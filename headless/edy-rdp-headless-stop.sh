#!/bin/bash
# edy-rdp-headless-stop <uid> -- tear down a user's headless isolated session.
set -uo pipefail
uid="${1:?usage: edy-rdp-headless-stop <uid>}"
user=$(id -un "$uid" 2>/dev/null) || exit 0
run=/run/user/$uid
runU(){ runuser -u "$user" -- env XDG_RUNTIME_DIR="$run" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$run/bus" "$@" 2>/dev/null; }
runU systemctl --user stop gnome-remote-desktop-headless.service
runU grdctl --headless rdp disable
# Only the dedicated Isolated compositor. NEVER pkill -x gnome-shell: that
# also kills the seat0 Ubuntu desktop (org.gnome.Shell@ubuntu) and is what
# made the local session unstable on disconnect.
systemctl stop "edy-rdp-shell-$uid.service" 2>/dev/null || true
pkill -u "$uid" -f '/usr/bin/gnome-shell --wayland --headless' 2>/dev/null || true
rm -f "/run/edy-rdp/headless/$uid.env"
# drop the virtual-desktop identity so a recreated desktop gets a NEW primary key
rm -f "/run/edy-rdp/headless/$uid.desktop"
echo "[headless] stopped isolated session for $user (uid $uid)"
