#!/usr/bin/env bash
# edy-rdp-bridge-start <KEY>
#
# The FreeRDP3 bridge: renders a grd RDP/RDSTLS target with the VANILLA xfreerdp3
# client (FreeRDP 3.x) into a headless Xvfb, and re-serves that framebuffer over
# loopback VNC with x11vnc. guacd's (FreeRDP-independent) VNC plugin then bridges
# it to the browser via the relay. This replaces guacd's bundled FreeRDP2 RDP
# client, which cannot negotiate NLA to grd's 3389 screen-share ("wrong security
# type", console-519) nor do the 3390 greeter's RDSTLS, and whose RDP cursor path
# froze the browser tab. xfreerdp3 handles all three.
#
# The relay writes the request to <STATE>/<KEY>.req, starts this unit, then reads
# <STATE>/<KEY>.env for the loopback VNC endpoint to hand guacd. Runs in the
# FOREGROUND and tears the whole stack down on exit, so "connection gone" disposes
# the bridge while the backing desktop (headless GNOME / physical seat) lives on.
#
# .req  (KEY=VALUE):  HOST PORT SECURITY USERNAME PASSWORD GEOM
# .env  (written here, 0640 root:edy-rdp):  VNCHOST VNCPORT VNCPASS
#
# SECURITY TODO (hardening pass): pass the RDP credential to xfreerdp3 without argv
# exposure (/args-from file), and gate the loopback VNC port (VNC password + nft
# owner-match) instead of -nopw. v1 proves the chain.
set -uo pipefail

# x11vnc refuses to serve an X11 (Xvfb) display if it sees Wayland env vars and
# assumes it should use the Wayland path; strip them so it uses our Xvfb.
unset WAYLAND_DISPLAY 2>/dev/null || true
export XDG_SESSION_TYPE=x11

STATE="${EDY_BRIDGE_STATE:-/run/edy-rdp/bridge}"
KEY="${1:?usage: edy-rdp-bridge-start <KEY>}"
req="$STATE/$KEY.req"
[ -r "$req" ] || { echo "no request file $req" >&2; exit 2; }

# The .req has EXACTLY 6 KEY=VALUE lines. More than that means a value contained a
# newline and forged an extra key (the relay + bridge.py reject that upstream; this is
# a cheap last line of defense against .req KEY injection / SSRF). Also take the FIRST
# value of each key so a later injected duplicate cannot override the intended one.
[ "$(wc -l < "$req")" -le 6 ] || { echo "malformed request (extra lines) $req" >&2; exit 2; }
HOST=""; PORT=""; SECURITY=""; USERNAME=""; PASSWORD=""; GEOM=""
while IFS='=' read -r k v; do case "$k" in
  HOST) [ -z "${HOST_SET:-}" ] && { HOST=$v; HOST_SET=1; } ;;
  PORT) [ -z "${PORT_SET:-}" ] && { PORT=$v; PORT_SET=1; } ;;
  SECURITY) [ -z "${SEC_SET:-}" ] && { SECURITY=$v; SEC_SET=1; } ;;
  USERNAME) [ -z "${USER_SET:-}" ] && { USERNAME=$v; USER_SET=1; } ;;
  PASSWORD) [ -z "${PASS_SET:-}" ] && { PASSWORD=$v; PASS_SET=1; } ;;
  GEOM) [ -z "${GEOM_SET:-}" ] && { GEOM=$v; GEOM_SET=1; } ;;
esac done < "$req"
[ -n "$SECURITY" ] || SECURITY="nla"
[ -n "$GEOM" ] || GEOM="1600x1000"
[ -n "$HOST" ] && [ -n "$PORT" ] || { echo "req missing HOST/PORT" >&2; exit 2; }

# deterministic, collision-checked display + loopback VNC port from KEY
hashnum=$(printf '%s' "$KEY" | cksum | cut -d' ' -f1)
disp=$(( 80 + hashnum % 100 ))
while [ -e "/tmp/.X11-unix/X$disp" ]; do disp=$(( (disp - 79) % 100 + 80 )); done
vncport=$(( 5900 + disp ))

install -d -o root -g edy-rdp -m 0750 "$STATE" 2>/dev/null || true

# Per-connection VNC token: a strong random password gating the loopback VNC port,
# so no other local user can attach to a live bridge (defense-in-depth on top of the
# loopback bind). x11vnc -passwdfile reads it from a 0600 file (never argv/ps); the
# relay injects the same value into guacd's VNC 'password' param, and the trace log
# redacts it. This closes the "-nopw local peek" hole (VNC-leg parallel of the token
# gate discussed with the user).
vncpass="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
pwfile="$STATE/.$KEY.vncpw"
( umask 077; printf '%s\n' "$vncpass" > "$pwfile" )

xvfb_pid=""; rdp_pid=""; vnc_pid=""; argsfile=""
cleanup() {
  [ -n "$vnc_pid" ]  && kill "$vnc_pid"  2>/dev/null
  [ -n "$rdp_pid" ]  && kill "$rdp_pid"  2>/dev/null
  [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null
  [ -n "$argsfile" ] && rm -f "$argsfile" 2>/dev/null
  rm -f "$pwfile" "$STATE/$KEY.env" "$STATE/$KEY.krb5.conf" 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "[bridge $KEY] Xvfb :$disp ($GEOM) -> xfreerdp3 $HOST:$PORT ($SECURITY) -> x11vnc 127.0.0.1:$vncport"
Xvfb ":$disp" -screen 0 "${GEOM}x24" -nolisten tcp >/dev/null 2>&1 &
xvfb_pid=$!
for i in $(seq 1 25); do [ -e "/tmp/.X11-unix/X$disp" ] && break; sleep 0.2; done

# xfreerdp3 -> the grd target, into the Xvfb. The credential is passed via an env
# var (/args-from:env) so it is NOT in argv: /proc/PID/environ is readable only by
# the process owner (the relay uid) and root, unlike world-readable /proc/PID/cmdline.
# CRITICAL: /args-from wants ONE ARGUMENT PER LINE. A space-joined string is taken
# as a single argument, silently dropping /u,/p,/cert:ignore -> xfreerdp3 hits the
# interactive certificate prompt with no stdin and dies, leaving a black Xvfb.
# Certificate policy depends on the target. The LOCAL grd (loopback) is trusted, so
# /cert:ignore. A REMOTE host is off-box and could be MITM'd on the LAN, so pin its
# cert trust-on-first-use (/cert:tofu) in a persistent per-boot store: the first
# connect stores the cert; a LATER changed cert (MITM) is refused. (First-use trust
# is the TOFU tradeoff — see docs/KNOWN_ISSUES.md; use a pinned CA for higher assurance.)
case "$HOST" in
  127.0.0.1|::1|localhost) CERTARG="/cert:ignore" ;;
  *) CERTARG="/cert:tofu"
     export XDG_CONFIG_HOME="${EDY_RDP_FREERDP_HOME:-/run/edy-rdp/freerdp}"
     mkdir -p "$XDG_CONFIG_HOME" 2>/dev/null || true ;;
esac
# Kerberos preflight (loopback / local grd only). FreeRDP3 tries Kerberos FIRST, and a
# dead AD DC makes xfreerdp3 hang ~2 min before NLA falls back to NTLM. The local grd
# door/gate users are LOCAL credentials (never AD principals), so point krb5 only at the
# KDCs that answer right now -- or none, for an INSTANT NTLM fallback. Scoped to loopback
# so a remote host's own realm is left alone. Non-fatal: on any error the system krb5 stands.
case "$HOST" in
  127.0.0.1|::1|localhost)
    _pf="$(dirname -- "$0")/edy-rdp-krb-preflight.sh"
    [ -x "$_pf" ] || _pf="$(command -v edy-rdp-krb-preflight.sh 2>/dev/null || true)"
    if [ -n "${_pf:-}" ] && [ -x "$_pf" ]; then
      eval "$("$_pf" "$KEY" 2>>"$STATE/$KEY.krblog")" && export KRB5_CONFIG
      echo "[bridge $KEY] krb preflight: KRB5_CONFIG=${KRB5_CONFIG:-<system>}"
    fi
    ;;
esac
# Security protocol. Local grd uses an explicit protocol (nla / rdstls). A REMOTE
# host "negotiates": offer NLA+TLS but DISABLE plain RDP-standard security
# (/sec:rdp:off), so the credential is never sent under weak RDP encryption -- the
# server picks NLA (Windows) or TLS (e.g. xrdp).
if [ "$SECURITY" = "negotiate" ]; then SECLINE="/sec:rdp:off"; else SECLINE="/sec:$SECURITY"; fi
# /clipboard puts the REMOTE clipboard into this bridge's Xvfb. That is only half
# the path: x11vnc then exposes it as a VNC cut-text, and guacd carries it to the
# browser (where disable-copy/disable-paste decide what the user may actually do).
# Without it the guacd-side clipboard params have nothing to move.
#
# Audio is deliberately NOT enabled here. xfreerdp3's /sound would play on THIS
# host, not in the browser -- VNC carries no audio. Sound reaches the browser via
# guacd's own enable-audio + audio-servername, which is a separate path.
# Smartcard is likewise absent: /smartcard would redirect the reader attached to
# this machine, never the browser user's, and VNC has no smartcard channel at all.
#
# Keyboard: left in xfreerdp3's default SCANCODE mode (no /kbd option). An earlier build
# set /kbd:unicode:on ("send characters, not scancodes"), but a controlled test on an
# Ubuntu 26.04 / GNOME 50 VM showed unicode mode MANGLES keys injected through the
# x11vnc XTEST -> Xvfb path -- winpr logs int_MultiByteToWideChar "insufficient buffer
# supplied, got 1, required 2" and the wrong password lands, making password fields WORSE.
# Plain scancode carries the browser's keys faithfully for this bridge topology; keep it.
# (See docs/KNOWN_ISSUES I39a and memory allow-locked-remote-desktop-vm.)
EDY_RDP_ARGS="$(printf '%s\n' \
  "/v:$HOST:$PORT" "/u:$USERNAME" "/p:$PASSWORD" "$CERTARG" "/gfx" "/clipboard" \
  "$SECLINE" "/f" "/size:$GEOM" "/log-level:WARN")"
export EDY_RDP_ARGS
rdplog="$STATE/$KEY.rdplog"
( umask 027; : > "$rdplog" ); chgrp edy-rdp "$rdplog" 2>/dev/null || true
DISPLAY=":$disp" setsid xfreerdp3 /args-from:env:EDY_RDP_ARGS >"$rdplog" 2>&1 &
rdp_pid=$!
unset EDY_RDP_ARGS

# FAIL LOUDLY, never serve a black frame: refused/cert/auth failures kill
# xfreerdp3 within a couple of seconds — catch that BEFORE publishing the VNC
# endpoint so the relay refuses the connection with the real reason instead of
# guacd happily streaming an empty Xvfb.
for i in $(seq 1 12); do
  kill -0 "$rdp_pid" 2>/dev/null || {
    echo "[bridge $KEY] ERROR: xfreerdp3 exited during connect; log tail:" >&2
    tail -n 4 "$rdplog" >&2 2>/dev/null || true
    exit 1
  }
  sleep 0.25
done

# x11vnc serves the Xvfb over loopback. Pin BOTH the IPv4 and IPv6 rfb port to
# $vncport (else x11vnc also grabs the default 5900) and background it directly so
# $vnc_pid is the real server the teardown trap kills (v1: -nopw; hardening adds a
# VNC password + an nft owner-match on the loopback port).
x11vnc -display ":$disp" -localhost -rfbport "$vncport" -rfbportv6 "$vncport" \
  -passwdfile "$pwfile" -forever -shared -noxdamage -o /dev/null >/dev/null 2>&1 &
vnc_pid=$!
for i in $(seq 1 25); do ss -tlnH 2>/dev/null | grep -q "127.0.0.1:$vncport " && break; sleep 0.2; done

tmp=$(mktemp "$STATE/.env.$KEY.XXXXXX")
printf 'VNCHOST=127.0.0.1\nVNCPORT=%s\nVNCPASS=%s\n' "$vncport" "$vncpass" > "$tmp"
chgrp edy-rdp "$tmp" 2>/dev/null || true; chmod 0640 "$tmp"; mv "$tmp" "$STATE/$KEY.env"

if ss -tlnH 2>/dev/null | grep -q "127.0.0.1:$vncport "; then
  echo "[bridge $KEY] ready: VNC 127.0.0.1:$vncport"
else
  echo "[bridge $KEY] ERROR: VNC port $vncport not listening" >&2; exit 1
fi

# stay up while BOTH halves live; if the RDP client dies mid-session, exit so the
# whole stack (and guacd's VNC feed) drops — the browser sees a disconnect, not a
# frozen last frame. Teardown trap fires on any exit.
while kill -0 "$vnc_pid" 2>/dev/null && kill -0 "$rdp_pid" 2>/dev/null; do sleep 2; done
kill -0 "$rdp_pid" 2>/dev/null || { echo "[bridge $KEY] xfreerdp3 ended; tearing down" >&2; }
