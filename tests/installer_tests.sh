#!/usr/bin/env bash
#
# tests/installer_tests.sh - the installer's own regression suite. Run by
# run_tests.sh; runnable alone. Non-root, no host state touched: every install
# is STAGED (DESTDIR=<tmp>) out of a temp COPY of the checkout, so the .env that
# install.sh places, the venv the bootstrap builds and the links it makes all
# land under one mktemp -d that is removed on exit. Nothing here ever runs
# podman, systemctl, mount, apt or a package manager.
#
# WHY THIS EXISTS: from 1.3.0 to 1.3.2 no install, deploy or --verify completed.
# Pre-flight check 5 assigned leftover="$(... | grep -o ...)" under
# `set -Eeuo pipefail`; a unit that renders CLEAN is grep's no-match case, so the
# pipeline returned 1 and set -e exited after "ok 3b." with no message
# (KNOWN_ISSUES I41). Nothing ran install.sh to completion anywhere but a host,
# and on the host the job wrapper masked the exit code. Test 1 below runs a
# staged install to completion and asserts on what it produced: the regression
# test that was missing. The rest cover the 1.4.0 contract: .env placement and
# validation (lib/edy-rdp-env.sh), requires.txt as the one prerequisite list
# (lib/edy-rdp-requires.sh), the start-time bootstrap's venv decision, the
# pulse-bind script's rootless --check plan and what it refuses to mount, and
# deploy.sh itself staged end to end - including its refusal of a stale .env
# BEFORE the payload alias swaps.
#
# Conventions: one function per test, named exactly as SPEC section 6 lists
# them; each runs in a subshell, prints its findings, returns 0 (ok), 77 (SKIP)
# or 1 (FAIL). Values a test writes into a .env are never echoed - only the key.
set -uo pipefail

SRC="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
TMP="$(mktemp -d)"
# The suite's temp root is the ONLY thing removed recursively, and it is a
# mktemp of ours, never a path under /usr, /etc or /var (install.sh's removal
# primitives explain why that distinction matters in this project).
trap 'rm -rf -- "$TMP"' EXIT

# The version install.sh stamps into a placed .env is whatever VERSION says; the
# test reads the same file rather than pinning a literal that rots on every bump.
WANT_VERSION="$(cat "$SRC/VERSION" 2>/dev/null || echo unknown)"

# The bootstrap and pulse-bind also `logger` when not under systemd. Set
# JOURNAL_STREAM so a test run does not write its noise into the host's syslog.
export JOURNAL_STREAM="${JOURNAL_STREAM:-installer_tests}"

FAILED=0
run_test() {   # $1 = test function; prints "  ok/FAIL/SKIP <name>" + captured findings
    local out rc
    out="$("$1" 2>&1)"; rc=$?
    case $rc in
      0)  printf '  ok   %s\n' "$1" ;;
      77) printf '  SKIP %s\n' "$1" ;;
      *)  printf '  FAIL %s\n' "$1"; FAILED=1 ;;
    esac
    [[ -n "$out" && $rc -ne 0 ]] && sed 's/^/         /' <<<"$out"
    return 0
}

# ONE manifest, install.sh's - read exactly the way deploy.sh reads it, so the
# tests assert on the same PAGE/LIBEXEC/LIBS/UNITS/SYSFILES the installer acts on.
load_manifest() { eval "$(sed -n '/^# BEGIN-MANIFEST/,/^# END-MANIFEST/p' "$1/install.sh")"; }
load_manifest "$SRC"
[[ -n "${PROJECT:-}" && ${#PAGE[@]} -gt 0 && ${#UNITS[@]} -gt 0 ]] \
    || { echo "  FAIL could not read the manifest out of $SRC/install.sh"; exit 1; }

# What the checkout held BEFORE the run. A developer may keep a .env in the tree
# for their own testing (.gitignore allows exactly that); the suite must only
# complain about files IT left behind, so the comparison is against this snapshot.
PRE_EXISTING=""
for f in .env venv venv.env; do [[ -e "$SRC/$f" ]] && PRE_EXISTING+=" $f"; done

# A working copy of the checkout WITHOUT .git, a stray dev .env, bytecode caches
# or a venv, so a staged install places .env into the COPY and a KIND=dev install
# never touches the real tree. tar keeps exec bits, which the installer asserts.
fresh_tree() {   # $1 = dir; creates $1/src (the copy) and $1/root (the DESTDIR)
    install -d -m 0755 -- "$1/src" "$1/root"
    tar -C "$SRC" --exclude=.git --exclude=.env --exclude=__pycache__ \
        --exclude=venv --exclude=venv.env -cf - . | tar -C "$1/src" -xf -
}

staged_install() {   # $1 = tree dir, $2... = install.sh args; output on stdout, rc passed through
    DESTDIR="$1/root" "$1/src/install.sh" "${@:2}" 2>&1
}

# A file another owner ships per the spec. Naming the spec section makes a FAIL
# here read as "not landed yet", not as a broken test.
need_file() {   # $1 = path relative to the tree root, $2 = spec section
    [[ -e "$SRC/$1" ]] && return 0
    echo "missing $1 (SPEC $2) - not landed yet?"; return 1
}

# The prerequisites for every bootstrap run: a .env that validates on THIS host.
# .envdefault ships EDY_RDP_ADMIN_GROUP=sudo, which exists on Debian/Ubuntu but not
# on every distro the tests may run on; the bootstrap validates without --staged
# (it runs on a live host), so the copy names the caller's own primary group.
bootstrap_env() {   # $1 = tree dir; prints the path of the test .env
    local f="$1/bootstrap.env"
    if [[ ! -f "$f" ]]; then
        cp -- "$1/src/.env" "$f" && printf 'EDY_RDP_ADMIN_GROUP=%s\n' "$(id -gn)" >> "$f"
    fi
    printf '%s\n' "$f"
}

run_bootstrap() {   # $1 = tree dir, $2 = requirements file, $3 = wheels dir, $4... = extra args
    local T=$1
    # The install path always exists on a host (install.sh linked out of it);
    # the bootstrap writes venv.env INTO it and does not create it.
    install -d -m 0755 -- "$T/ip"
    "$T/src/bootstrap/edy-rdp-bootstrap.sh" \
        --install-conf "$T/root/etc/$PROJECT/install.conf" \
        --env "$(bootstrap_env "$T")" --envdefault "$T/src/.envdefault" \
        --install-path "$T/ip" --payload "$T/src" \
        --requires "$SRC/requires.txt" --requirements "$2" --wheels "$3" \
        --required-env "${REQUIRED_ENV[*]}" --skip-prereqs "${@:4}" 2>&1
}

# ---------------------------------------------------------------------------
# 1. the I41 regression test: a staged install runs to completion and produces
#    everything the manifest declares.
installer_staged_install_completes() {
    local T="$TMP/main" out rc bad=0 f n
    fresh_tree "$T"
    out="$(staged_install "$T" --with-units)"; rc=$?
    printf '%s\n' "$out" > "$T/install.out"
    if (( rc != 0 )); then
        echo "install.sh exited $rc (the I41 silent abort exits 1 with no FATAL line):"
        tail -n 6 <<<"$out"; return 1
    fi
    for n in 'ok   5.' 'ok   6.' 'ok   7.' 'ok   9.' 'installed (dev)'; do
        grep -qF -- "$n" <<<"$out" || { echo "output lacks '$n'"; bad=1; }
    done
    local cpkg="$T/root/usr/share/cockpit/$PAGE_NAME" lib="$T/root$LIBEXECDIR"
    for f in "${PAGE[@]}"; do
        [[ -L "$cpkg/$f" ]] || { echo "$cpkg/$f is not a symlink"; bad=1; }
    done
    for f in "${PAGE_DIRS[@]}"; do
        [[ -d "$cpkg/$f" && ! -L "$cpkg/$f" ]] || { echo "$cpkg/$f is not a real directory"; bad=1; }
    done
    for f in "${LIBEXEC[@]}" "${LIBS[@]}"; do
        [[ -L "$lib/${f#*:}" ]] || { echo "$lib/${f#*:} is not a symlink"; bad=1; }
    done
    for f in "${UNITS[@]}"; do
        if [[ ! -f "$T/root$UNITDIR/$f" ]]; then echo "$UNITDIR/$f was not rendered"; bad=1
        elif grep -v '^#' "$T/root$UNITDIR/$f" | grep -q '@[A-Z_]\+@'; then
            echo "$UNITDIR/$f still carries a placeholder on a directive line"; bad=1
        fi
    done
    for f in "${SYSFILES[@]}"; do
        [[ -f "$T/root${f#*:}" ]] || { echo "${f#*:} was not installed"; bad=1; }
    done
    grep -q '^REQUIRED_ENV=' "$T/root/etc/$PROJECT/install.conf" 2>/dev/null \
        || { echo "install.conf lacks REQUIRED_ENV= (the bootstrap reads it; SPEC 2.6)"; bad=1; }
    return $bad
}

# 2. the same staged tree passes its own --verify (which the I41 abort also killed).
installer_staged_verify_passes() {
    local T="$TMP/main" out rc last
    [[ -f "$T/install.out" ]] || { echo "needs installer_staged_install_completes first"; return 1; }
    out="$(staged_install "$T" --verify)"; rc=$?
    last="$(sed -e '/^[[:space:]]*$/d' <<<"$out" | tail -n 1)"
    if (( rc != 0 )) || [[ "$last" != "verify: PASS" ]]; then
        echo "--verify exited $rc, last line '$last':"
        grep -E '^(FATAL|  FAIL)' <<<"$out" | head -n 12; return 1
    fi
}

# 3. D1: a missing .env is PLACED from .envdefault (derived, stamped) and validates.
env_place_missing_env() {
    # Two statements: `local a=x b="$a/y"` expands both words before either binds
    # (install.sh's render_unit_to_stdout explains the same trap).
    local T="$TMP/main" first bad=0
    local env="$T/src/.env"
    need_file lib/edy-rdp-env.sh 2.8 || return 1
    [[ -f "$T/install.out" ]] || { echo "needs installer_staged_install_completes first"; return 1; }
    [[ -f "$env" ]] || { echo "install.sh did not place $env"; return 1; }
    first="$(head -n 1 "$env")"
    [[ "$first" == '# '* ]] || { echo "line 1 is not a comment"; bad=1; }
    grep -qF "placed by install.sh $WANT_VERSION" <<<"$first" \
        || { echo "line 1 lacks 'placed by install.sh $WANT_VERSION'"; bad=1; }
    . "$T/src/lib/edy-rdp-env.sh" || { echo "cannot source lib/edy-rdp-env.sh"; return 1; }
    local problems
    if ! problems="$(env_validate "$env" "$T/src/.envdefault" --staged "${REQUIRED_ENV[@]}")"; then
        echo "placed .env does not validate:"; sed 's/^/  /' <<<"$problems"; bad=1
    fi
    [[ "$(env_get "$env" GUACD_IMAGE)" == "$(env_get "$T/src/.envdefault" GUACD_IMAGE)" ]] \
        || { echo "GUACD_IMAGE differs from .envdefault's"; bad=1; }
    return $bad
}

# 4. D1: an existing .env keeps the operator's value and gains ONLY the keys it lacked.
env_place_reconcile_keeps_values() {
    local T="$TMP/reconcile" env out rc k bad=0
    need_file lib/edy-rdp-env.sh 2.8 || return 1
    fresh_tree "$T"; env="$T/src/.env"
    {
        printf 'EDY_RDP_GUACD=127.0.0.1:4899\n'
        for k in "${REQUIRED_ENV[@]}"; do
            [[ "$k" == EDY_RDP_GUACD || "$k" == EDY_RDP_PULSE_SEAT_UID ]] && continue
            grep -m1 "^$k=" "$T/src/.envdefault"
        done
    } > "$env"
    out="$(staged_install "$T" --with-units)"; rc=$?
    if (( rc != 0 )); then echo "install.sh exited $rc:"; grep -E '^(FATAL|  FAIL)' <<<"$out" | head -n 6; return 1; fi
    grep -qF 'reconciled' <<<"$out" || { echo "output lacks 'reconciled'"; bad=1; }
    . "$T/src/lib/edy-rdp-env.sh" || { echo "cannot source lib/edy-rdp-env.sh"; return 1; }
    [[ "$(env_get "$env" EDY_RDP_GUACD)" == "127.0.0.1:4899" ]] \
        || { echo "EDY_RDP_GUACD was changed (an operator value must never be touched)"; bad=1; }
    local hdr key
    hdr="$(grep -n -m1 "added by install.sh $WANT_VERSION" "$env" | cut -d: -f1)"
    key="$(grep -n -m1 '^EDY_RDP_PULSE_SEAT_UID=auto$' "$env" | cut -d: -f1)"
    [[ -n "$hdr" ]] || { echo "no '# added by install.sh $WANT_VERSION' header"; bad=1; }
    [[ -n "$key" ]] || { echo "EDY_RDP_PULSE_SEAT_UID=auto was not appended"; bad=1; }
    [[ -n "$hdr" && -n "$key" && "$key" -gt "$hdr" ]] \
        || { echo "EDY_RDP_PULSE_SEAT_UID is not under the 'added by' header"; bad=1; }
    return $bad
}

# 5. D1: a bad value is REFUSED naming the key, and nothing is linked (fail closed).
#    The values themselves are never printed - only the key and the rc.
env_validate_refuses_bad_values() {
    need_file lib/edy-rdp-env.sh 2.8 || return 1
    local bad=0
    bad_env_case "$TMP/bad1" 'EDY_RDP_LOG_LEVEL' 'LOUD'    'EDY_RDP_LOG_LEVEL: must be one of' || bad=1
    bad_env_case "$TMP/bad2" 'EDY_RDP_STATE_FILE' '$HOME/x' 'contains $'                        || bad=1
    bad_env_case "$TMP/bad3" 'EDY_RDP_DOOR_PASSWORD' 'hunter2' 'looks like a secret VALUE'      || bad=1
    return $bad
}
bad_env_case() {   # $1 = tree dir, $2 = KEY, $3 = value, $4 = phrase the refusal must carry
    local T=$1 key=$2 val=$3 phrase=$4 out rc ok=1
    fresh_tree "$T"
    # .envdefault first (every other key valid), the bad line LAST so it is the
    # value in force - the grammar takes the last assignment of a key.
    { cat "$T/src/.envdefault"; printf '%s=%s\n' "$key" "$val"; } > "$T/src/.env"
    out="$(staged_install "$T" --with-units)"; rc=$?
    (( rc != 0 ))                     || { echo "$key: install.sh exited 0 - the bad value was accepted"; ok=0; }
    grep -qF -- "$key" <<<"$out"      || { echo "$key: the refusal does not name the key"; ok=0; }
    grep -qF -- "$phrase" <<<"$out"   || { echo "$key: the refusal lacks '$phrase' (rc=$rc)"; ok=0; }
    [[ -z "$(find "$T/root" -type l -print -quit 2>/dev/null)" ]] \
        || { echo "$key: something was linked under DESTDIR although the .env was refused"; ok=0; }
    (( ok )) && return 0
    # Show what the installer said, with the test's own value redacted.
    grep -E '^(FATAL|  FAIL|    )' <<<"$out" | sed "s|${val//|/\\|}|<value>|g" | head -n 6
    return 1
}

# 6. lib/edy-rdp-requires.sh parses the real requires.txt and compares versions.
requires_lib_parses_and_compares() {
    need_file lib/edy-rdp-requires.sh 2.9 || return 1
    . "$SRC/lib/edy-rdp-requires.sh" || { echo "cannot source lib/edy-rdp-requires.sh"; return 1; }
    local bad=0
    # req_load fills arrays in THIS shell, so it must not run inside $( ).
    req_load "$SRC/requires.txt" > "$TMP/req_load.out" \
        || { echo "req_load failed: $(cat "$TMP/req_load.out")"; return 1; }
    (( ${#REQ_NAMES[@]} == 9 )) || { echo "REQ_NAMES has ${#REQ_NAMES[@]} entries, want 9"; bad=1; }
    [[ "${REQ_MIN[freerdp]:-}" == "3.0" ]] || { echo "REQ_MIN[freerdp] is '${REQ_MIN[freerdp]:-}', want 3.0"; bad=1; }
    [[ "$(req_image_ref)" == ghcr.io/skylark-software/janua@sha256:* ]] \
        || { echo "req_image_ref is '$(req_image_ref)', want the Janua digest ref (SPEC 4.8)"; bad=1; }
    local pair
    for pair in '3.31.0 3.0' '0.9.17 0.9.16' '360-1 266'; do
        # shellcheck disable=SC2086
        req_version_ge $pair || { echo "req_version_ge $pair should be true"; bad=1; }
    done
    req_version_ge 0.9.16 0.9.17 && { echo "req_version_ge 0.9.16 0.9.17 should be false"; bad=1; }
    [[ "$(req_norm 21.1.22-1ubuntu1)" == "21.1.22" ]] \
        || { echo "req_norm 21.1.22-1ubuntu1 is '$(req_norm 21.1.22-1ubuntu1)'"; bad=1; }
    return $bad
}

# 7. a missing tool is reported by name, with the command that fixes it.
requires_lib_reports_missing_tool() {
    need_file lib/edy-rdp-requires.sh 2.9 || return 1
    . "$SRC/lib/edy-rdp-requires.sh" || { echo "cannot source lib/edy-rdp-requires.sh"; return 1; }
    local f="$TMP/requires.fake" bad=0 name=edyrdp-nonexistent-tool fix zeros
    zeros="$(printf '0%.0s' {1..64})"
    printf '%s >=1.0 0\nguacd-image x sha256:%s\n' "$name" "$zeros" > "$f"
    req_load "$f" || { echo "req_load refused the fixture"; return 1; }
    # req_check fills REQ_MISSING in THIS shell, so it must not run inside $( ).
    req_check > "$TMP/req_check.out"
    (( $? == 1 )) || { echo "req_check rc should be 1 for a missing tool"; bad=1; }
    [[ ${#REQ_MISSING[@]} -eq 1 && "${REQ_MISSING[0]}" == "$name" ]] \
        || { echo "REQ_MISSING is '${REQ_MISSING[*]:-}', want '$name'"; bad=1; }
    fix="$(req_fix_command "$name")"
    grep -qF -- "$name" <<<"$fix" || { echo "req_fix_command does not name $name: '$fix'"; bad=1; }
    if [[ -n "$(req_detect_pm)" ]]; then
        grep -qF -- 'install' <<<"$fix" || { echo "req_fix_command lacks 'install' although a package manager exists: '$fix'"; bad=1; }
    fi
    return $bad
}

# 8. D2: an empty requirements.txt means the system python and NO venv.
bootstrap_empty_requirements_uses_system_python() {
    local T="$TMP/main" out rc bad=0
    need_file bootstrap/edy-rdp-bootstrap.sh 2.7 || return 1
    [[ -f "$T/install.out" ]] || { echo "needs installer_staged_install_completes first"; return 1; }
    printf '# nothing: the relay is stdlib-only\n' > "$T/empty.txt"
    out="$(run_bootstrap "$T" "$T/empty.txt" "$T/nowheels")"; rc=$?
    if (( rc != 0 )); then echo "bootstrap exited $rc:"; tail -n 6 <<<"$out"; return 1; fi
    grep -qx 'EDY_RDP_PYTHON=/usr/bin/python3' "$T/ip/venv.env" 2>/dev/null \
        || { echo "venv.env does not say EDY_RDP_PYTHON=/usr/bin/python3"; bad=1; }
    [[ ! -e "$T/ip/venv" ]] || { echo "a venv was created for an empty requirements.txt"; bad=1; }
    return $bad
}

# 9. D2: a requirement makes the bootstrap build the venv OFFLINE from a vendored
#    wheel, idempotently. The wheel is built by tests/make_wheel.py - no network.
bootstrap_builds_venv_offline_and_is_idempotent() {
    local T="$TMP/main" out rc bad=0
    local py="$T/ip/venv/bin/python3"
    need_file bootstrap/edy-rdp-bootstrap.sh 2.7 || return 1
    [[ -f "$T/install.out" ]] || { echo "needs installer_staged_install_completes first"; return 1; }
    python3 -c 'import venv, ensurepip' 2>/dev/null \
        || { echo "python3 lacks venv/ensurepip (python3-venv not installed)"; return 77; }
    python3 "$SRC/tests/make_wheel.py" "$T/wheels" > /dev/null || { echo "make_wheel.py failed"; return 1; }
    printf 'edyrdp_testpkg==0.0.1\n' > "$T/reqs.txt"
    out="$(run_bootstrap "$T" "$T/reqs.txt" "$T/wheels")"; rc=$?
    if (( rc != 0 )); then echo "bootstrap exited $rc:"; tail -n 8 <<<"$out"; return 1; fi
    grep -qx "EDY_RDP_PYTHON=$py" "$T/ip/venv.env" 2>/dev/null \
        || { echo "venv.env does not point at $py"; bad=1; }
    [[ -x "$py" ]] && "$py" -c 'import edyrdp_testpkg' 2>/dev/null \
        || { echo "the venv python cannot import the wheel's package"; bad=1; }
    [[ -f "$T/ip/venv/.edy-rdp-bootstrap" ]] \
        || { echo "the venv carries no .edy-rdp-bootstrap marker (a stale venv could never be reclaimed)"; bad=1; }
    [[ "$(cat "$T/ip/venv/.requirements.sha" 2>/dev/null)" == "$(sha256sum "$T/reqs.txt" | cut -d' ' -f1)" ]] \
        || { echo ".requirements.sha does not match sha256 of requirements"; bad=1; }
    out="$(run_bootstrap "$T" "$T/reqs.txt" "$T/wheels")"; rc=$?
    (( rc == 0 )) || { echo "second run exited $rc"; bad=1; }
    grep -qF 'venv: current' <<<"$out" || { echo "second run did not log 'venv: current' (not idempotent)"; bad=1; }
    out="$(run_bootstrap "$T" "$T/reqs.txt" "$T/wheels" --check)"; rc=$?
    (( rc == 0 )) || { echo "--check after a current build exited $rc (it must have nothing to do)"; tail -n 4 <<<"$out"; bad=1; }
    return $bad
}

# 10. D3: pulse-bind --check prints its plan, needs no root, mounts nothing.
pulse_bind_check_mode() {
    need_file pulse/edy-rdp-pulse-bind.sh 4.6 || return 1
    local dir="$TMP/pulse" out rc bad=0
    out="$(EDY_RDP_PULSE_DIR="$dir" "$SRC/pulse/edy-rdp-pulse-bind.sh" --seat-uid 4242 --check 2>&1)"; rc=$?
    (( rc == 0 )) || { echo "--check exited $rc"; bad=1; }
    grep -qF 'plan:' <<<"$out"                 || { echo "no 'plan:' line"; bad=1; }
    grep -qF 'check: no changes made' <<<"$out" || { echo "no 'check: no changes made' line"; bad=1; }
    grep -qF '/run/user/4242/pulse/native' <<<"$out" || { echo "the plan does not derive the seat socket from --seat-uid"; bad=1; }
    if mountpoint -q "$dir" 2>/dev/null || [[ -e "$dir/native" ]]; then
        echo "--check changed something under $dir"; bad=1
    fi
    (( bad )) && sed 's/^/  /' <<<"$out"
    return $bad
}

# 10b. D3 security: pulse-bind vets what root is about to mount, and --check
#      applies the same vetting so it is provable without root. A symlink where
#      the seat socket should be, a socket owned by somebody else, and a symlink
#      planted where the TARGET goes are each refused naming the path; the seat
#      user's own real socket is accepted. Sockets are bound by RELATIVE path
#      (python chdir) because AF_UNIX paths are capped at 108 bytes and $TMP is
#      wherever TMPDIR points.
pulse_bind_refuses_unsafe_seat_socket() {
    need_file pulse/edy-rdp-pulse-bind.sh 4.6 || return 1
    local d="$TMP/pulse-unsafe" me bad=0
    me="$(id -u)"
    install -d -m 0755 -- "$d/seat" "$d/dir-planted"
    python3 - "$d/seat" <<'PY' || { echo "cannot create a test socket"; return 1; }
import os, socket, sys
os.chdir(sys.argv[1]); socket.socket(socket.AF_UNIX).bind("real")
PY
    ln -s -- "$d/seat/real" "$d/seat/native"
    ln -s -- /etc/hostname "$d/dir-planted/native"
    pulse_check_case "symlinked seat socket"  "$d/dir" "$d/seat/native" "$me"  1 "$d/seat/native is a symlink - refusing" || bad=1
    pulse_check_case "foreign-owned socket"   "$d/dir" "$d/seat/real"   4242  1 "not a socket owned by uid 4242"          || bad=1
    pulse_check_case "planted target symlink" "$d/dir-planted" "$d/seat/real" "$me" 1 "$d/dir-planted/native is a symlink" || bad=1
    pulse_check_case "own real socket"        "$d/dir" "$d/seat/real"   "$me"  0 "seat=$d/seat/real (exists)"             || bad=1
    return $bad
}
pulse_check_case() {   # $1 = label, $2 = bind dir, $3 = seat socket, $4 = uid, $5 = want rc, $6 = phrase
    local out rc
    out="$(EDY_RDP_PULSE_DIR="$2" EDY_RDP_PULSE_SEAT_SOCKET="$3" \
           "$SRC/pulse/edy-rdp-pulse-bind.sh" --seat-uid "$4" --check 2>&1)"; rc=$?
    if (( rc != $5 )) || ! grep -qF -- "$6" <<<"$out"; then
        echo "$1: --check exited $rc (want $5), output lacks '$6':"; sed 's/^/  /' <<<"$out"; return 1
    fi
    [[ ! -e "$2/native" || -L "$2/native" ]] || { echo "$1: --check created $2/native"; return 1; }
    return 0
}

# 10d. I59: EDY_RDP_PULSE_SEAT_UID=auto (the default) resolves via loginctl to
#      whichever session is active on seat0 - the GDM greeter before a login,
#      a logged-in user's own session after, without needing to know which one
#      ahead of time - and falls back to uid 1000 when no such session exists
#      at all (e.g. a headless host). A lingering, non-seat session (matches
#      edt1's own lingering "eddie" --user manager: uid 1000, no Seat= at all)
#      is listed first and must be skipped rather than mistaken for the active
#      seat. An explicit --seat-uid still wins outright; auto-resolution must
#      not even run. Hermetic: a fake loginctl earlier in PATH.
pulse_bind_auto_resolves_seat_uid() {
    need_file pulse/edy-rdp-pulse-bind.sh 4.6 || return 1
    local bin="$TMP/fakebin-loginctl" bad=0 out
    install -d -- "$bin"
    cat > "$bin/loginctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "list-sessions --no-legend" ]]; then
    for s in $FAKE_SESSION_IDS; do printf '%s\n' "$s"; done
elif [[ "$1" == show-session ]]; then
    var="FAKE_PROPS_$2"; printf '%s\n' "${!var}"
fi
EOF
    chmod +x "$bin/loginctl"

    export FAKE_SESSION_IDS="3 c1"
    # session 3: an active but SEAT-LESS session (e.g. an SSH login, which some
    # systemd-logind versions also mark Active=yes) - must be skipped by the
    # seat0 check specifically, independent of the Active check (a session
    # that is merely inactive would be skipped either way and not exercise
    # this filter on its own).
    export FAKE_PROPS_3=$'Seat=\nActive=yes\nUser=1000'
    export FAKE_PROPS_c1=$'Seat=seat0\nActive=yes\nUser=60578'
    out="$(PATH="$bin:$PATH" EDY_RDP_PULSE_DIR="$TMP/pulse-auto1" "$SRC/pulse/edy-rdp-pulse-bind.sh" --check 2>&1)"
    grep -qF 'auto: resolved the active seat0 session to uid 60578' <<<"$out" \
        || { echo "greeter-active case: no resolution log:"; sed 's/^/  /' <<<"$out"; bad=1; }
    grep -qF '/run/user/60578/pulse/native' <<<"$out" \
        || { echo "greeter-active case: plan does not use the resolved uid:"; sed 's/^/  /' <<<"$out"; bad=1; }

    export FAKE_SESSION_IDS="3"
    out="$(PATH="$bin:$PATH" EDY_RDP_PULSE_DIR="$TMP/pulse-auto2" "$SRC/pulse/edy-rdp-pulse-bind.sh" --check 2>&1)"
    grep -qF 'auto: no session is both on seat0 and active' <<<"$out" \
        || { echo "no-active-session case: no fallback log:"; sed 's/^/  /' <<<"$out"; bad=1; }
    grep -qF '/run/user/1000/pulse/native' <<<"$out" \
        || { echo "no-active-session case: did not fall back to uid 1000:"; sed 's/^/  /' <<<"$out"; bad=1; }

    out="$(PATH="$bin:$PATH" EDY_RDP_PULSE_DIR="$TMP/pulse-auto3" "$SRC/pulse/edy-rdp-pulse-bind.sh" --seat-uid 4242 --check 2>&1)"
    grep -qF 'auto:' <<<"$out" \
        && { echo "explicit --seat-uid case: auto-resolution ran anyway:"; sed 's/^/  /' <<<"$out"; bad=1; }
    grep -qF '/run/user/4242/pulse/native' <<<"$out" \
        || { echo "explicit --seat-uid case: plan lost the pinned uid:"; sed 's/^/  /' <<<"$out"; bad=1; }

    unset FAKE_SESSION_IDS FAKE_PROPS_3 FAKE_PROPS_c1
    return $bad
}

# 10d2. I59 follow-up (adversarial review): EDY_RDP_PULSE_SEAT_SOCKET is
#      documented to WIN over the uid outright. With EDY_RDP_PULSE_SEAT_UID
#      left at its "auto" default, a mismatched active-seat0 uid (reported by
#      a fake loginctl) must NOT make the override start refusing a socket
#      that never changed -- the override's own real owner is what the
#      ownership check has to use, not an unrelated "who is active" answer.
#      Hermetic: fake loginctl reporting an active uid that does NOT own the
#      real (test-created) override socket.
pulse_bind_auto_uid_never_overrides_a_pinned_seat_socket() {
    need_file pulse/edy-rdp-pulse-bind.sh 4.6 || return 1
    local d="$TMP/pulse-override-vs-auto" bin="$TMP/fakebin-loginctl2" bad=0 out me
    me="$(id -u)"
    install -d -m 0755 -- "$d/seat"
    python3 - "$d/seat" <<'PY' || { echo "cannot create a test socket"; return 1; }
import os, socket, sys
os.chdir(sys.argv[1]); socket.socket(socket.AF_UNIX).bind("native")
PY
    install -d -- "$bin"
    cat > "$bin/loginctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "list-sessions --no-legend" ]]; then
    printf 'c1\n'
elif [[ "$1" == show-session ]]; then
    printf 'Seat=seat0\nActive=yes\nUser=%s\n' "$FAKE_ACTIVE_UID"
fi
EOF
    chmod +x "$bin/loginctl"
    export FAKE_ACTIVE_UID=424242   # deliberately NOT $me: someone else is "active" at seat0

    out="$(PATH="$bin:$PATH" EDY_RDP_PULSE_DIR="$d/dir" EDY_RDP_PULSE_SEAT_SOCKET="$d/seat/native" \
           "$SRC/pulse/edy-rdp-pulse-bind.sh" --check 2>&1)"
    grep -qF "seat=$d/seat/native (exists)" <<<"$out" \
        || { echo "override case: the pinned socket was not accepted despite a mismatched active seat0 uid:"; sed 's/^/  /' <<<"$out"; bad=1; }
    grep -qF "not a socket owned by uid $FAKE_ACTIVE_UID" <<<"$out" \
        && { echo "override case: auto-resolution's active-seat uid leaked into the ownership check:"; sed 's/^/  /' <<<"$out"; bad=1; }

    unset FAKE_ACTIVE_UID
    return $bad
}

# 10e. I59: PULSE_SOURCE=auto resolves the seat's current default sink (via
#      `pactl get-default-sink` over the bound socket) instead of a hand-typed
#      name that goes stale the moment the audio topology changes; a pin, or
#      "unset" (audio off, the default), is never previewed as if it were auto.
#      Hermetic: a fake pactl earlier in PATH, a real (never actually recorded
#      from) unix socket standing in for the seat's.
pulse_bind_auto_resolves_source_preview() {
    need_file pulse/edy-rdp-pulse-bind.sh 4.6 || return 1
    local d="$TMP/pulse-source-preview" bin="$TMP/fakebin-pactl" bad=0 out me
    me="$(id -u)"
    install -d -m 0755 -- "$d/seat"
    python3 - "$d/seat" <<'PY' || { echo "cannot create a test socket"; return 1; }
import os, socket, sys
os.chdir(sys.argv[1]); socket.socket(socket.AF_UNIX).bind("native")
PY
    install -d -- "$bin"
    cat > "$bin/pactl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == get-default-sink ]] && printf '%s\n' "${FAKE_DEFAULT_SINK:-}"
EOF
    chmod +x "$bin/pactl"

    export FAKE_DEFAULT_SINK="alsa_output.usb-Generic_USB_Audio-00.HiFi__Speaker__sink"
    out="$(PATH="$bin:$PATH" EDY_RDP_PULSE_DIR="$d/dir" EDY_RDP_PULSE_SEAT_SOCKET="$d/seat/native" \
           PULSE_SOURCE=auto "$SRC/pulse/edy-rdp-pulse-bind.sh" --seat-uid "$me" --check 2>&1)"
    grep -qF "plan: PULSE_SOURCE=auto -> would resolve to ${FAKE_DEFAULT_SINK}.monitor" <<<"$out" \
        || { echo "auto-source preview: wrong/missing plan line:"; sed 's/^/  /' <<<"$out"; bad=1; }

    out="$(PATH="$bin:$PATH" EDY_RDP_PULSE_DIR="$d/dir2" EDY_RDP_PULSE_SEAT_SOCKET="$d/seat/native" \
           PULSE_SOURCE=my-pinned-sink.monitor "$SRC/pulse/edy-rdp-pulse-bind.sh" --seat-uid "$me" --check 2>&1)"
    grep -qF 'PULSE_SOURCE=auto' <<<"$out" \
        && { echo "pinned-source case: previewed auto-resolution anyway:"; sed 's/^/  /' <<<"$out"; bad=1; }

    out="$(PATH="$bin:$PATH" EDY_RDP_PULSE_DIR="$d/dir3" EDY_RDP_PULSE_SEAT_SOCKET="$d/seat/native" \
           "$SRC/pulse/edy-rdp-pulse-bind.sh" --seat-uid "$me" --check 2>&1)"
    grep -qF 'PULSE_SOURCE=auto' <<<"$out" \
        && { echo "unset-source case: previewed auto-resolution anyway:"; sed 's/^/  /' <<<"$out"; bad=1; }

    unset FAKE_DEFAULT_SINK
    return $bad
}

# 10c. deploy.sh itself, STAGED, end to end: copy, alias swap, the installed
#      install.sh placing .env and linking, then --verify. Nothing had run this
#      path to completion anywhere but a host with a masking job wrapper (I41).
deploy_staged_completes_and_verifies() {
    local T="$TMP/deploy" out rc bad=0 last root
    fresh_tree "$T"; root="$T/root/opt/$PROJECT"
    out="$(DESTDIR="$T/root" "$T/src/deploy.sh" 2>&1)"; rc=$?
    last="$(sed -e '/^[[:space:]]*$/d' <<<"$out" | tail -n 1)"
    if (( rc != 0 )) || [[ "$last" != "DEPLOY OK $WANT_VERSION" ]]; then
        echo "deploy.sh exited $rc, last line '$last':"; grep -E '^(FATAL|  FAIL|DEPLOY)' <<<"$out" | head -n 8; return 1
    fi
    [[ "$(readlink -- "$root/payload")" == "payload-$WANT_VERSION" ]] \
        || { echo "payload alias is '$(readlink -- "$root/payload" 2>&1)', want payload-$WANT_VERSION"; bad=1; }
    [[ -f "$root/.env" ]] || { echo "the installed install.sh did not place $root/.env"; bad=1; }
    [[ -f "$root/payload/requires.txt" && -f "$root/payload/requirements.txt" ]] \
        || { echo "requires.txt / requirements.txt did not ship in the payload"; bad=1; }
    [[ -L "$T/root$LIBEXECDIR/edy-rdp-bootstrap" ]] || { echo "libexec was not linked out of the payload"; bad=1; }
    out="$(DESTDIR="$T/root" "$T/src/deploy.sh" --verify 2>&1)"; rc=$?
    last="$(sed -e '/^[[:space:]]*$/d' <<<"$out" | tail -n 1)"
    if (( rc != 0 )) || [[ "$last" != "DEPLOY VERIFY OK" ]]; then
        echo "deploy.sh --verify exited $rc, last line '$last':"; grep -E '^(FATAL|  FAIL|DEPLOY)' <<<"$out" | head -n 8; bad=1
    fi
    return $bad
}

# 10d. an operator .env that install.sh would refuse stops deploy.sh in ITS
#      pre-flight - before a payload is copied or the alias swapped. Otherwise the
#      refusal lands after the swap, from the installed install.sh, and the host is
#      the Sep-18 half-deployed state again (I43). The 1.3.x PULSE_SERVER is the
#      value edt1's live .env actually carries.
deploy_refuses_stale_env_before_swap() {
    local T="$TMP/deploy-stale" out rc bad=0 root
    fresh_tree "$T"; root="$T/root/opt/$PROJECT"
    install -d -m 0755 -- "$root"
    { cat "$T/src/.envdefault"; printf 'PULSE_SERVER=unix:/run/pulse.sock\n'; } > "$root/.env"
    out="$(DESTDIR="$T/root" "$T/src/deploy.sh" 2>&1)"; rc=$?
    (( rc != 0 )) || { echo "deploy.sh exited 0 with a stale PULSE_SERVER in the .env"; bad=1; }
    grep -qF 'DEPLOY FAILED (pre-flight)' <<<"$out" || { echo "no 'DEPLOY FAILED (pre-flight)' line"; bad=1; }
    grep -qF 'PULSE_SERVER' <<<"$out"               || { echo "the refusal does not name PULSE_SERVER"; bad=1; }
    grep -qF 'BEFORE anything is copied' <<<"$out"  || { echo "the refusal does not say it stopped before copying"; bad=1; }
    [[ -z "$(ls -d "$root"/payload* 2>/dev/null)" ]] \
        || { echo "a payload was copied or the alias swapped although the .env was refused: $(ls -d "$root"/payload*)"; bad=1; }
    [[ ! -e "$T/root/usr" ]] || { echo "something was linked under DESTDIR/usr"; bad=1; }
    (( bad )) && grep -E '^(FATAL|  FAIL|DEPLOY|    )' <<<"$out" | head -n 8
    return $bad
}

# 11. every shell script parses; shellcheck when the host has it (it is not on edt1).
shell_syntax() {
    local bad=0 f files=()
    shopt -s nullglob
    files=("$SRC"/install.sh "$SRC"/deploy.sh "$SRC"/lib/*.sh "$SRC"/bootstrap/*.sh "$SRC"/pulse/*.sh "$SRC"/tests/*.sh)
    shopt -u nullglob
    for f in lib/edy-rdp-env.sh lib/edy-rdp-requires.sh bootstrap/edy-rdp-bootstrap.sh pulse/edy-rdp-pulse-bind.sh; do
        [[ -f "$SRC/$f" ]] || { echo "missing $f (SPEC 1) - not landed yet?"; bad=1; }
    done
    for f in bootstrap/edy-rdp-bootstrap.sh pulse/edy-rdp-pulse-bind.sh tests/installer_tests.sh tests/make_wheel.py; do
        [[ ! -f "$SRC/$f" || -x "$SRC/$f" ]] || { echo "$f is not executable (units ExecStart these; git must record 100755)"; bad=1; }
    done
    for f in "${files[@]}"; do
        bash -n "$f" || { echo "bash -n: $f"; bad=1; }
    done
    python3 -m py_compile "$SRC/tests/make_wheel.py" || { echo "py_compile: tests/make_wheel.py"; bad=1; }
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -S warning "${files[@]}" || { echo "shellcheck -S warning found problems (above)"; bad=1; }
    fi
    return $bad
}

# 12/13 helper: migrate_shadow_group_rename() and ensure_shadow_group() call
# real groupadd/groupmod/getent against the actual system group table -
# exactly like migrate_group_rename()/create_users() do - and deploy.sh's own
# root-or-DESTDIR gate at the top of the file makes it impossible to reach
# their UNGUARDED (real, non-staged) code path through the script itself
# without being root. So these two tests extract just the one function's
# source (the same sed-range-then-eval technique load_manifest() above
# already uses for install.sh's BEGIN-MANIFEST/END-MANIFEST) and drive it
# directly against FAKE getent/groupmod/groupadd/say/die shell functions
# (a bare command name resolves to a same-named shell function before PATH,
# so these shadow the real tools with no PATH trick needed) - the host's
# actual /etc/group is never touched no matter who runs this suite.
load_deploy_fn() {   # $1 = function name; sources that one function into THIS shell
    eval "$(sed -n "/^$1() {/,/^}/p" "$SRC/deploy.sh")"
}

# 12. migrate_shadow_group_rename(): (a) a real "rdp-shadow" group is renamed
#     to "cockpit-guac-rdp-shadow", (b) an .env carrying the exact old default
#     is rewritten, (c) an .env with a clearly-customized value is untouched by
#     both the rename and the rewrite, (d) a second run of each case is a safe
#     no-op (idempotent).
deploy_migrate_shadow_group_rename() {
    load_deploy_fn migrate_shadow_group_rename
    local bad=0 env="$TMP/shadow-migrate.env"
    local -a SAY_LOG=() GROUPMOD_CALLS=()
    local FAKE_GROUPS DIED=0
    say()     { SAY_LOG+=("$1 $2"); }
    die()     { DIED=1; SAY_LOG+=("DIE: $*"); }
    getent()  { [[ "$1" == group ]] || return 1
                local g; for g in $FAKE_GROUPS; do [[ "$g" == "$2" ]] && return 0; done; return 2; }
    groupmod() { GROUPMOD_CALLS+=("$*")
                 [[ "$*" == "-n cockpit-guac-rdp-shadow rdp-shadow" ]] \
                     && FAKE_GROUPS="cockpit-guac-rdp-shadow"; }

    # (a) a real "rdp-shadow" group exists, "cockpit-guac-rdp-shadow" does not.
    D=""; FAKE_GROUPS="rdp-shadow"; ENVF="$TMP/no-such-env"
    migrate_shadow_group_rename
    (( ! DIED )) || { echo "(a) die() was called: ${SAY_LOG[*]}"; bad=1; }
    [[ "${GROUPMOD_CALLS[*]:-}" == "-n cockpit-guac-rdp-shadow rdp-shadow" ]] \
        || { echo "(a) groupmod calls: '${GROUPMOD_CALLS[*]:-}'"; bad=1; }
    [[ "${SAY_LOG[*]:-}" == *"renamed"*"rdp-shadow -> cockpit-guac-rdp-shadow"* ]] \
        || { echo "(a) no 'renamed ... rdp-shadow -> cockpit-guac-rdp-shadow' log: ${SAY_LOG[*]:-}"; bad=1; }
    # (d) run again: "cockpit-guac-rdp-shadow" now exists, so this must be a no-op.
    GROUPMOD_CALLS=(); SAY_LOG=()
    migrate_shadow_group_rename
    [[ -z "${GROUPMOD_CALLS[*]:-}" ]] || { echo "(a/d) second run called groupmod again: ${GROUPMOD_CALLS[*]}"; bad=1; }

    # cockpit-guac-rdp-shadow already exists (e.g. an operator made it by hand
    # under the new name already) -> do nothing, not an error, EVEN IF a real
    # "rdp-shadow" also still happens to exist alongside it.
    GROUPMOD_CALLS=(); SAY_LOG=(); FAKE_GROUPS="rdp-shadow cockpit-guac-rdp-shadow"
    migrate_shadow_group_rename
    [[ -z "${GROUPMOD_CALLS[*]:-}" ]] || { echo "(a) renamed although cockpit-guac-rdp-shadow already existed"; bad=1; }
    (( ! DIED )) || { echo "(a) die() was called when the new group already existed"; bad=1; }

    # (b) .env carries the exact old default -> rewritten in place.
    FAKE_GROUPS=""; ENVF="$env"
    printf 'EDY_RDP_GUACD=127.0.0.1:4822\nEDY_RDP_SHADOW_GROUP=rdp-shadow\n' > "$env"
    migrate_shadow_group_rename
    grep -qx 'EDY_RDP_SHADOW_GROUP=cockpit-guac-rdp-shadow' "$env" \
        || { echo "(b) .env was not rewritten: $(cat "$env")"; bad=1; }
    grep -qx 'EDY_RDP_SHADOW_GROUP=rdp-shadow' "$env" \
        && { echo "(b) old line is still present"; bad=1; }
    [[ "${SAY_LOG[*]:-}" == *"updated"*"EDY_RDP_SHADOW_GROUP rdp-shadow -> cockpit-guac-rdp-shadow"* ]] \
        || { echo "(b) no 'updated ...' log: ${SAY_LOG[*]:-}"; bad=1; }
    # (d) run again on the now-rewritten .env: a safe no-op.
    SAY_LOG=()
    migrate_shadow_group_rename
    [[ -z "${SAY_LOG[*]:-}" ]] || { echo "(b/d) second run touched an already-migrated .env: ${SAY_LOG[*]}"; bad=1; }
    grep -qx 'EDY_RDP_SHADOW_GROUP=cockpit-guac-rdp-shadow' "$env" \
        || { echo "(b/d) .env no longer carries the new value after a second run"; bad=1; }

    # (c) a deliberately-customized .env value: untouched by the rewrite, and a
    # real "rdp-shadow" group existing at the same time must not touch it either.
    FAKE_GROUPS="rdp-shadow"; GROUPMOD_CALLS=(); SAY_LOG=()
    printf 'EDY_RDP_SHADOW_GROUP=my-custom-shadow-group\n' > "$env"
    migrate_shadow_group_rename
    grep -qx 'EDY_RDP_SHADOW_GROUP=my-custom-shadow-group' "$env" \
        || { echo "(c) a customized .env value was changed: $(cat "$env")"; bad=1; }
    [[ "${SAY_LOG[*]:-}" != *updated* ]] || { echo "(c) .env-rewrite logic fired on a customized value"; bad=1; }
    # the group rename in (a) is independent of the .env content and DID fire
    # here too (a real "rdp-shadow" group existed) - that is correct: (a) and
    # (b)/(c) are separate, unrelated checks, not an accidental linkage.
    [[ "${GROUPMOD_CALLS[*]:-}" == "-n cockpit-guac-rdp-shadow rdp-shadow" ]] \
        || { echo "(c) unexpected groupmod calls: '${GROUPMOD_CALLS[*]:-}'"; bad=1; }
    return $bad
}

# 12b. migrate_pulse_auto_defaults() (I59): (a) an .env carrying the exact old
#      EDY_RDP_PULSE_SEAT_UID=1000 default is rewritten to "auto", (b) same for
#      the exact old PULSE_SOURCE example default, (c) a customized value of
#      either is left untouched, (d) a second run is a safe no-op.
deploy_migrate_pulse_auto_defaults() {
    load_deploy_fn migrate_pulse_auto_defaults
    local bad=0 env="$TMP/pulse-auto-migrate.env"
    local -a SAY_LOG=() SYSTEMCTL_CALLS=()
    say() { SAY_LOG+=("$1 $2"); }
    systemctl() { SYSTEMCTL_CALLS+=("$*"); return 0; }

    D=""; ENVF="$env"
    printf 'EDY_RDP_PULSE_SEAT_UID=1000\nPULSE_SOURCE=alsa_output.pci-0000_01_00.1.hdmi-stereo.monitor\n' > "$env"
    migrate_pulse_auto_defaults
    grep -qx 'EDY_RDP_PULSE_SEAT_UID=auto' "$env" \
        || { echo "(a) EDY_RDP_PULSE_SEAT_UID was not migrated: $(cat "$env")"; bad=1; }
    grep -qx 'PULSE_SOURCE=auto' "$env" \
        || { echo "(b) PULSE_SOURCE was not migrated: $(cat "$env")"; bad=1; }
    [[ "${SAY_LOG[*]:-}" == *"EDY_RDP_PULSE_SEAT_UID 1000 -> auto"* ]] \
        || { echo "(a) no 'updated ...' log: ${SAY_LOG[*]:-}"; bad=1; }
    [[ "${SAY_LOG[*]:-}" == *"PULSE_SOURCE <old default example> -> auto"* ]] \
        || { echo "(b) no 'updated ...' log: ${SAY_LOG[*]:-}"; bad=1; }
    # (e) the superseded per-uid pair (for exactly the uid just migrated away
    # from) is disabled/stopped, so it cannot keep re-binding uid 1000's own
    # socket/sink over the new -auto pair's resolution.
    [[ " ${SYSTEMCTL_CALLS[*]:-} " == *" disable --now edy-rdp-pulse-seat@1000.path "* ]] \
        || { echo "(e) old per-uid path unit was not disabled: ${SYSTEMCTL_CALLS[*]:-}"; bad=1; }
    [[ " ${SYSTEMCTL_CALLS[*]:-} " == *" stop edy-rdp-pulse-rebind@1000.service "* ]] \
        || { echo "(e) old per-uid rebind service was not stopped: ${SYSTEMCTL_CALLS[*]:-}"; bad=1; }
    [[ "${SAY_LOG[*]:-}" == *"disabled"*"edy-rdp-pulse-seat@1000.path"* ]] \
        || { echo "(e) no 'disabled ...' log: ${SAY_LOG[*]:-}"; bad=1; }

    # (d) a second run on the now-migrated .env is a safe no-op (no .env
    # rewrite, no further systemctl calls -- the uid line no longer matches
    # the old-default pattern this migration looks for).
    SAY_LOG=(); SYSTEMCTL_CALLS=()
    migrate_pulse_auto_defaults
    [[ -z "${SAY_LOG[*]:-}" ]] || { echo "(d) second run touched an already-migrated .env: ${SAY_LOG[*]}"; bad=1; }
    [[ -z "${SYSTEMCTL_CALLS[*]:-}" ]] || { echo "(d) second run made systemctl calls: ${SYSTEMCTL_CALLS[*]}"; bad=1; }

    # (c) deliberately-customized values of either key are left untouched, and
    # no systemctl call is made against a uid that was never the old default.
    SAY_LOG=(); SYSTEMCTL_CALLS=()
    printf 'EDY_RDP_PULSE_SEAT_UID=4242\nPULSE_SOURCE=my-custom-sink.monitor\n' > "$env"
    migrate_pulse_auto_defaults
    grep -qx 'EDY_RDP_PULSE_SEAT_UID=4242' "$env" \
        || { echo "(c) a customized EDY_RDP_PULSE_SEAT_UID was changed: $(cat "$env")"; bad=1; }
    grep -qx 'PULSE_SOURCE=my-custom-sink.monitor' "$env" \
        || { echo "(c) a customized PULSE_SOURCE was changed: $(cat "$env")"; bad=1; }
    [[ -z "${SAY_LOG[*]:-}" ]] || { echo "(c) migration fired on customized values: ${SAY_LOG[*]}"; bad=1; }
    [[ -z "${SYSTEMCTL_CALLS[*]:-}" ]] || { echo "(c) systemctl called for a customized (non-1000) uid: ${SYSTEMCTL_CALLS[*]}"; bad=1; }
    return $bad
}

# 13. ensure_shadow_group(): creates the resolved group when it is missing and
#     EDY_RDP_SHADOW_GROUP is non-empty; creates nothing when it is blank; and
#     (structurally) is only ever called under --with-users in do_deploy().
deploy_ensure_shadow_group() {
    load_deploy_fn ensure_shadow_group
    . "$SRC/lib/edy-rdp-env.sh" || { echo "cannot source lib/edy-rdp-env.sh"; return 1; }
    local bad=0 env="$TMP/ensure-shadow.env"
    local -a SAY_LOG=() GROUPADD_CALLS=()
    local FAKE_GROUPS
    say()      { SAY_LOG+=("$1 $2"); }
    getent()   { [[ "$1" == group ]] || return 1
                 local g; for g in $FAKE_GROUPS; do [[ "$g" == "$2" ]] && return 0; done; return 2; }
    groupadd() { GROUPADD_CALLS+=("$*"); }

    # non-empty EDY_RDP_SHADOW_GROUP, group missing -> created.
    ENVF="$env"; FAKE_GROUPS=""
    printf 'EDY_RDP_SHADOW_GROUP=cockpit-guac-rdp-shadow\n' > "$env"
    ensure_shadow_group
    [[ "${GROUPADD_CALLS[*]:-}" == "--system cockpit-guac-rdp-shadow" ]] \
        || { echo "missing-group case: groupadd calls '${GROUPADD_CALLS[*]:-}'"; bad=1; }
    [[ "${SAY_LOG[*]:-}" == *"created"*"cockpit-guac-rdp-shadow"* ]] \
        || { echo "missing-group case: no 'created ...' log: ${SAY_LOG[*]:-}"; bad=1; }

    # non-empty, group already exists -> no-op (idempotent).
    GROUPADD_CALLS=(); SAY_LOG=(); FAKE_GROUPS="cockpit-guac-rdp-shadow"
    ensure_shadow_group
    [[ -z "${GROUPADD_CALLS[*]:-}" ]] \
        || { echo "existing-group case: groupadd was still called: ${GROUPADD_CALLS[*]}"; bad=1; }

    # blanked EDY_RDP_SHADOW_GROUP (the gate turned off) -> nothing is created.
    GROUPADD_CALLS=(); SAY_LOG=(); FAKE_GROUPS=""
    printf 'EDY_RDP_SHADOW_GROUP=\n' > "$env"
    ensure_shadow_group
    [[ -z "${GROUPADD_CALLS[*]:-}" ]] \
        || { echo "blank-group case: groupadd was called although the gate is off: ${GROUPADD_CALLS[*]}"; bad=1; }

    # without --with-users at all, do_deploy() must never reach this function -
    # asserted structurally, the same way run_tests.sh's own DEPLOY-CONTRACT
    # section asserts other call-site properties by grep rather than by driving
    # a real unflagged deploy (which would need the group to pre-exist to tell
    # "not called" apart from "called and it was a no-op").
    grep -qE '\(\(WITH_USERS\)\) && \{ step "shadow group"; ensure_shadow_group; \}' "$SRC/deploy.sh" \
        || { echo "ensure_shadow_group is no longer gated behind ((WITH_USERS)) in do_deploy()"; bad=1; }
    return $bad
}

# ---------------------------------------------------------------------------
# Order matters: 2, 3, 8 and 9 read the tree test 1 installs.
for t in installer_staged_install_completes \
         installer_staged_verify_passes \
         env_place_missing_env \
         env_place_reconcile_keeps_values \
         env_validate_refuses_bad_values \
         requires_lib_parses_and_compares \
         requires_lib_reports_missing_tool \
         bootstrap_empty_requirements_uses_system_python \
         bootstrap_builds_venv_offline_and_is_idempotent \
         pulse_bind_check_mode \
         pulse_bind_refuses_unsafe_seat_socket \
         pulse_bind_auto_resolves_seat_uid \
         pulse_bind_auto_uid_never_overrides_a_pinned_seat_socket \
         pulse_bind_auto_resolves_source_preview \
         deploy_staged_completes_and_verifies \
         deploy_refuses_stale_env_before_swap \
         shell_syntax \
         deploy_migrate_shadow_group_rename \
         deploy_migrate_pulse_auto_defaults \
         deploy_ensure_shadow_group; do
    run_test "$t"
done

# Belt and braces: the checkout itself must be exactly as it was before the run.
for f in .env venv venv.env; do
    [[ -e "$SRC/$f" && "$PRE_EXISTING" != *" $f"* ]] \
        && { echo "  FAIL the suite left $f in the checkout"; FAILED=1; }
done

exit $FAILED
