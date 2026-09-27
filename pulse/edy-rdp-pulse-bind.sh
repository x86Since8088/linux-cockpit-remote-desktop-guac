#!/usr/bin/env bash
# edy-rdp-pulse-bind [--seat-uid N] [--check] — bind the seat's PulseAudio socket into
# the SHARED directory the guacd container mounts, so desktop audio reaches guacd.
#
# WHY A DIRECTORY, AND WHY SHARED (KNOWN_ISSUES I42)
#   The seat's pulse socket lives under the user's XDG_RUNTIME_DIR (0700), which the
#   container cannot traverse, so the socket has to be bind-mounted somewhere the
#   container can reach. 1.3.x bound the socket FILE onto /run/edy-rdp-pulse.sock
#   ONCE, at guacd start, behind 'ExecStartPre=-'. After a boot where guacd came up
#   before the seat logged in, the target stayed a 0-byte regular file, the '-'
#   swallowed the error, nothing ever retried, and the container's '-v' was rprivate:
#   a bind done on the host later could not reach the running container. Audio was
#   dead until someone restarted guacd.
#
#   Now the bind root is a DIRECTORY, /run/edy-rdp-pulse, made a bind mount of itself
#   and marked rshared. The seat socket is bound INTO it as 'native', and the guacd
#   unit mounts the directory ':ro,rslave'. A mount event under a shared source
#   propagates into every slave of that mount - including the one inside the running
#   container - so a bind done AFTER the container started (this script, fired by
#   edy-rdp-pulse-seat@<uid>.path when /run/user/<uid>/pulse changes at login) is
#   visible inside the container as /run/pulse/native with no restart. rslave, not
#   rshared, on the container side: the host's mounts must reach the container, the
#   container's must never reach the host. ro: connect() on a unix socket needs no
#   write permission on the MOUNT (the kernel's read-only check exempts sockets - the
#   same reason docker.sock:ro works), so guacd gets nothing it can write into the
#   host directory this script trusts. This is a design argument until the operator
#   re-tests it live; the outcome line this script logs is the diagnostic either way.
#
# WHAT IT REFUSES, AND WHY
#   This runs as root and bind-mounts what it finds under a directory the SEAT USER
#   owns into a rootful container. '-S', 'stat -L' and 'mount --bind' all follow
#   symlinks, so a seat user who replaced 'native' - or 'pulse', or the runtime dir
#   itself - with a link could have root mount ANY socket on the host (the podman
#   socket, the relay's control socket) into the container. So no component the
#   user owns may be a symlink, the source must be a SOCKET OWNED BY THE SEAT UID
#   (lstat, never followed), the target must be absent, a mountpoint, or the empty
#   root-owned file this script itself creates, and after the bind the target is
#   re-read and undone if it is not the socket that was vetted. The same rule
#   applies to an EDY_RDP_PULSE_SEAT_SOCKET override.
#
# WHO RUNS IT
#   - edy-rdp-guacd.service, ExecStartPre (NOT '-'-prefixed): prepares the shared root
#     and binds the socket if the seat is already logged in. An absent seat socket is
#     exit 0 - "no audio until login" is not a reason to keep guacd down.
#   - edy-rdp-pulse-rebind@<uid>.service, started by the path unit at each login (and
#     once by deploy.sh --with-units, for a seat that is logged in at deploy time:
#     PathChanged= only ever fires for the NEXT change).
#   - an operator, by hand: --check prints the plan without root and changes nothing.
#
# SEAT SOCKET PRECEDENCE
#   EDY_RDP_PULSE_SEAT_SOCKET (non-empty, from the .env) > --seat-uid N
#   > EDY_RDP_PULSE_SEAT_UID (from the .env) > 1000, each meaning /run/user/N/pulse/native.
#
# EXIT CODES
#   0  bound, already bound, or seat socket absent (logged; no audio until login)
#   1  a refused source or target (symlink, wrong owner, not a socket), or a real
#      mount/umount/mkdir failure (this is what stops guacd). --check exits 1 for a
#      refusal too: the plan IS "refuse".
#   2  not root and not --check (mount needs CAP_SYS_ADMIN)
set -uo pipefail

DIR="${EDY_RDP_PULSE_DIR:-/run/edy-rdp-pulse}"   # tests point this at a temp dir
CHECK=0
SEAT_UID_ARG=""
while (( $# )); do
    case "$1" in
        --seat-uid) SEAT_UID_ARG="${2:?--seat-uid needs a numeric uid}"; shift 2 ;;
        --seat-uid=*) SEAT_UID_ARG="${1#*=}"; shift ;;
        --check) CHECK=1; shift ;;
        -h|--help) printf 'usage: edy-rdp-pulse-bind [--seat-uid N] [--check]\n'; exit 0 ;;
        *) printf '[pulse-bind] unknown argument: %s (usage: edy-rdp-pulse-bind [--seat-uid N] [--check])\n' "$1" >&2; exit 2 ;;
    esac
done

# One line per outcome, on stdout for the journal when a unit runs us, and via
# logger when a human does (JOURNAL_STREAM is set only under systemd).
log() {
    printf '[pulse-bind] %s\n' "$*"
    if [[ -z "${JOURNAL_STREAM:-}" ]] && command -v logger >/dev/null 2>&1; then
        logger -t edy-rdp-pulse-bind -- "$*"
    fi
}
fail() { local rc="${2:-1}"; log "FAIL $1"; exit "$rc"; }

# --- resolve the seat socket -------------------------------------------------
UID_="${SEAT_UID_ARG:-${EDY_RDP_PULSE_SEAT_UID:-1000}}"
case "$UID_" in
    ''|*[!0-9]*) fail "seat uid must be numeric, got '$UID_'" 2 ;;
esac
OVERRIDE=0
if [[ -n "${EDY_RDP_PULSE_SEAT_SOCKET:-}" ]]; then
    SOCKET="$EDY_RDP_PULSE_SEAT_SOCKET"; OVERRIDE=1
else
    SOCKET="/run/user/$UID_/pulse/native"
fi
T="$DIR/native"

# --- the two vettings (lstat only; nothing followed) ---------------------------
# seat_check: SEAT_STATE=absent|exists on rc 0; on rc 1 SEAT_STATE is the refusal.
# The user-owned components are checked one by one, deepest last, because a
# symlink anywhere on the way is enough for 'mount --bind' to land elsewhere.
seat_check() {
    local p
    SEAT_STATE=""
    if (( ! OVERRIDE )); then
        for p in "/run/user/$UID_" "/run/user/$UID_/pulse"; do
            [[ -L "$p" ]] && { SEAT_STATE="$p is a symlink - refusing"; return 1; }
        done
    fi
    [[ -L "$SOCKET" ]] && { SEAT_STATE="$SOCKET is a symlink - refusing"; return 1; }
    [[ -e "$SOCKET" ]] || { SEAT_STATE=absent; return 0; }
    local fu
    fu="$(stat -c '%F %u' -- "$SOCKET" 2>/dev/null || true)"
    [[ "$fu" == "socket $UID_" ]] \
        || { SEAT_STATE="$SOCKET is not a socket owned by uid $UID_ (it is: ${fu:-unreadable}) - refusing"; return 1; }
    SEAT_STATE=exists
    return 0
}
# target_check: TGT_STATE=absent|mounted|"not mounted" on rc 0; the refusal on
# rc 1. Anything at the target other than what this script itself puts there
# means something else wrote into the bind root - and the next ': >' or 'mount'
# through a planted symlink would create or cover an attacker-chosen host path.
target_check() {
    local fu
    TGT_STATE=""
    [[ -L "$DIR" ]] && { TGT_STATE="$DIR is a symlink - refusing"; return 1; }
    [[ -L "$T" ]] && { TGT_STATE="$T is a symlink - refusing (something wrote into $DIR)"; return 1; }
    [[ -e "$T" ]] || { TGT_STATE=absent; return 0; }
    mountpoint -q -- "$T" 2>/dev/null && { TGT_STATE=mounted; return 0; }
    fu="$(stat -c '%F %u' -- "$T" 2>/dev/null || true)"
    [[ "$fu" == "regular empty file 0" ]] \
        || { TGT_STATE="$T is not the empty root-owned file expected (it is: ${fu:-unreadable}) - refusing"; return 1; }
    TGT_STATE="not mounted"
    return 0
}

# --- --check: the plan, no root, no writes -----------------------------------
if (( CHECK )); then
    seat_check   || fail "$SEAT_STATE"
    target_check || fail "$TGT_STATE"
    log "plan: dir=$DIR seat=$SOCKET ($SEAT_STATE) target=$T ($TGT_STATE)"
    log "check: no changes made"
    exit 0
fi

(( EUID == 0 )) || fail "mount needs root (CAP_SYS_ADMIN); use --check to see the plan" 2

# --- 1. the shared bind root --------------------------------------------------
# Idempotent: a directory that is already a shared mountpoint is left alone. Each
# step's stderr goes into the FAIL line so the journal says which mount refused.
did=0
[[ -L "$DIR" ]] && fail "$DIR is a symlink - refusing"
err="$(mkdir -p -- "$DIR" 2>&1)" || fail "mkdir -p $DIR: $err"
if ! mountpoint -q -- "$DIR"; then
    err="$(mount --bind -- "$DIR" "$DIR" 2>&1)" || fail "mount --bind $DIR $DIR: $err"
    did=1
fi
if ! findmnt -no PROPAGATION -- "$DIR" 2>/dev/null | grep -q shared; then
    err="$(mount --make-rshared -- "$DIR" 2>&1)" || fail "mount --make-rshared $DIR: $err"
    did=1
fi
(( did )) && log "shared bind root ready ($DIR)"

# --- 2. the seat socket --------------------------------------------------------
seat_check || fail "$SEAT_STATE"
if [[ "$SEAT_STATE" == absent ]]; then
    log "seat socket absent ($SOCKET) - no audio until a seat login; edy-rdp-pulse-seat@${UID_}.path binds it then"
    exit 0
fi

# --- 3. bind it in as 'native' ------------------------------------------------
# Identity is device:inode of the SOCKET (lstat; a symlink was refused above).
# A previous login's socket may still be bound (same path, new inode after
# pipewire-pulse restarted): re-bind only when they differ.
target_check || fail "$TGT_STATE"
want="$(stat -c '%d:%i' -- "$SOCKET" 2>/dev/null || true)"
[[ -n "$want" ]] || fail "cannot stat $SOCKET"
if [[ "$TGT_STATE" == mounted ]]; then
    if [[ "$(stat -c '%d:%i' -- "$T" 2>/dev/null)" == "$want" ]]; then
        log "already bound (unchanged)"
        exit 0
    fi
    err="$(umount -- "$T" 2>&1)" || fail "umount $T: $err"
    log "stale bind released (seat socket changed - new login)"
fi
# A bind mount needs an existing target of the same kind; an empty regular file
# is what a socket binds onto. Not '-L', not foreign: target_check just said so.
[[ -e "$T" ]] || : > "$T"
err="$(mount --bind -- "$SOCKET" "$T" 2>&1)" || fail "mount --bind $SOCKET $T: $err"
# The window between the lstat above and the mount is the seat user's to race.
# Look at what is NOW on the target; if it is not the vetted socket, undo it.
got="$(stat -c '%F %u %d:%i' -- "$T" 2>/dev/null || true)"
if [[ "$got" != "socket $UID_ $want" ]]; then
    umount -- "$T" 2>/dev/null || true
    fail "$T after the bind is '${got:-unreadable}', not the vetted seat socket (socket $UID_ $want) - undone"
fi
log "bound $SOCKET -> $T"
exit 0
