#!/usr/bin/env bash
#
# edy-rdp-bootstrap - what runs, as root, right before the relay starts.
#
#   ExecStartPre=+@LIBEXEC@/edy-rdp-bootstrap        (edy-rdp-relay.service)
#   edy-rdp-bootstrap --check                          dry run: plan, no writes
#
# WHY IT EXISTS
#   Service start is the one moment a wrong .env would otherwise put a relay on
#   the built-in defaults it was never configured with, and the one moment an
#   OS prerequisite that went missing since deploy would otherwise fail at the
#   first click instead of in the journal. So this runs FIRST, as root ('+' in
#   the unit: exempt from User=, NoNewPrivileges= and ProtectSystem=), and it
#   fails CLOSED:
#     1. the .env is validated with the same lib install.sh used to place it
#        (grammar, required keys, secret shapes, per-key rules) - a problem
#        names the key and the reason, and the relay does not start;
#     2. the OS prerequisites are verified against requires.txt (presence AND
#        minimum version) - a miss prints the exact fix command. It NEVER runs
#        apt/dnf here: installing packages changes host state, and this
#        project reserves that for deploy.sh --with-deps, on a host being
#        deployed to, by an operator who asked for it;
#     3. the interpreter: only when requirements.txt names a dependency does
#        the relay need a venv, and then it is built OFFLINE from the wheels
#        deploy.sh vendored into the payload (a service start must not reach
#        the internet), rebuilt when requirements.txt's sha256 changes, and
#        named in [install path]/venv.env for the units to read. An empty
#        requirements.txt - the relay is stdlib-only today - means
#        /usr/bin/python3 and no venv at all.
#   Idempotent and fast on the happy path: three reads, one sha256 and, when
#   nothing changed, not a single write.
#
# Exit codes: 0 ok | 1 .env invalid | 2 prerequisites | 3 venv | 4 no install.conf
# Every outcome is one journal line prefixed [bootstrap].
set -Eeuo pipefail
# root-owned, WORLD-READABLE: the venv and venv.env this writes are read and
# executed by the edy-relay uid the unit then drops to.
umask 022

# Libs: beside this script's REAL path (the libexec link resolves into the payload),
# overridable for tests. Do not hardcode /usr/libexec here: a checkout runs this too.
LIBDIR="${EDY_RDP_LIBDIR:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../lib" && pwd)}"
. "$LIBDIR/edy-rdp-env.sh"; . "$LIBDIR/edy-rdp-requires.sh"

log() {
    printf '[bootstrap] %s\n' "$*"
    # Under systemd stdout IS the journal; by hand, also leave a trace there.
    [[ -z "${JOURNAL_STREAM:-}" ]] && logger -t edy-rdp-bootstrap -- "$*" 2>/dev/null
    return 0
}
fail() { local rc=$1; shift; log "FAIL $*"; exit "$rc"; }

usage() { sed -n '2,7p' "$0" | sed 's/^# \?//'; }

# --- CLI > install.conf > derived from PAYLOAD ------------------------------
CONF="${EDY_RDP_INSTALL_CONF:-/etc/cockpit-guac-rdp/install.conf}"
o_env=""; o_envdefault=""; o_install_path=""; o_payload=""; o_requires=""
o_requirements=""; o_wheels=""; o_required_env=""
PYTHON=/usr/bin/python3
SKIP_PREREQS=0; CHECK=0
while (($#)); do
  case "$1" in
    --install-conf) CONF="${2:?}"; shift 2 ;;
    --env)          o_env="${2:?}"; shift 2 ;;
    --envdefault)   o_envdefault="${2:?}"; shift 2 ;;
    --install-path) o_install_path="${2:?}"; shift 2 ;;
    --payload)      o_payload="${2:?}"; shift 2 ;;
    --requires)     o_requires="${2:?}"; shift 2 ;;
    --requirements) o_requirements="${2:?}"; shift 2 ;;
    --wheels)       o_wheels="${2:?}"; shift 2 ;;
    --python)       PYTHON="${2:?}"; shift 2 ;;
    --required-env) o_required_env="${2:?}"; shift 2 ;;
    --skip-prereqs) SKIP_PREREQS=1; shift ;;   # tests only: a build box need not be a deploy host
    --check)        CHECK=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) fail 4 "unknown option: $1" ;;
  esac
done

# install.conf is what install.sh wrote; a key it lacks (an older install.conf,
# or a test that passes everything on the command line) is simply absent.
cget() { [[ -r "$CONF" ]] && env_get "$CONF" "$1" 2>/dev/null || true; }
ENV="${o_env:-$(cget ENV_FILE)}"
INSTALL_PATH="${o_install_path:-$(cget INSTALL_PATH)}"
PAYLOAD="${o_payload:-$(cget PAYLOAD)}"
ENVDEFAULT="${o_envdefault:-$(cget ENVDEFAULT)}";     ENVDEFAULT="${ENVDEFAULT:-${PAYLOAD:+$PAYLOAD/.envdefault}}"
REQUIRES="${o_requires:-$(cget REQUIRES)}";           REQUIRES="${REQUIRES:-${PAYLOAD:+$PAYLOAD/requires.txt}}"
REQUIREMENTS="${o_requirements:-$(cget REQUIREMENTS)}"; REQUIREMENTS="${REQUIREMENTS:-${PAYLOAD:+$PAYLOAD/requirements.txt}}"
WHEELS="${o_wheels:-$(cget WHEELS)}";                 WHEELS="${WHEELS:-${PAYLOAD:+$PAYLOAD/wheels}}"
REQUIRED_ENV="${o_required_env:-$(cget REQUIRED_ENV)}"
if [[ -z "$ENV" || -z "$INSTALL_PATH" || -z "$ENVDEFAULT" || -z "$REQUIRES" || -z "$REQUIREMENTS" || -z "$WHEELS" ]]; then
    fail 4 "no install.conf at $CONF (run install.sh)"
fi

# --- 1. the .env, fail closed -----------------------------------------------
# shellcheck disable=SC2086
if problems="$(env_validate "$ENV" "$ENVDEFAULT" $REQUIRED_ENV)"; then
    log "env OK ($(env_keys "$ENV" | wc -l) keys, $ENV)"
else
    while IFS= read -r p; do [[ -n "$p" ]] && log "FAIL env: $p"; done <<<"$problems"
    exit 1
fi
[[ -n "$REQUIRED_ENV" ]] || log "env: install.conf carries no REQUIRED_ENV (pre-1.4 install?) - required keys not checked"

# --- 2. prerequisites: verified, never installed ----------------------------
if (( SKIP_PREREQS )); then
    log "prereqs: skipped (--skip-prereqs)"
else
    req_load "$REQUIRES" >/dev/null || fail 2 "prereqs: cannot parse $REQUIRES"
    if req_check --quiet >/dev/null; then
        log "prereqs OK (${#REQ_NAMES[@]} present, >= minimum)"
    else
        for n in "${REQ_MISSING[@]}";  do log "FAIL prereq $n missing"; done
        for n in "${REQ_OUTDATED[@]}"; do log "FAIL prereq $n have ${REQ_HAVE[$n]} < ${REQ_MIN[$n]}"; done
        log "fix: $(req_fix_command "${REQ_MISSING[@]}" "${REQ_OUTDATED[@]}")"
        log "(deploy.sh --with-deps runs that for you; the bootstrap never installs packages at service start)"
        exit 2
    fi
fi

# --- 3. the interpreter -----------------------------------------------------
VENV="$INSTALL_PATH/venv"
MARK="$VENV/.edy-rdp-bootstrap"      # "this bootstrap made it" - the ONLY thing rm -rf is ever aimed at
SHAF="$VENV/.requirements.sha"
OUT="$INSTALL_PATH/venv.env"
n="$(req_pip_count "$REQUIREMENTS")"
want_sha="$(req_sha256 "$REQUIREMENTS")"
would=0   # --check: would we write anything?
# The install path exists on any deployed or dev host (it holds the payload);
# a test pointing --install-path at a fresh directory gets it made.
(( CHECK )) || install -d -m 0755 -- "$INSTALL_PATH"

venv_current() { [[ -x "$VENV/bin/python3" && -f "$SHAF" && "$(cat "$SHAF")" == "$want_sha" ]]; }

if (( n == 0 )); then
    PY="$PYTHON"
    if [[ -d "$VENV" && ! -L "$VENV" ]]; then
        if [[ -e "$MARK" ]]; then
            if (( CHECK )); then log "would remove stale $VENV (requirements.txt is now empty)"; would=1
            else rm -rf -- "$VENV"; log "venv: removed stale $VENV (this bootstrap created it; requirements.txt is now empty)"; fi
        else
            log "venv: $VENV exists but was not created by this bootstrap - left alone"
        fi
    fi
    log "venv: requirements.txt is empty - EDY_RDP_PYTHON=$PY"
else
    PY="$VENV/bin/python3"
    if venv_current; then
        log "venv: current (sha ${want_sha:0:8})"
    elif (( CHECK )); then
        if [[ -e "$VENV" && ! -e "$MARK" ]]; then
            fail 3 "venv: $VENV exists and was not created by this bootstrap; move it aside"
        fi
        log "would $( [[ -e "$VENV" ]] && echo rebuild || echo build ) $VENV from $WHEELS (requirements sha ${want_sha:0:8})"; would=1
    else
        verb=built
        if [[ -e "$VENV" ]]; then
            [[ -d "$VENV" && ! -L "$VENV" && -e "$MARK" ]] \
                || fail 3 "venv: $VENV exists and was not created by this bootstrap; move it aside"
            rm -rf -- "$VENV"; verb=rebuilt
        fi
        "$PYTHON" -m venv "$VENV" \
            || fail 3 "venv: python3 -m venv failed - is python3-venv installed? fix: $(req_detect_pm || true) install python3-venv"
        printf 'created by edy-rdp-bootstrap %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARK"
        # OFFLINE on purpose: a service start never reaches an index. The wheels
        # are what deploy.sh vendored (pip download) into the payload.
        "$VENV/bin/python3" -m pip install --quiet --no-index --find-links "$WHEELS" -r "$REQUIREMENTS" \
            || fail 3 "venv: offline pip install failed; wheels for every requirement must be in $WHEELS (deploy.sh vendors them with pip download)"
        printf '%s\n' "$want_sha" > "$SHAF"
        log "venv: $verb $VENV (requirements sha ${want_sha:0:8})"
    fi
fi

# --- venv.env: the one line the units read -----------------------------------
content="$(printf '# Written by edy-rdp-bootstrap at relay start; do not edit (it is rewritten).\n# requirements.txt sha256: %s\nEDY_RDP_PYTHON=%s\n' "$want_sha" "$PY")"
if [[ -f "$OUT" && "$(cat "$OUT")" == "$content" ]]; then
    log "venv.env: unchanged"
elif (( CHECK )); then
    log "would write $OUT with EDY_RDP_PYTHON=$PY"; would=1
else
    printf '%s\n' "$content" > "$OUT.new" && chmod 0644 "$OUT.new" && mv -f -- "$OUT.new" "$OUT" \
        || { rm -f -- "$OUT.new"; fail 3 "venv.env: cannot write $OUT"; }
    log "venv.env: wrote EDY_RDP_PYTHON=$PY"
fi

if (( CHECK )); then
    (( would )) && { log "check: changes pending (nothing written)"; exit 3; }
    log "check: nothing to do"
fi
exit 0
