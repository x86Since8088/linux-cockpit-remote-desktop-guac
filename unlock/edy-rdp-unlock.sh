#!/bin/bash
# edy-rdp-unlock <uid> — unlock the caller's OWN locked graphical seat session.
#
# This exists because nothing else can do it. The greeter on 3390 starts a NEW
# session and cannot attach to a locked one; Console and Virtual are refused by
# grd while the seat is locked ("Session creation inhibited"); and a Wayland VNC
# or Isolated desktop is a different session entirely. To resume the session the
# user actually left, the seat has to be unlocked, and logind is the only thing
# that unlocks it.
#
# The privilege is deliberately narrow. This runs as root, but it will only
# unlock a session that is ALL of:
#   * owned by the uid passed in (never another user's)
#   * attached to a seat (never a TTY or a remote/seatless session)
#   * graphical (wayland or x11)
#   * currently Active
#   * currently LockedHint=yes
# Anything else is refused, so the worst this can do is unlock a screen its
# caller was already entitled to unlock by walking to the machine.
set -uo pipefail

uid="${1:?usage: edy-rdp-unlock <uid>}"
user=$(id -un "$uid" 2>/dev/null) || { echo "no such uid $uid" >&2; exit 2; }

unlocked=0
while read -r sid rest; do
    [ -n "$sid" ] || continue
    props=$(loginctl show-session "$sid" \
            -p User -p Type -p Active -p Seat -p LockedHint 2>/dev/null) || continue
    get(){ printf '%s\n' "$props" | sed -n "s/^$1=//p"; }
    [ "$(get User)"       = "$uid" ] || continue
    [ -n "$(get Seat)"    ]          || continue
    [ "$(get Active)"     = "yes"  ] || continue
    [ "$(get LockedHint)" = "yes"  ] || continue
    case "$(get Type)" in wayland|x11) ;; *) continue ;; esac

    echo "[unlock] session $sid ($user, $(get Type) on $(get Seat)) is locked; unlocking"
    if loginctl unlock-session "$sid"; then
        unlocked=$((unlocked+1))
    else
        echo "[unlock] loginctl refused to unlock $sid" >&2
    fi
done < <(loginctl list-sessions --no-legend 2>/dev/null)

if [ "$unlocked" -eq 0 ]; then
    echo "[unlock] nothing to do: $user has no active, locked, graphical seat session" >&2
    exit 3
fi
echo "[unlock] unlocked $unlocked session(s) for $user"
