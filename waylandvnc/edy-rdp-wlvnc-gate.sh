#!/bin/bash
# edy-rdp-wlvnc-gate - owner-gate the per-user wayvnc listener ports (I65).
#
# wayvnc runs with enable_auth=false on 127.0.0.1:34000+(uid-1000). The
# edy_rdp_guacd nftables table drops non-root connections to the ports in its set
# `wayvnc_ports` -- ONLY those ports, so an unrelated local listener that happens
# to sit in 34000-34999 is untouched. This helper is the one place that knows the
# uid -> port formula and the one thing that writes the set.
#
#   port <uid>   print the wayvnc port of <uid> (the start script uses this too)
#   add  <uid>   add that port to the set (start script, BEFORE wayvnc listens)
#   del  <uid>   remove it (stop script)
#   load         (re)load the guacd table and, in the SAME nft transaction,
#                re-add every session that exists (a directory $STATE/<uid>).
#                edy-rdp-firewall.service uses this for start AND reload, so a
#                reload (table deleted + re-created) never opens a window.
set -uo pipefail
WLVNC_PORT_BASE=${WLVNC_PORT_BASE:-34000}
UID_BASE=${UID_BASE:-1000}
STATE=${WLVNC_STATE_DIR:-/run/edy-rdp/waylandvnc}
RULES=${EDY_RDP_GUACD_NFT:-/etc/nftables.d/edy-rdp-guacd.nft}
NFT=${NFT:-/usr/sbin/nft}
TABLE="inet edy_rdp_guacd"; SET=wayvnc_ports

port_of() {
    local uid=$1
    [[ $uid =~ ^[0-9]+$ ]] && (( uid >= UID_BASE && uid < UID_BASE + 1000 )) \
        || { echo "uid '$uid' out of range" >&2; return 2; }
    echo $(( WLVNC_PORT_BASE + uid - UID_BASE ))
}

case "${1:-}" in
  port) port_of "${2:?usage: $0 port <uid>}" ;;
  add)  p=$(port_of "${2:?usage: $0 add <uid>}") || exit 2
        "$NFT" add element $TABLE $SET "{ $p }" ;;
  del)  p=$(port_of "${2:?usage: $0 del <uid>}") || exit 2
        "$NFT" delete element $TABLE $SET "{ $p }" 2>/dev/null || true ;;
  load)
    ports=()
    for d in "$STATE"/[0-9]*/; do
        [[ -d $d ]] || continue
        u=$(basename "$d")
        p=$(port_of "$u" 2>/dev/null) && ports+=("$p")
    done
    { cat -- "$RULES"
      if ((${#ports[@]})); then
          echo "add element $TABLE $SET { $(IFS=,; echo "${ports[*]}") }"
      fi
    } | "$NFT" -f - ;;
  *) echo "usage: $0 port|add|del <uid> | load" >&2; exit 2 ;;
esac
