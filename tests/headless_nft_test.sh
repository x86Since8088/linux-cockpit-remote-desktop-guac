#!/usr/bin/env bash
#
# tests/headless_nft_test.sh - KNOWN_ISSUES I61 regression suite. Run by
# run_tests.sh; runnable alone. Non-root, and the HOST's firewall and sysctls are
# never read for a verdict nor written: the kernel half runs inside a throwaway
# unprivileged user+network namespace (`unshare -rn`) that vanishes with it.
#
# THE DEFECT: up to 1.10.6 hardening/edy-rdp-headless.nft was
#     iif "lo" tcp dport 33000-33999 accept
#     tcp dport 33000-33999 drop
# with no conntrack exception. 33000-33999 lies inside the ephemeral range
# (net.ipv4.ip_local_port_range, 32768-60999), so the SYN-ACK of every OUTBOUND
# connection whose local port landed there was dropped: ~3.5% of edt1's outbound
# connections, in multi-second bursts per destination (edy-proxy-go R52: the
# public front-door VIP flapped ~30x/day; 29 of 29 failing connections in a
# capture used local ports 33000-33999, none of 9,079 others did).
#
# What this asserts:
#   static   the shipped rule accepts ct established,related BEFORE any drop, and
#            drops only ct state new; the nft range, the sysctl reservation and
#            the port base the session scripts use are one and the same range;
#            install.sh ships the sysctl drop-in; the firewall unit applies both
#            on start AND reload; deploy.sh reloads instead of `enable --now`.
#   checker  install.sh's own headless_rule_is_stateful (what --verify runs
#            against the LOADED table) accepts the shipped rule and rejects the
#            1.10.6 one.
#   staged   a DESTDIR install places both files, an upgrade over the old
#            stateless file replaces it, and --uninstall removes both.
#   kernel   in a private netns: a reply to an outbound connection from local
#            port 33005 gets through; a NEW inbound connection to a session port
#            from off-box is still dropped; loopback still reaches it; the OLD
#            rule reproduces the incident (mutation check: the test can fail);
#            and with the drop-in applied the allocator never hands out
#            33000-33999.
#
# Conventions follow tests/installer_tests.sh: one function per test, each run
# in a subshell, returns 0 (ok), 77 (SKIP) or 1 (FAIL).
set -uo pipefail

SRC="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
SELF="$SRC/tests/headless_nft_test.sh"
RULE="$SRC/hardening/edy-rdp-headless.nft"
SYSCTL_SRC="$SRC/hardening/edy-rdp-headless-sysctl.conf"
SYSCTL_DST=/etc/sysctl.d/90-edy-rdp-headless.conf
NFT_DST=/etc/nftables.d/edy-rdp-headless.nft
UNIT="$SRC/systemd/edy-rdp-firewall.service"
export JOURNAL_STREAM="${JOURNAL_STREAM:-headless_nft_test}"

# The 1.10.6 rule, verbatim: the mutation the kernel test must catch.
OLD_RULE='table inet edy_rdp_headless
delete table inet edy_rdp_headless
table inet edy_rdp_headless {
    chain input {
        type filter hook input priority filter; policy accept;
        iif "lo" tcp dport 33000-33999 accept
        tcp dport 33000-33999 drop
    }
}'

# ---------------------------------------------------------------------------
# The kernel half. Re-entered by this same script under `unshare -rn`: we are
# uid 0 only inside a user namespace we own, in a network namespace that has
# nothing but lo. A peer namespace (nested, also ours) is joined by a veth.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == --in-netns ]]; then
    exec python3 - "$RULE" "$SYSCTL_SRC" "$OLD_RULE" <<'PY'
import os, socket, subprocess, sys, time

rule, sysctl_conf, old_rule = sys.argv[1], sys.argv[2], sys.argv[3]
HOST, PEER = "10.231.61.1", "10.231.61.2"
fails = []

def sh(*cmd, check=True, **kw):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kw)
    if check and r.returncode:
        raise SystemExit("SETUP %s -> rc %d: %s" % (" ".join(cmd), r.returncode,
                                                  r.stdout.decode(errors="replace").strip()))
    return r

# the peer: a nested netns held open by a sleeping child
peer = subprocess.Popen(["unshare", "-n", "sleep", "60"])
time.sleep(0.2)
pid = str(peer.pid)
def in_peer(*cmd, **kw):
    return sh("nsenter", "-t", pid, "-n", *cmd, **kw)

PEER_SERVER = r'''
import socket, sys, threading
ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind(("0.0.0.0", 8080)); ls.listen(64)
print("ready", flush=True)
held = []
while True:
    c, _ = ls.accept(); held.append(c)
'''
PEER_CLIENT = r'''
import socket, sys
s = socket.socket(); s.settimeout(float(sys.argv[2]))
try:
    s.connect((sys.argv[1], int(sys.argv[3]))); print("connected")
except socket.timeout:
    print("timeout")
except OSError as e:
    print("error %s" % e.errno)
'''

srv = None
try:
    sh("ip", "link", "set", "lo", "up")
    sh("ip", "link", "add", "veth-h", "type", "veth", "peer", "name", "veth-p")
    sh("ip", "link", "set", "veth-p", "netns", pid)
    sh("ip", "addr", "add", HOST + "/24", "dev", "veth-h")
    sh("ip", "link", "set", "veth-h", "up")
    in_peer("ip", "link", "set", "lo", "up")
    in_peer("ip", "addr", "add", PEER + "/24", "dev", "veth-p")
    in_peer("ip", "link", "set", "veth-p", "up")
    srv = subprocess.Popen(["nsenter", "-t", pid, "-n", "python3", "-c", PEER_SERVER],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    assert srv.stdout.readline().strip() == b"ready", "peer server did not start"

    def load(text):
        r = subprocess.run(["nft", "-f", "-"], input=text.encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return r.returncode, r.stdout.decode(errors="replace").strip()

    def outbound(local_port, timeout=1.5):
        s = socket.socket(); s.settimeout(timeout)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((HOST, local_port)); s.connect((PEER, 8080)); return "connected"
        except socket.timeout:
            return "timeout"
        finally:
            s.close()

    # A session-port listener on the "host" (grd binds all interfaces).
    lst = socket.socket(); lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lst.bind(("0.0.0.0", 33006)); lst.listen(8)

    rc, out = load(open(rule).read())
    if rc:
        print("FAIL the shipped rule does not load: %s" % out); sys.exit(1)

    # 1. the incident: a reply to an outbound connection from a session-range port
    for lp in (33000, 33005, 33999):
        r = outbound(lp)
        if r != "connected":
            fails.append("outbound from local port %d -> %s:8080: %s (the reply was dropped - I61)" % (lp, PEER, r))
    # 2. the guard: a NEW connection to a session port from off-box is still dropped
    r = in_peer("python3", "-c", PEER_CLIENT, HOST, "1.5", "33006", check=False).stdout.decode().strip()
    if r != "timeout":
        fails.append("NEW inbound %s -> %s:33006 was '%s', want 'timeout' (dropped)" % (PEER, HOST, r))
    # 3. loopback still reaches a session port
    c = socket.socket(); c.settimeout(1.5)
    try:
        c.connect(("127.0.0.1", 33006))
    except OSError as e:
        fails.append("loopback -> 127.0.0.1:33006 failed: %s" % e)
    finally:
        c.close()
    # 4. ports outside the range are untouched
    if outbound(32900) != "connected":
        fails.append("outbound from local port 32900 failed (outside the range)")

    # 5. mutation check: the 1.10.6 rule MUST reproduce the incident here, or
    #    test 1 proves nothing about this kernel.
    rc, out = load(old_rule)
    if rc:
        fails.append("the old rule did not load: %s" % out)
    elif outbound(33005, timeout=1.0) != "timeout":
        fails.append("MUTATION NOT CAUGHT: with the 1.10.6 stateless rule an outbound connection "
                     "from 33005 still connected, so check 1 cannot tell the rules apart")
    load(open(rule).read())

    # 6. the reservation: with the shipped drop-in applied and the ephemeral
    #    range narrowed to straddle 33000-33999, no unbound connect() may be
    #    handed a session port. Without the drop-in ~98% of them would be.
    with open("/proc/sys/net/ipv4/ip_local_port_range", "w") as f:
        f.write("32990 34010\n")
    r = sh("sysctl", "-q", "-p", sysctl_conf, check=False)
    if r.returncode:
        fails.append("sysctl -p %s failed: %s" % (sysctl_conf, r.stdout.decode().strip()))
    else:
        got = open("/proc/sys/net/ipv4/ip_local_reserved_ports").read().strip()
        if got != "33000-33999":
            fails.append("after sysctl -p the reserved list is '%s', want 33000-33999" % got)
        held, bad = [], []
        for _ in range(15):
            s = socket.socket(); s.settimeout(1.5); s.connect((PEER, 8080))
            held.append(s)
            lp = s.getsockname()[1]
            if 33000 <= lp <= 33999:
                bad.append(lp)
        for s in held:
            s.close()
        if bad:
            fails.append("with the reservation applied, connect() still got session ports %s" % bad)
finally:
    # Both children, or the caller's $(...) never sees EOF: the peer server
    # holds an inherited copy of its stdout/stderr.
    for p in (srv, peer):
        if p is not None:
            p.kill(); p.wait()

for f in fails:
    print("FAIL " + f)
sys.exit(1 if fails else 0)
PY
fi

FAILED=0
run_test() {
    local out rc
    out="$("$1" 2>&1)"; rc=$?
    case $rc in
      0)  printf '  ok   %s\n' "$1" ;;
      77) printf '  SKIP %s\n' "$1" ;;
      *)  printf '  FAIL %s\n' "$1"; FAILED=1 ;;
    esac
    [[ -n "$out" && ( $rc -ne 0 || -n "${VERBOSE:-}" ) ]] && sed 's/^/         /' <<<"$out"
    return 0
}

# The chain's rules in order, comments and blank lines stripped.
rules_of() { sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" \
             | awk '/^chain input/{c=1; next} c && /^}/{exit} c && NF && !/^type /'; }

# ---------------------------------------------------------------------------
static_rule_is_stateful() {
    local bad=0 first r
    mapfile -t r < <(rules_of "$RULE")
    ((${#r[@]})) || { echo "no rules parsed out of $RULE"; return 1; }
    first="${r[0]}"
    [[ "$first" == "ct state established,related accept" ]] \
        || { echo "first rule is '$first', want 'ct state established,related accept'"; bad=1; }
    local x seen_drop=0
    for x in "${r[@]}"; do
        if [[ "$x" == *" drop" ]]; then
            seen_drop=1
            [[ "$x" == "ct state new "* ]] || { echo "unscoped drop: '$x' (must be 'ct state new ...')"; bad=1; }
        fi
    done
    ((seen_drop)) || { echo "the rule no longer drops anything - the session ports are open to the LAN"; bad=1; }
    printf '%s\n' "${r[@]}" | grep -qx 'iif "lo" tcp dport 33000-33999 accept' \
        || { echo "loopback accept for 33000-33999 is gone (guacd dials 127.0.0.1:<port>)"; bad=1; }
    return $bad
}

static_ranges_agree() {
    local bad=0 nft_range sys_range base wl_base reap_base
    nft_range="$(rules_of "$RULE" | sed -n 's/^ct state new tcp dport \([0-9]*-[0-9]*\) drop$/\1/p')"
    sys_range="$(sed -n 's/^net\.ipv4\.ip_local_reserved_ports *= *//p' "$SYSCTL_SRC")"
    base="$(sed -n 's/^HEADLESS_PORT_BASE=\${HEADLESS_PORT_BASE:-\([0-9]*\)}$/\1/p' "$SRC/headless/edy-rdp-headless-start.sh")"
    reap_base="$(sed -n 's/^HEADLESS_PORT_BASE = \([0-9]*\)$/\1/p' "$SRC/relay/edy_rdp_reaper.py")"
    [[ -n "$nft_range" && "$nft_range" == "$sys_range" ]] \
        || { echo "nft drops '$nft_range' but the sysctl reserves '$sys_range'"; bad=1; }
    [[ -n "$base" && "$nft_range" == "$base-$((base + 999))" ]] \
        || { echo "session ports are $base + (uid-1000), 1000 uids, but the rule covers '$nft_range'"; bad=1; }
    [[ "$reap_base" == "$base" ]] \
        || { echo "reaper HEADLESS_PORT_BASE=$reap_base, start script $base"; bad=1; }
    return $bad
}

static_installer_and_unit_wiring() {
    local bad=0
    eval "$(sed -n '/^# BEGIN-MANIFEST/,/^# END-MANIFEST/p' "$SRC/install.sh")"
    printf '%s\n' "${SYSFILES[@]}" | grep -qx "hardening/edy-rdp-headless.nft:$NFT_DST" \
        || { echo "SYSFILES no longer installs $NFT_DST"; bad=1; }
    printf '%s\n' "${SYSFILES[@]}" | grep -qx "hardening/edy-rdp-headless-sysctl.conf:$SYSCTL_DST" \
        || { echo "SYSFILES does not install $SYSCTL_DST (I61 reserved ports)"; bad=1; }
    local want
    for want in "ExecStart=/usr/sbin/nft -f $NFT_DST" "ExecReload=/usr/sbin/nft -f $NFT_DST" \
                "ExecStart=-/usr/sbin/sysctl -q -p $SYSCTL_DST" \
                "ExecReload=-/usr/sbin/sysctl -q -p $SYSCTL_DST" \
                "ExecReload=/usr/sbin/nft -f /etc/nftables.d/edy-rdp-guacd.nft"; do
        grep -qxF -- "$want" "$UNIT" || { echo "$UNIT lacks: $want"; bad=1; }
    done
    # The sysctl must come AFTER both nft loads: a failed sysctl ('-') must never
    # be what stands between boot and the firewall.
    local ln_s ln_n
    ln_s="$(grep -n '^ExecStart=-/usr/sbin/sysctl' "$UNIT" | cut -d: -f1)"
    ln_n="$(grep -n "^ExecStart=/usr/sbin/nft -f $NFT_DST" "$UNIT" | cut -d: -f1)"
    [[ -n "$ln_s" && -n "$ln_n" && "$ln_s" -gt "$ln_n" ]] \
        || { echo "the sysctl ExecStart must follow the nft loads"; bad=1; }
    # An active oneshot ignores `enable --now`; the upgrade path must reload it.
    if grep -qE 'enable --now edy-rdp-firewall' "$SRC/deploy.sh"; then
        echo "deploy.sh still uses 'enable --now edy-rdp-firewall' (a no-op on an active unit: old rules stay loaded)"; bad=1
    fi
    grep -q 'reload-or-restart edy-rdp-firewall.service' "$SRC/deploy.sh" \
        || { echo "deploy.sh never reloads edy-rdp-firewall.service"; bad=1; }
    grep -qE '^ *\(\(WITH_UNITS\)\) \|\| refresh_active_firewall$' "$SRC/deploy.sh" \
        || { echo "deploy.sh no longer refreshes an active firewall on a plain deploy (self-update path)"; bad=1; }
    return $bad
}

# install.sh's checker is what --verify runs against `nft list table`. Extract
# the function verbatim (install.sh itself cannot be sourced: it runs).
checker_accepts_new_rejects_old() {
    local fn bad=0
    fn="$(sed -n '/^headless_rule_is_stateful() {$/,/^}$/p' "$SRC/install.sh")"
    [[ -n "$fn" ]] || { echo "install.sh lost headless_rule_is_stateful()"; return 1; }
    eval "$fn"
    headless_rule_is_stateful < "$RULE" || { echo "checker REJECTS the shipped rule"; bad=1; }
    headless_rule_is_stateful <<<"$OLD_RULE" && { echo "checker ACCEPTS the 1.10.6 stateless rule"; bad=1; }
    # the shape `nft list table` prints (no comments, tabs)
    headless_rule_is_stateful <<<$'table inet edy_rdp_headless {\n\tchain input {\n\t\ttype filter hook input priority filter; policy accept;\n\t\tct state established,related accept\n\t\tiif "lo" tcp dport 33000-33999 accept\n\t\tct state new tcp dport 33000-33999 drop\n\t}\n}' \
        || { echo "checker REJECTS the nft-list rendering of the shipped rule"; bad=1; }
    # established/related AFTER the drop is not good enough
    headless_rule_is_stateful <<<$'iif "lo" tcp dport 33000-33999 accept\ntcp dport 33000-33999 drop\nct state established,related accept' \
        && { echo "checker accepts an established/related rule that comes after the drop"; bad=1; }
    return $bad
}

staged_install_upgrade_uninstall() {
    local T bad=0 out
    T="$(mktemp -d)"; trap 'rm -rf -- "$T"' RETURN
    install -d -m 0755 -- "$T/src" "$T/root/etc/nftables.d"
    tar -C "$SRC" --exclude=.git --exclude=.env --exclude=__pycache__ \
        --exclude=venv --exclude=venv.env -cf - . | tar -C "$T/src" -xf -
    # an upgrade: the 1.10.6 stateless file is what the host holds today
    printf '%s\n' "$OLD_RULE" > "$T/root$NFT_DST"
    out="$(DESTDIR="$T/root" "$T/src/install.sh" 2>&1)" \
        || { echo "staged install failed:"; tail -n 8 <<<"$out"; return 1; }
    cmp -s "$T/root$NFT_DST" "$RULE" \
        || { echo "the upgrade did not replace $NFT_DST with the shipped stateful rule"; bad=1; }
    cmp -s "$T/root$SYSCTL_DST" "$SYSCTL_SRC" \
        || { echo "$SYSCTL_DST was not installed (or differs from the shipped drop-in)"; bad=1; }
    [[ "$(stat -c %a "$T/root$SYSCTL_DST" 2>/dev/null)" == 644 ]] \
        || { echo "$SYSCTL_DST is not mode 0644"; bad=1; }
    out="$(DESTDIR="$T/root" "$T/src/install.sh" --uninstall 2>&1)" \
        || { echo "staged uninstall failed:"; tail -n 8 <<<"$out"; return 1; }
    [[ ! -e "$T/root$NFT_DST" ]] || { echo "--uninstall left $NFT_DST"; bad=1; }
    [[ ! -e "$T/root$SYSCTL_DST" ]] || { echo "--uninstall left $SYSCTL_DST"; bad=1; }
    return $bad
}

kernel_netns_behaviour() {
    command -v nft >/dev/null 2>&1 || PATH="$PATH:/usr/sbin:/sbin"
    local t
    for t in unshare nsenter nft ip sysctl python3; do
        command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not available"; return 77; }
    done
    unshare -rn true 2>/dev/null \
        || { echo "SKIP: unprivileged user+network namespaces are not available here"; return 77; }
    unshare -rn nft list ruleset >/dev/null 2>&1 \
        || { echo "SKIP: nft cannot run inside an unprivileged netns here"; return 77; }
    local out rc
    out="$(timeout 60 unshare -rn bash "$SELF" --in-netns 2>&1)"; rc=$?
    printf '%s\n' "$out"
    if (( rc != 0 )) && grep -q '^SETUP ' <<<"$out"; then
        return 77   # the sandbox could not be built; that is not a verdict on the rule
    fi
    return $rc
}

for t in static_rule_is_stateful \
         static_ranges_agree \
         static_installer_and_unit_wiring \
         checker_accepts_new_rejects_old \
         staged_install_upgrade_uninstall \
         kernel_netns_behaviour; do
    run_test "$t"
done
exit $FAILED
