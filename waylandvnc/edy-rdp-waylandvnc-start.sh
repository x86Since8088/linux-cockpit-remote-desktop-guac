#!/bin/bash
# edy-rdp-waylandvnc-start <uid>
#
# Brings up (idempotently) a per-user headless WAYLAND session for <uid> --
# sway on the wlroots headless backend -- and serves it over VNC with wayvnc on
# a deterministic LOOPBACK port. guacd speaks VNC natively, so nothing
# translates: no xfreerdp3, no Xvfb, no x11vnc, no RDP anywhere in the path.
#
# WHY THIS EXISTS ALONGSIDE THE ISOLATED SCENARIO
#   isolated refuses when the user is logged in at the seat, because a second
#   gnome-shell for the same uid shares /run/user/<uid> (wayland socket + session
#   bus) with the physical desktop and tearing it down has killed that desktop.
#   This session gets its OWN XDG_RUNTIME_DIR under /run/edy-rdp/waylandvnc/<uid>,
#   touches nothing the seat owns, and therefore runs happily beside a local
#   login -- which is the case that previously left a locked-out user with no
#   working scenario at all.
#
# WHY NOT x11vnc / wayvnc AGAINST THE PHYSICAL SCREEN
#   x11vnc reads an X framebuffer, and there is none under Wayland. wayvnc needs
#   the wlroots screencopy protocol, which Mutter does not implement. Neither can
#   see a GNOME seat. This scenario therefore serves a session we control rather
#   than mirroring the physical one -- for that, use Console.
set -uo pipefail

UID_BASE=${UID_BASE:-1000}
STATE=/run/edy-rdp/waylandvnc
GEOM=${WLVNC_GEOM:-1600x1000}

uid="${1:?usage: edy-rdp-waylandvnc-start <uid>}"
user=$(id -un "$uid" 2>/dev/null) || { echo "no such uid $uid" >&2; exit 2; }
[ "$uid" -ge "$UID_BASE" ] && [ "$uid" -lt "$((UID_BASE+1000))" ] || { echo "uid $uid out of range" >&2; exit 2; }
# The uid -> port formula lives in ONE place: the gate helper (installed beside
# this script; the .sh name is the source-tree layout).
d=$(dirname -- "$0"); GATE=""
for g in "$d/edy-rdp-wlvnc-gate" "$d/edy-rdp-wlvnc-gate.sh"; do [ -x "$g" ] && { GATE=$g; break; }; done
[ -n "$GATE" ] || { echo "edy-rdp-wlvnc-gate not found beside $0" >&2; exit 1; }
port=$("$GATE" port "$uid") || exit 2
rt="$STATE/$uid/rt"                 # dedicated runtime dir: never /run/user/$uid
unit="edy-rdp-wlvnc-$uid"

install -d -o root -g edy-rdp -m 0750 "$STATE"
install -d -o "$user" -g "$user" -m 0700 "$STATE/$uid" "$rt"

# Owner-gate the port BEFORE anything can listen on it (and again on every call:
# idempotent, and it heals a table that was re-created). The directory just made
# above is also what a firewall reload re-reads, so there is no unguarded window.
# Fail closed: no gate, no wayvnc (it runs without auth).
"$GATE" add "$uid" || { echo "[wlvnc] could not gate port $port in the edy_rdp_guacd table" >&2; exit 1; }

# Already up? Report and exit 0 -- the relay calls this on every connect.
if systemctl is-active --quiet "$unit.service" && ss -tlnH "sport = :$port" 2>/dev/null | grep -q .; then
    echo "[wlvnc] session for $user already up on 127.0.0.1:$port"
else
    systemctl reset-failed "$unit.service" 2>/dev/null || true
    cat > "$STATE/$uid/sway.cfg" <<CFG
output HEADLESS-1 resolution ${GEOM}
# no bar, no autostart: this is a remote work surface, not a kiosk
CFG
    cat > "$STATE/$uid/wayvnc.cfg" <<CFG
address=127.0.0.1
port=$port
enable_auth=false
CFG
    chown "$user":"$user" "$STATE/$uid/sway.cfg" "$STATE/$uid/wayvnc.cfg"

    # Deliberately NO PAMName=login. pam_systemd sets XDG_RUNTIME_DIR itself,
    # overriding --setenv, which puts sway's socket in /run/user/<uid> -- the very
    # directory this scenario exists to stay out of. Without PAM the dedicated
    # runtime dir survives and the seat's compositor is untouched. sway headless
    # needs no logind seat, so nothing is lost.
    systemd-run --uid="$uid" --gid="$uid" \
        --property=Type=simple --unit="$unit" --collect \
        --setenv=XDG_RUNTIME_DIR="$rt" \
        --setenv=XDG_SESSION_TYPE=wayland \
        --setenv=WLR_BACKENDS=headless \
        --setenv=WLR_LIBINPUT_NO_DEVICES=1 \
        --setenv=XDG_CURRENT_DESKTOP=sway \
        /usr/bin/sway -c "$STATE/$uid/sway.cfg" >/dev/null 2>&1

    # Wait for sway's socket. Its NAME is assigned by sway, not by us -- setting
    # WAYLAND_DISPLAY beforehand does not rename it, and guessing wayland-0 is
    # how the first attempt at this failed.
    wd=""
    for i in $(seq 1 40); do
        wd=$(ls "$rt" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1)
        [ -n "$wd" ] && break
        sleep 0.5
    done
    [ -n "$wd" ] || { echo "[wlvnc] sway never created a wayland socket" >&2; exit 1; }
    echo "[wlvnc] sway up for $user (WAYLAND_DISPLAY=$wd)"

    systemctl reset-failed "$unit-vnc.service" 2>/dev/null || true
    systemd-run --uid="$uid" --gid="$uid" --property=Type=simple \
        --unit="$unit-vnc" --collect \
        --setenv=XDG_RUNTIME_DIR="$rt" \
        --setenv=WAYLAND_DISPLAY="$wd" \
        /usr/bin/wayvnc -C "$STATE/$uid/wayvnc.cfg" 127.0.0.1 "$port" >/dev/null 2>&1

    for i in $(seq 1 40); do
        ss -tlnH "sport = :$port" 2>/dev/null | grep -q . && break
        sleep 0.5
    done
fi

ss -tlnH "sport = :$port" 2>/dev/null | grep -q . || {
    echo "[wlvnc] wayvnc never listened on 127.0.0.1:$port" >&2; exit 1; }

# Publish for the relay. No credential: wayvnc runs without auth because the
# port is loopback-only and the edy_rdp_guacd nftables table
# (hardening/edy-rdp-guacd.nft) lets only uid 0 -- guacd, in its rootful
# container -- connect to this port (it is in the set wayvnc_ports). Without that rule any local uid
# could attach to this user's desktop; edy-rdp-waylandvnc@.service Requires=
# the firewall unit so it cannot start without it.
tmp=$(mktemp "$STATE/.$uid.XXXXXX")
printf 'PORT=%s\nUSER=%s\nHOST=127.0.0.1\n' "$port" "$user" > "$tmp"
chgrp edy-rdp "$tmp"; chmod 0640 "$tmp"; mv "$tmp" "$STATE/$uid.env"
echo "[wlvnc] ready: 127.0.0.1:$port for $user"
