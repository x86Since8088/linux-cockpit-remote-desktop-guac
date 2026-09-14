#!/usr/bin/env bash
# edy-rdp-krb-preflight <KEY> — pick only REACHABLE KDCs before an NLA/RDSTLS connect.
#
# FreeRDP3 tries Kerberos FIRST. When a domain controller is down, xfreerdp3 hangs on it
# for ~2 minutes before NLA fails and it would have fallen back to NTLM. For this project
# the RDP "door"/"gate" users (rdplogin, rdplocal) are LOCAL grd credentials — never AD
# principals — so Kerberos can only ever fail for them; the hang is pure dead weight.
#
# This preflight reads the realm and its configured KDC list from the system krb5 config
# (including /etc/krb5.conf.d/ drop-ins), probes EVERY KDC's port 88 IN PARALLEL with a
# 500 ms timeout, and writes a per-request krb5.conf that lists ONLY the KDCs that answered
# (dns_lookup_kdc off, so a dead one is never re-discovered). If none answer it writes one
# with NO kdc for the realm, so Kerberos fails INSTANTLY ("cannot find KDC") and NLA drops
# straight to NTLM. Either way the ~2 min stall is gone. Every attempt, each online/offline
# result, and the decision are logged.
#
# Emits one line on stdout for the caller to eval:  KRB5_CONFIG=<path>
# (empty/unchanged realm, or nothing to do, => prints the system config path.)
set -uo pipefail

KEY="${1:-preflight}"
STATE="${EDY_BRIDGE_STATE:-/run/edy-rdp/bridge}"
LOG="${EDY_KRB_LOG:-$STATE/$KEY.krblog}"
OUT="${EDY_KRB_OUT:-$STATE/$KEY.krb5.conf}"
PROBE_S="${EDY_KRB_PROBE_S:-0.5}"          # 500 ms per-KDC probe
SYS_KRB5="${EDY_SYS_KRB5:-/etc/krb5.conf}"
KDC_DROPINS=(/etc/krb5.conf.d/*)

ts(){ date '+%Y-%m-%dT%H:%M:%S%z'; }
log(){ printf '%s krb-preflight[%s] %s\n' "$(ts)" "$KEY" "$*" >>"$LOG" 2>/dev/null; }

# --- realm ------------------------------------------------------------------
REALM=$(grep -rhoiE '^[[:space:]]*default_realm[[:space:]]*=[[:space:]]*[^[:space:]]+' \
          "$SYS_KRB5" "${KDC_DROPINS[@]}" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*//')
if [ -z "$REALM" ]; then log "no default_realm; using system krb5"; echo "KRB5_CONFIG=$SYS_KRB5"; exit 0; fi

# --- configured KDC hosts for THIS realm (scoped to its [realms] block) ------
collect_kdcs(){
  awk -v want="$REALM" '
    /^[[:space:]]*\[realms\]/ { inr=1; cur=""; next }
    /^[[:space:]]*\[/         { if ($0 !~ /\[realms\]/) inr=0 }
    inr && /=[[:space:]]*\{/  { cur=$1; next }
    inr && /^[[:space:]]*\}/  { cur="" }
    inr && cur==want && /^[[:space:]]*kdc[[:space:]]*=/ {
      v=$0; sub(/.*=[[:space:]]*/,"",v); gsub(/[[:space:]]/,"",v); if (v!="") print v }
  ' "$@" 2>/dev/null
}
mapfile -t KDCS < <(collect_kdcs "$SYS_KRB5" "${KDC_DROPINS[@]}" | awk 'NF && !seen[$0]++')
if [ "${#KDCS[@]}" -eq 0 ]; then
  log "realm=$REALM has NO configured kdc (relies on SRV); leaving system krb5 in place"
  echo "KRB5_CONFIG=$SYS_KRB5"; exit 0
fi
log "realm=$REALM configured_kdcs=${KDCS[*]}"

# --- probe every KDC:88 in parallel, 500 ms --------------------------------
probe(){                         # host[:port] -> "ONLINE|OFFLINE host ip port ms"
  local h="$1" host port ip start end
  host="${h%%:*}"; port="${h##*:}"; [ "$port" = "$h" ] && port=88
  ip=$(timeout 1 getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$ip" ] || ip="$host"
  start=$(date +%s%3N 2>/dev/null || echo 0)
  if timeout "$PROBE_S" bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
    end=$(date +%s%3N 2>/dev/null || echo 0)
    printf 'ONLINE %s %s %s %s\n' "$host" "$ip" "$port" "$((end-start))"
  else
    printf 'OFFLINE %s %s %s %s\n' "$host" "$ip" "$port" "timeout>=${PROBE_S}s"
  fi
}
RES=$(for h in "${KDCS[@]}"; do probe "$h" & done; wait)
online=()
while read -r st host ip port info; do
  [ -z "${st:-}" ] && continue
  log "probe kdc=$host ip=$ip:$port -> $st ($info)"
  [ "$st" = ONLINE ] && online+=("$host:$port")
done <<< "$RES"

# --- write a per-request krb5.conf with only-online (or no) KDCs ------------
lc_realm=$(printf '%s' "$REALM" | tr 'A-Z' 'a-z')
umask 077
{
  printf '[libdefaults]\n'
  printf '    default_realm = %s\n' "$REALM"
  printf '    dns_lookup_kdc = false\n    dns_lookup_realm = false\n'
  printf '    ccache_type = 4\n    forwardable = true\n    rdns = false\n\n'
  printf '[realms]\n    %s = {\n' "$REALM"
  for kp in "${online[@]}"; do printf '        kdc = %s\n' "$kp"; done
  [ "${#online[@]}" -gt 0 ] && printf '        admin_server = %s\n' "${online[0]%%:*}"
  printf '    }\n\n[domain_realm]\n    .%s = %s\n    %s = %s\n' "$lc_realm" "$REALM" "$lc_realm" "$REALM"
} > "$OUT" 2>/dev/null

if [ "${#online[@]}" -gt 0 ]; then
  log "DECISION: kerberos via ONLINE kdc(s): ${online[*]}  -> $OUT"
else
  log "DECISION: NO kdc reachable; krb5 has no KDC -> Kerberos fails instantly, NLA uses NTLM  -> $OUT"
fi
echo "KRB5_CONFIG=$OUT"
