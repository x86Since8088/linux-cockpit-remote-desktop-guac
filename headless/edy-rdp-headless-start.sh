#!/bin/bash
# edy-rdp-headless-start <uid>
#
# Brings up (idempotently) a per-user ISOLATED headless GNOME session for <uid>
# plus a headless gnome-remote-desktop RDP server on a deterministic LOOPBACK
# port, using plain RDP (no greeter/RDSTLS handover -- which is broken on this
# host). guacd (FreeRDP2) renders it. See docs/KNOWN_ISSUES I26/I29.
#
# Port = HEADLESS_PORT_BASE + (uid - UID_BASE).  Reachable only via loopback
# (firewalled by edy-rdp-headless.nft); the SO_PEERCRED relay is the intended
# path. An ephemeral RDP gate credential is minted per bring-up and written to
# /run/edy-rdp/headless/<uid>.env (root:edy-rdp 0640) for the relay to read.
set -uo pipefail

HEADLESS_PORT_BASE=${HEADLESS_PORT_BASE:-33000}
UID_BASE=${UID_BASE:-1000}
STATE=/run/edy-rdp/headless

uid="${1:?usage: edy-rdp-headless-start <uid>}"
user=$(id -un "$uid" 2>/dev/null) || { echo "no such uid $uid" >&2; exit 2; }
[ "$uid" -ge "$UID_BASE" ] && [ "$uid" -lt "$((UID_BASE+1000))" ] || { echo "uid $uid out of range" >&2; exit 2; }
port=$((HEADLESS_PORT_BASE + uid - UID_BASE))
run=/run/user/$uid
cdir=/var/lib/edy-rdp/headless/$uid    # cert lives in a service-owned dir, not the user's home

runU(){ runuser -u "$user" -- env XDG_RUNTIME_DIR="$run" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$run/bus" "$@"; }

echo "[headless] bringing up isolated session for $user (uid $uid) on 127.0.0.1:$port"

# 1. lingering + GPU group access (headless users get no logind ACL for /dev/dri)
loginctl enable-linger "$user"
for g in render video; do id -nG "$user" | grep -qw "$g" || usermod -aG "$g" "$user"; done
for i in $(seq 1 20); do [ -S "$run/bus" ] && break; sleep 0.5; done
[ -S "$run/bus" ] || { echo "user bus for $user never appeared" >&2; exit 1; }

# 2. headless gnome-shell in a REAL logind session (PAMName=login), NO --virtual-monitor
#    (grd creates the monitor on connect; a pre-made one gets captured empty).
#
# Do NOT reuse a seat0 / --mode=ubuntu gnome-shell. Isolated and the local
# Ubuntu desktop share /run/user/<uid> (wayland-0 + session bus). Hijacking
# the existing compositor, then tearing it down, kills the physical desktop.
seat_shell=0
if pgrep -u "$uid" -a -x gnome-shell 2>/dev/null | grep -v -- '--headless' | grep -q .
then
  seat_shell=1
fi
if [ "$seat_shell" = 1 ]; then
  echo "[headless] REFUSING isolated session: $user already has a seat GNOME desktop." >&2
  echo "[headless] Isolated RDP would share /run/user/$uid with it and has previously killed gnome-shell on disconnect." >&2
  # publish the human reason for the relay to surface to the browser (0640 root:edy-rdp)
  install -d -o root -g edy-rdp -m 0750 "$STATE" 2>/dev/null || true
  ( umask 027; printf '%s' "you are logged into the physical desktop on this machine as $user; the Isolated desktop cannot run alongside a local login. Use the Console or Virtual session instead, or log out locally first." > "$STATE/$uid.err" )
  chgrp edy-rdp "$STATE/$uid.err" 2>/dev/null || true
  exit 3
fi
rm -f "$STATE/$uid.err" 2>/dev/null || true
fresh=0
if ! systemctl is-active --quiet "edy-rdp-shell-$uid.service" 2>/dev/null \
   && ! pgrep -u "$uid" -f '/usr/bin/gnome-shell --wayland --headless' >/dev/null 2>&1; then
  fresh=1
  systemctl reset-failed "edy-rdp-shell-$uid.service" 2>/dev/null || true
  systemd-run --uid="$uid" --gid="$uid" --property=PAMName=login --property=Type=simple \
    --property=SupplementaryGroups="render video" --unit="edy-rdp-shell-$uid" --collect \
    --setenv=XDG_RUNTIME_DIR="$run" --setenv=XDG_SESSION_TYPE=wayland \
    --setenv=XDG_CURRENT_DESKTOP=GNOME \
    /usr/bin/gnome-shell --wayland --headless --no-x11
  for i in $(seq 1 20); do [ -S "$run/wayland-0" ] && break; sleep 0.5; done
  [ -S "$run/wayland-0" ] || { echo "wayland-0 for $user never appeared" >&2; exit 1; }
fi

# 3. self-signed TLS cert (grd's own TPM auto-gen fails here; FreeRDP accepts openssl PEM)
install -d -o "$uid" -g "$uid" -m 0700 "$cdir"
if [ ! -s "$cdir/rdp-tls.crt" ]; then
  runuser -u "$user" -- openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$cdir/rdp-tls.key" -out "$cdir/rdp-tls.crt" -days 3650 \
    -subj "/CN=edy-rdp-headless-$user" >/dev/null 2>&1
  chmod 600 "$cdir/rdp-tls.key"
fi

# 4. mint an ephemeral gate credential, configure the HEADLESS grd scope (file-based
#    creds -- the regular scope needs a keyring the headless user does not have).
cred=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
runU grdctl --headless rdp set-port "$port"            >/dev/null 2>&1
runU grdctl --headless rdp disable-port-negotiation    >/dev/null 2>&1
runU grdctl --headless rdp set-tls-cert "$cdir/rdp-tls.crt" >/dev/null 2>&1
runU grdctl --headless rdp set-tls-key  "$cdir/rdp-tls.key" >/dev/null 2>&1
runU grdctl --headless rdp set-credentials "$user" "$cred" >/dev/null 2>&1
runU grdctl --headless rdp enable                      >/dev/null 2>&1
runU systemctl --user restart gnome-remote-desktop-headless.service

# 4b. virtual-desktop identity: a UUID + creation time that is the PRIMARY KEY for
#     this user's virtual desktop. Generated when the desktop is first created and
#     REUSED for the life of that gnome-shell session (so a reconnect is reissued the
#     SAME desktop); the id file is removed on teardown, so a torn-down-then-recreated
#     desktop gets a NEW id. Persist it alongside the runtime state.
install -d -o root -g edy-rdp -m 0750 "$STATE"
idf="$STATE/$uid.desktop"
if [ "${fresh:-0}" = 1 ] || [ ! -s "$idf" ]; then
  desktop_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "d-$uid-$$-$RANDOM")
  created=$(date +%s)
  ( umask 027; printf 'DESKTOP_ID=%s\nCREATED=%s\n' "$desktop_id" "$created" > "$idf" )
  chgrp edy-rdp "$idf" 2>/dev/null || true; chmod 0640 "$idf" 2>/dev/null || true
else
  # shellcheck disable=SC1090
  . "$idf"; desktop_id="$DESKTOP_ID"; created="$CREATED"
fi

# 5. publish port+cred+desktop-id for the relay (root:edy-rdp 0640)
umask 027
tmp=$(mktemp "$STATE/.$uid.XXXXXX")
printf 'PORT=%s\nUSER=%s\nCRED=%s\nDESKTOP_ID=%s\nCREATED=%s\n' \
       "$port" "$user" "$cred" "$desktop_id" "$created" > "$tmp"
chgrp edy-rdp "$tmp"; chmod 0640 "$tmp"; mv "$tmp" "$STATE/$uid.env"

# 6. wait for the RDP port
for i in $(seq 1 15); do ss -ltnH 2>/dev/null | grep -q ":$port " && break; sleep 0.5; done
if ss -ltnH 2>/dev/null | grep -q ":$port "; then
  echo "[headless] ready: $user isolated desktop on 127.0.0.1:$port"
else
  echo "[headless] ERROR: port $port not listening for $user" >&2; exit 1
fi
