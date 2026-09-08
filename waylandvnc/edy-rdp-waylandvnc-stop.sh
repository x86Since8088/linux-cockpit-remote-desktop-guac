#!/bin/bash
# edy-rdp-waylandvnc-stop <uid> — tear down the per-user headless Wayland session.
set -uo pipefail
STATE=/run/edy-rdp/waylandvnc
uid="${1:?usage: edy-rdp-waylandvnc-stop <uid>}"
unit="edy-rdp-wlvnc-$uid"
# VNC first: dropping the compositor out from under wayvnc leaves it spinning
# on a dead socket instead of exiting.
systemctl stop "$unit-vnc.service" 2>/dev/null || true
systemctl stop "$unit.service" 2>/dev/null || true
rm -f "$STATE/$uid.env"
rm -rf "$STATE/$uid"
echo "[wlvnc] stopped session for uid $uid"
