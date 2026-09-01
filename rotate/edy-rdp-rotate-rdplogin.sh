#!/usr/bin/env bash
# edy-rdp-rotate-rdplogin — auto-rotate the 3390 "Remote Login" greeter door
# credential (username "rdplogin"). Run by edy-rdp-rotate-rdplogin.timer as root.
#
# The 3390 system daemon loads its RDP credential only at process start
# (KNOWN_ISSUES I15), so applying a new key requires restarting the daemon, which
# drops any live 3390 session. To avoid tearing down an in-progress greeter mid-use
# AND to avoid a window where credentials.ini holds a key the running daemon has not
# loaded (new connects would fail NLA), we ROTATE ONLY WHEN 3390 IS IDLE; the daily
# timer simply rotates on the next idle run. The browser fetches the current key from
# credentials.ini on each connect, so rotation is transparent to clients.
set -Eeuo pipefail

DOOR_USER="${EDY_RDP_DOOR_USER:-rdplogin}"

# Skip if a greeter connection is established (the FreeRDP3 bridge -> grd 3390, or a
# native client). A restart would drop it; wait for the next timer fire.
if ss -tnH state established 2>/dev/null | grep -q ':3390 '; then
  logger -t edy-rdp-rotate "3390 busy (established session); deferring rdplogin rotation"
  exit 0
fi

newkey="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
if [ "${#newkey}" -lt 16 ]; then
  logger -t edy-rdp-rotate "ERROR: failed to generate a strong key"; exit 1
fi

# set the new door credential, then restart the 3390 daemon so it loads it
grdctl --system rdp set-credentials "$DOOR_USER" "$newkey" >/dev/null 2>&1
grdctl --system rdp enable >/dev/null 2>&1 || true
systemctl try-restart gnome-remote-desktop.service

# never log the key itself; length only
logger -t edy-rdp-rotate "rotated 3390 ${DOOR_USER} door credential (len ${#newkey}); daemon restarted"
