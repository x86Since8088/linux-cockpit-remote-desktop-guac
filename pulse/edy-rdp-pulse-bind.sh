#!/usr/bin/env bash
# edy-rdp-pulse-bind [--seat-uid N] [--auto-restart-guacd] [--check] — bind the seat's
# PulseAudio socket into the SHARED directory the guacd container mounts, so desktop
# audio reaches guacd, and (I59) resolve WHICH sink to record.
#
# I59: WHY "AUTO" AND NOT A FIXED HOSTNAME/SINK
#   Both "which uid is the seat" and "which sink that uid plays to" used to be a
#   one-time, hand-typed operator step (docs/AUDIO.md's old "seat setup"): find the
#   sink with `pactl get-default-sink`, paste "<name>.monitor" into PULSE_SOURCE,
#   restart guacd. That silently goes stale the moment the audio topology changes
#   (a monitor disconnects, a different sink becomes default, or - the case that
#   found this - the sink named in .env simply is not the one actually live), and it
#   only ever named ONE fixed uid, so it could reflect a mirrored desktop login OR
#   the GDM greeter but never both as the operator actually switches between them.
#   EDY_RDP_PULSE_SEAT_UID=auto (the new default) instead re-resolves, every time
#   this script runs, WHICHEVER session is actually active on seat0 right now via
#   `loginctl` (the greeter before login, whoever's logged in after) - see
#   resolve_active_seat_uid() below. PULSE_SOURCE=auto (opt-in; unset still means
#   "no audio channel", unchanged) similarly re-resolves that seat's OWN current
#   default sink via `pactl get-default-sink` over the just-bound socket - see
#   resolve_default_sink_monitor(). Either can still be pinned to a literal value,
#   which is left completely alone (this script never overwrites an explicit pin).
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
#     exit 0 - "no audio until login" is not a reason to keep guacd down. Never passes
#     --auto-restart-guacd (it would be restarting the unit it is a prerequisite of).
#   - edy-rdp-pulse-rebind@<uid>.service (EDY_RDP_PULSE_SEAT_UID pinned to a number):
#     started by edy-rdp-pulse-seat@<uid>.path at each login, and once by deploy.sh
#     --with-units for a seat logged in at deploy time.
#   - edy-rdp-pulse-rebind-auto.service (EDY_RDP_PULSE_SEAT_UID=auto, the default):
#     started by edy-rdp-pulse-seat-auto.path on ANY change under /run/user (a login
#     or logout by anyone, on any seat - the least specific watch that still catches
#     "the active seat0 session changed"; this script re-derives who that actually is
#     rather than trusting which uid's directory changed), and once by deploy.sh
#     --with-units. Passes --auto-restart-guacd: PULSE_SOURCE is a container start-time
#     env var, so a resolved value that changed cannot reach an already-running guacd
#     any other way (unlike the socket bind itself, which reaches it via mount
#     propagation with no restart - see WHY A DIRECTORY above).
#   - an operator, by hand: --check prints the plan, including what PULSE_SOURCE=auto
#     would currently resolve to, without root and without changing anything.
#
# SEAT SOCKET PRECEDENCE
#   EDY_RDP_PULSE_SEAT_SOCKET (non-empty, from the .env) > --seat-uid N
#   > EDY_RDP_PULSE_SEAT_UID (from the .env) > auto, each meaning /run/user/N/pulse/native.
#   "auto" (the default) resolves via resolve_active_seat_uid() below; a numeric value
#   pins a specific seat exactly as before I59.
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
AUTO_RESTART=0
SEAT_UID_ARG=""
while (( $# )); do
    case "$1" in
        --seat-uid) SEAT_UID_ARG="${2:?--seat-uid needs a numeric uid or 'auto'}"; shift 2 ;;
        --seat-uid=*) SEAT_UID_ARG="${1#*=}"; shift ;;
        --check) CHECK=1; shift ;;
        --auto-restart-guacd) AUTO_RESTART=1; shift ;;
        -h|--help) printf 'usage: edy-rdp-pulse-bind [--seat-uid N|auto] [--auto-restart-guacd] [--check]\n'; exit 0 ;;
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

# Every external IPC call in this file (loginctl/pactl, both a round trip to a
# separate daemon) is timeout-wrapped: a wedged logind or a pipewire-pulse that
# accepts a connection but never completes protocol negotiation must not hang
# this script indefinitely, since it runs as edy-rdp-guacd.service's own
# ExecStartPre (unconditionally, on every start) -- the same class of risk
# bridge/edy-rdp-krb-preflight.sh already guards against for a different IPC
# call (`timeout 1 getent ...`), and KNOWN_ISSUES I40 is a prior incident of
# exactly this shape (FreeRDP3's Kerberos-first NLA hanging ~2 minutes against
# a dead KDC). A timeout here degrades to the same "nothing resolved" path as
# a clean negative answer -- the caller's existing fallback handles both alike.
IPC_TIMEOUT=3

# I59: the uid of whichever session is CURRENTLY active on seat0 - the GDM
# greeter before anyone logs in, the logged-in user's own session after (which
# is exactly "GDM and mirroring scenarios" without needing to know which one it
# is ahead of time). Read-only (loginctl queries, no writes), so it is safe to
# call under --check too. Prints nothing and returns 1 if loginctl is missing,
# errors, times out, or no session is both on seat0 and Active=yes (e.g. a
# headless host with no display manager at all) - the caller falls back to a
# fixed uid.
resolve_active_seat_uid() {
    command -v loginctl >/dev/null 2>&1 || return 1
    local sid seat active uid k v
    while read -r sid _; do
        [[ -n "$sid" ]] || continue
        seat=""; active=""; uid=""
        while IFS='=' read -r k v; do
            case "$k" in Seat) seat="$v" ;; Active) active="$v" ;; User) uid="$v" ;; esac
        done < <(timeout "$IPC_TIMEOUT" loginctl show-session "$sid" -p Seat -p Active -p User 2>/dev/null)
        [[ "$seat" == seat0 && "$active" == yes && "$uid" =~ ^[0-9]+$ ]] || continue
        printf '%s\n' "$uid"
        return 0
    done < <(timeout "$IPC_TIMEOUT" loginctl list-sessions --no-legend 2>/dev/null)
    return 1
}
# I59: the seat's OWN current default sink, over the (already vetted/bound)
# socket path given in $1 - never a microphone, same "playing on the desktop"
# meaning as the manual `pactl get-default-sink` step in docs/AUDIO.md. Prints
# nothing and returns 1 if pactl is missing, the socket refuses the connection
# or times out (nobody there yet, or it is not actually a pulse socket), or no
# sink is set.
resolve_default_sink_monitor() {
    command -v pactl >/dev/null 2>&1 || return 1
    local sink
    sink="$(PULSE_SERVER="unix:$1" timeout "$IPC_TIMEOUT" pactl get-default-sink 2>/dev/null)" || return 1
    [[ -n "$sink" ]] || return 1
    printf '%s.monitor\n' "$sink"
}

# --- resolve the seat socket -------------------------------------------------
# EDY_RDP_PULSE_SEAT_SOCKET is documented (SEAT SOCKET PRECEDENCE, above) to
# WIN over the uid outright, so OVERRIDE has to be known BEFORE "auto" ever
# runs: auto-resolving "whoever is active on seat0 right now" for a pinned
# override path would make an operator's explicit override start silently
# refusing (or, worse, succeeding for the wrong reason) purely depending on who
# ELSE happens to be logged in -- found by adversarial review, reproduced
# against a fake loginctl reporting a mismatched active uid.
OVERRIDE=0
if [[ -n "${EDY_RDP_PULSE_SEAT_SOCKET:-}" ]]; then
    SOCKET="$EDY_RDP_PULSE_SEAT_SOCKET"; OVERRIDE=1
fi
UID_="${SEAT_UID_ARG:-${EDY_RDP_PULSE_SEAT_UID:-auto}}"
if [[ "$UID_" == auto ]]; then
    if (( OVERRIDE )); then
        # Trust the override's OWN current owner for the ownership check
        # below, rather than an unrelated "who is active" answer: the operator
        # chose this exact path, so ITS real owner is what "wins over the uid"
        # has to mean. A symlinked $SOCKET is still caught (and this bind
        # refused) by seat_check()'s own -L check further down regardless of
        # what stat reports here -- this is not a security-relevant lookup,
        # only which numeric uid gets compared against.
        resolved="$(stat -c '%u' -- "$SOCKET" 2>/dev/null || true)"
        if [[ "$resolved" =~ ^[0-9]+$ ]]; then
            UID_="$resolved"
        else
            UID_=1000
            log "auto: EDY_RDP_PULSE_SEAT_SOCKET is set but $SOCKET does not exist yet - using uid $UID_ for the ownership check until it appears"
        fi
    else
        resolved="$(resolve_active_seat_uid || true)"
        if [[ -n "$resolved" ]]; then
            log "auto: resolved the active seat0 session to uid $resolved"
            UID_="$resolved"
        else
            UID_=1000
            log "auto: no session is both on seat0 and active (loginctl) - falling back to uid $UID_"
        fi
    fi
fi
case "$UID_" in
    ''|*[!0-9]*) fail "seat uid must be numeric or 'auto', got '$UID_'" 2 ;;
esac
(( OVERRIDE )) || SOCKET="/run/user/$UID_/pulse/native"
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

# Guacd restarts are a shared resource -- EVERY current viewer's session drops
# when it restarts, not just the one that changed. Left unthrottled, a resolved
# value that keeps flapping (found by adversarial review: this project's own
# edt1-gui-crash-shutdown-rca.md documents the GDM greeter crash-looping on
# every RDP disconnect, each crash landing in a fresh session -- exactly the
# kind of churn edy-rdp-pulse-seat-auto.path reacts to) could otherwise fire
# `systemctl try-restart` fast enough to trip systemd's OWN default
# StartLimitBurst (5 restarts / 10s) and leave edy-rdp-guacd.service FAILED,
# not just noisy, for every viewer until an operator runs `systemctl
# reset-failed`. This cooldown keeps this script's OWN restarts well under that
# limit; the next trigger after it expires (or guacd's own next restart for any
# other reason, e.g. a deploy) still picks up whatever is current by then, so a
# skipped restart here is a delay, never a permanently lost update.
RESTART_COOLDOWN_SECS=30

# I59: resolves and, unless $2=preview, PERSISTS PULSE_SOURCE for this seat when
# .env opted in (PULSE_SOURCE=auto); leaves a pin or "audio off" (unset) alone,
# and cleans up a stale generated file left by an EARLIER auto run so "audio off"
# always really means off regardless of history. $1 = the socket path to query
# (the bound $T once live, or $SOCKET itself for a --check preview before
# anything is bound). Restarts guacd (--auto-restart-guacd only) so an
# already-running container picks up a value that changed - PULSE_SOURCE is a
# container start-time env var, so mount propagation (which is what lets the
# SOCKET bind reach a running container with no restart) cannot carry this.
resolve_and_persist_source() {
    local sock="$1" preview="${2:-}" src_file="$DIR/pulse-source.env" new_source old_source
    if [[ "${PULSE_SOURCE:-}" == auto ]]; then
        new_source="$(resolve_default_sink_monitor "$sock" || true)"
        if [[ -z "$new_source" ]]; then
            log "PULSE_SOURCE=auto: could not resolve a default sink over $sock yet (pactl failed, or nothing bound) - unchanged"
            return 0
        fi
        if [[ -n "$preview" ]]; then
            log "plan: PULSE_SOURCE=auto -> would resolve to $new_source"
            return 0
        fi
        old_source=""
        [[ -f "$src_file" ]] && old_source="$(sed -n 's/^PULSE_SOURCE=//p' "$src_file")"
        [[ "$new_source" == "$old_source" ]] && return 0
        # A unique per-invocation temp name (this project's own established
        # idiom for atomic-write-then-rename -- see bridge/edy-rdp-bridge-
        # start.sh's mktemp use), not a fixed one: two invocations CAN overlap
        # in practice (edy-rdp-guacd.service's own ExecStartPre and a
        # login/logout-triggered rebind both call this script, with no
        # ordering between them), and a fixed name let one invocation's mv
        # silently fail (ENOENT, the other invocation having already renamed
        # it away) while this function kept logging success regardless. The
        # mv's exit status now gates the log line and the restart decision
        # instead of running unconditionally after it.
        local tmp
        tmp="$(mktemp "$src_file.XXXXXX")" || { log "PULSE_SOURCE=auto: mktemp failed for $src_file - unchanged"; return 0; }
        if ! { printf 'PULSE_SOURCE=%s\n' "$new_source" > "$tmp" && mv -f -- "$tmp" "$src_file"; }; then
            rm -f -- "$tmp"
            log "FAILED to persist PULSE_SOURCE=$new_source to $src_file (see above)"
            return 0
        fi
        log "resolved PULSE_SOURCE=$new_source (was '${old_source:-<none>}')"
        if (( AUTO_RESTART )); then
            if ! systemctl is-active --quiet edy-rdp-guacd.service; then
                log "edy-rdp-guacd.service is not currently running - nothing to restart"
            else
                local cooldown="$DIR/.last-guacd-restart" now last=0
                now="$(date +%s)"
                [[ -f "$cooldown" ]] && last="$(cat -- "$cooldown" 2>/dev/null || echo 0)"
                [[ "$last" =~ ^[0-9]+$ ]] || last=0
                if (( now - last < RESTART_COOLDOWN_SECS )); then
                    log "skipping guacd restart -- one already happened $(( now - last ))s ago (cooldown ${RESTART_COOLDOWN_SECS}s; the next restart for any reason will pick up this value)"
                elif systemctl try-restart edy-rdp-guacd.service 2>/dev/null; then
                    printf '%s\n' "$now" > "$cooldown"
                    log "restarted edy-rdp-guacd.service to pick up the new PULSE_SOURCE"
                else
                    log "FAILED to restart edy-rdp-guacd.service (see: systemctl status edy-rdp-guacd.service)"
                fi
            fi
        fi
    elif [[ -z "$preview" && -e "$src_file" ]]; then
        rm -f -- "$src_file"
        log "removed stale generated $src_file (PULSE_SOURCE is not 'auto')"
    fi
}

# --- --check: the plan, no root, no writes -----------------------------------
if (( CHECK )); then
    seat_check   || fail "$SEAT_STATE"
    target_check || fail "$TGT_STATE"
    log "plan: dir=$DIR seat=$SOCKET ($SEAT_STATE) target=$T ($TGT_STATE)"
    [[ "$SEAT_STATE" == exists ]] && resolve_and_persist_source "$SOCKET" preview
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
    resolve_and_persist_source "$SOCKET"
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
        resolve_and_persist_source "$T"
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
resolve_and_persist_source "$T"
exit 0
