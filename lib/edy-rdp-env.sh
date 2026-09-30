# lib/edy-rdp-env.sh - the ONE reading of the .env grammar (DEPLOY-CONTRACT 4.1).
#
# Sourced, never executed. install.sh (placement, reconcile, --verify), deploy.sh
# (--verify) and the relay's start-time bootstrap (edy-rdp-bootstrap) all run
# THESE functions, so a value the installer accepts is a value the bootstrap
# accepts, and a key the bootstrap refuses is one the installer already refused.
# Before 1.4.0 the grammar lived three times - a python heredoc in install.sh, a
# sed in check 7 and a grep in deploy.sh - and the secret-shape rule lived only
# in deploy.sh, which is exactly how a .env could pass one and fail the next.
#
# Contract for every function here:
#   - bash 4+, safe under `set -Eeuo pipefail` (no pipeline is allowed to fail on
#     the no-match case, no unset variable is read);
#   - no side effect on source: nothing runs, nothing is declared but functions;
#   - every function RETURNS, never exits - the caller decides what a problem
#     costs (install.sh dies, --verify records a FAIL, the bootstrap exits 1);
#   - problems go to STDOUT, one per line, as "KEY: reason" (or "line N: reason"
#     for a line that has no usable key), so a caller can wrap them verbatim.
#
# The grammar - a strict subset of what sh, Python and systemd's EnvironmentFile
# all accept, so one file serves all three readers:
#   KEY=value      KEY="value with spaces"      EMPTY=
#   blank lines and full-line '#' comments are ignored; a trailing '#' is PART
#   OF THE VALUE; key ^[A-Z][A-Z0-9_]*$; no $, no backticks, no interpolation.

# --- parsing ---------------------------------------------------------------

# _env_scan FILE MODE - the one loop. MODE=data prints "KEY<TAB>VALUE" for every
# well-formed assignment (bad lines skipped); MODE=problems prints one line per
# grammar violation and nothing else. rc 1 if any violation was seen, in either
# mode, so data readers can stay lenient while checkers stay strict.
_env_scan() {
    local file=$1 mode=$2 n=0 raw line k v rc=0
    if [[ ! -r "$file" ]]; then
        [[ "$mode" == problems ]] && printf 'file: %s is missing or unreadable\n' "$file"
        return 1
    fi
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        n=$((n+1))
        line="${raw#"${raw%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" != *=* ]]; then
            [[ "$mode" == problems ]] && printf 'line %d: not KEY=VALUE\n' "$n"
            rc=1; continue
        fi
        k="${line%%=*}"; v="${line#*=}"
        k="${k%"${k##*[![:space:]]}"}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        if [[ ! "$k" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            [[ "$mode" == problems ]] && printf "line %d: bad key '%s' (must match [A-Z][A-Z0-9_]*)\n" "$n" "$k"
            rc=1; continue
        fi
        if (( ${#v} >= 2 )) && [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then v="${v:1:${#v}-2}"; fi
        if [[ "$v" == *'$'* || "$v" == *'`'* ]]; then
            [[ "$mode" == problems ]] && printf '%s: contains $ or ` - no interpolation (DEPLOY-CONTRACT 4.1, line %d)\n' "$k" "$n"
            rc=1; continue
        fi
        [[ "$mode" == data ]] && printf '%s\t%s\n' "$k" "$v"
    done < "$file"
    return $rc
}

# env_parse FILE - "KEY<TAB>VALUE" per assignment, file order. On a grammar
# error prints the problems INSTEAD and returns 1: a caller that wants data
# never has to tell the two apart on one stream.
env_parse() {
    local file=$1
    if _env_scan "$file" problems >/dev/null; then _env_scan "$file" data; return 0; fi
    _env_scan "$file" problems; return 1
}

env_check_grammar() { _env_scan "$1" problems; }

# env_keys FILE - sorted unique keys; rc 0 even for a file with bad lines.
env_keys() { _env_scan "$1" data 2>/dev/null | cut -f1 | sort -u || true; return 0; }

# env_get FILE KEY - the LAST value assigned (later lines win, as in the shell,
# python and systemd), unquoted. rc 1 with empty output when the key is absent;
# rc 0 with empty output when it is present and empty (EDY_RDP_REMOTE_ALLOW=).
env_get() {
    local file=$1 key=$2 k v found=0 val=""
    while IFS=$'\t' read -r k v; do
        [[ "$k" == "$key" ]] && { found=1; val="$v"; }
    done < <(_env_scan "$file" data 2>/dev/null || true)
    (( found )) || return 1
    printf '%s\n' "$val"
}

# --- checks: each prints its problems and returns 1 if it printed any ------

# env_check_required FILE DEFAULTS KEY... - every KEY present, and non-empty
# unless DEFAULTS ships it empty on purpose (EDY_RDP_REMOTE_ALLOW= is the
# fail-closed "feature off", not a missing value).
env_check_required() {
    local file=$1 defaults=$2 k v dv rc=0; shift 2
    for k in "$@"; do
        if ! v="$(env_get "$file" "$k")"; then
            printf '%s: required key missing\n' "$k"; rc=1; continue
        fi
        if [[ -z "$v" ]]; then
            dv="$(env_get "$defaults" "$k" 2>/dev/null || printf 'x')"
            [[ -z "$dv" ]] || { printf '%s: empty (.envdefault does not ship it empty)\n' "$k"; rc=1; }
        fi
    done
    return $rc
}

# env_check_secrets FILE - the rule deploy.sh used to enforce alone: a deployed
# .env carries locations and settings, never a credential. A key that is SHAPED
# like one (PASS, TOKEN, KEY, ...) and carries a value is refused - unless the
# suffix says it names a file, path, user or id (EDY_RDP_STATE_FILE is a path,
# EDY_RDP_DOOR_USER is an account name; neither is a secret).
env_check_secrets() {
    local file=$1 k v rc=0
    while IFS=$'\t' read -r k v; do
        [[ "$k" =~ (PASS|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|PASSPHRASE) ]] || continue
        [[ "$k" =~ _(FILE|PATH|DIR|NAME|ID|USER)$ ]] && continue
        [[ -z "${v// }" ]] && continue
        printf '%s: looks like a secret VALUE - a deployed .env carries locations and settings, never secrets (the 3390 door key lives in grd'"'"'s credential store)\n' "$k"
        rc=1
    done < <(_env_scan "$file" data 2>/dev/null || true)
    return $rc
}

# env_check_values FILE [--staged] - per-key validators, for keys PRESENT only
# (required-ness is env_check_required's job). --staged skips the one check
# that asks the HOST a question (does the admin group exist): a DESTDIR-staged
# install describes some other machine.
env_check_values() {
    local file=$1 staged=0 k v rc=0 port
    [[ "${2:-}" == --staged ]] && staged=1
    while IFS=$'\t' read -r k v; do
        case "$k" in
          EDY_RDP_GUACD)
            port="${v##*:}"
            # 10#: without it bash reads a leading zero as octal, '08' is an
            # arithmetic ERROR, and an error in the || chain is not a refusal.
            if [[ ! "$v" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
                printf '%s: must be host:port\n' "$k"; rc=1; fi ;;
          EDY_RDP_STATE_FILE)
            [[ "$v" == /* ]] || { printf '%s: must be an absolute path\n' "$k"; rc=1; } ;;
          EDY_RDP_LOG_LEVEL)
            case "$v" in DEBUG|INFO|WARNING|ERROR) ;;
              *) printf '%s: must be one of DEBUG INFO WARNING ERROR\n' "$k"; rc=1 ;; esac ;;
          EDY_RDP_ALLOW_ARGS)
            [[ "$v" == *--allow-target* ]] || { printf '%s: must carry at least one --allow-target\n' "$k"; rc=1; } ;;
          GUACD_IMAGE)
            [[ -n "$v" ]] || { printf '%s: must not be empty\n' "$k"; rc=1; } ;;
          GUACD_ENTRYPOINT)
            [[ "$v" == /* ]] || { printf '%s: must be an absolute path inside the image\n' "$k"; rc=1; } ;;
          EDY_RDP_ADMIN_GROUP)
            if [[ -z "$v" ]]; then printf '%s: must not be empty\n' "$k"; rc=1
            elif (( ! staged )) && ! getent group "$v" >/dev/null 2>&1; then
                printf "%s: group '%s' does not exist on this host\n" "$k" "$v"; rc=1; fi ;;
          EDY_RDP_SHADOW_GROUP)
            # Deliberately NO getent-group existence check (unlike ADMIN_GROUP
            # above): this is a project-specific group name that will not exist
            # on any host until `deploy.sh --with-users` creates it (or an
            # operator does, on a host where that flag was never passed), and
            # refusing every install/redeploy until then would be a needless,
            # deploy-breaking foot-gun. is_admin() already treats a nonexistent
            # group as "nobody in it" (fails closed), which is exactly this
            # feature's safe out-of-the-box default. Empty is a supported,
            # intentional way to turn the whole gate off (mirrors
            # EDY_RDP_REMOTE_ALLOW=).
            [[ -z "$v" || "$v" =~ ^[a-z_][a-z0-9_-]*$ ]] \
                || { printf "%s: must be empty (disables the shadow gate) or a unix group name\n" "$k"; rc=1; } ;;
          EDY_RDP_REMOTE_ADMIN_ONLY|EDY_RDP_DESKUI_ENABLE)
            case "$v" in ''|0|1) ;; *) printf '%s: must be empty, 0 or 1\n' "$k"; rc=1 ;; esac ;;
          EDY_RDP_PULSE_SEAT_UID)
            [[ "$v" =~ ^[0-9]+$ ]] || { printf '%s: must be a numeric uid\n' "$k"; rc=1; } ;;
          EDY_RDP_PULSE_SEAT_SOCKET)
            [[ -z "$v" || "$v" == /* ]] || { printf '%s: must be an absolute path\n' "$k"; rc=1; } ;;
          PULSE_SERVER)
            if [[ "$v" == unix:/run/pulse.sock ]]; then
                printf '%s: stale 1.3.x value - the socket is now unix:/run/pulse/native (docs/AUDIO.md)\n' "$k"; rc=1
            elif [[ -n "$v" && "$v" != unix:/* ]]; then
                printf '%s: must be unix:<path>\n' "$k"; rc=1; fi ;;
          EDY_RDP_DOOR_USER)
            [[ "$v" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf '%s: must be a unix user name\n' "$k"; rc=1; } ;;
          EDY_RDP_UPDATE_REPO)
            [[ "$v" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
                || { printf '%s: must be owner/repo\n' "$k"; rc=1; } ;;
        esac
    done < <(_env_scan "$file" data 2>/dev/null || true)
    return $rc
}

# env_validate FILE DEFAULTS [--staged] [--present-only] KEY... - the whole
# gate, in order: grammar, required keys (skipped with --present-only, for the
# pre-flight look at a file reconcile is about to complete), secret shapes,
# per-key values. Prints EVERY problem, not the first: an operator fixing a
# .env should get one list, not one round-trip per key. rc 1 if any.
env_validate() {
    local file=$1 defaults=$2 staged="" present_only=0 rc=0; shift 2
    while (($#)); do
        case "$1" in
          --staged)       staged=--staged; shift ;;
          --present-only) present_only=1; shift ;;
          *) break ;;
        esac
    done
    env_check_grammar "$file" || rc=1
    (( present_only )) || env_check_required "$file" "$defaults" "$@" || rc=1
    env_check_secrets "$file" || rc=1
    # shellcheck disable=SC2086
    env_check_values "$file" $staged || rc=1
    return $rc
}

# --- placement -------------------------------------------------------------

# env_place DEFAULTS FILE VERSION - put the configuration where the units read
# it, without ever clobbering the operator. Prints ONE line:
#   placed          FILE was absent: DEFAULTS copied with its first line
#                   replaced by a dated provenance header. Comments come along -
#                   they are the operator's documentation of every key.
#   added: K1 K2    FILE present: each key DEFAULTS has and FILE lacks is
#                   APPENDED with DEFAULTS' value under a dated header. Existing
#                   lines are never touched (>> only). This is what the Sep-18
#                   deploy needed and did not have: two new keys, an operator's
#                   file, and an installer that could only refuse.
#   unchanged       nothing to add.
# A commented-out key in DEFAULTS (#PULSE_SERVER=) is a comment, never added.
# rc 1 on a write failure.
env_place() {
    local defaults=$1 file=$2 version=$3 today
    today="$(date -u +%Y-%m-%d)"
    if [[ ! -e "$file" ]]; then
        {
            printf '# %s - placed by install.sh %s on %s from .envdefault. Edit values here;\n' "$file" "$version" "$today"
            printf '#   a re-install appends keys a new version adds and NEVER changes yours.\n'
            # The header this replaces is a COMMENT line. A DEFAULTS whose first
            # line is an assignment keeps it - dropping line 1 unconditionally
            # would silently lose a key.
            if [[ "$(sed -n 1p -- "$defaults")" == \#* ]]; then tail -n +2 -- "$defaults"; else cat -- "$defaults"; fi
        } > "$file.new" || { rm -f -- "$file.new"; return 1; }
        chmod 0644 -- "$file.new" && mv -f -- "$file.new" "$file" || { rm -f -- "$file.new"; return 1; }
        printf 'placed\n'; return 0
    fi
    # Append only into the regular file we expect: '>>' follows a symlink, and
    # this runs as root.
    [[ -f "$file" && ! -L "$file" ]] || { printf 'file: %s is not a regular file - refusing to append\n' "$file"; return 1; }
    local have k v added=() lines=()
    have="$(env_keys "$file")"
    while IFS=$'\t' read -r k v; do
        printf '%s\n' "$have" | grep -qxF -- "$k" && continue
        added+=("$k")
        # the raw line as DEFAULTS wrote it (quotes and all), not a re-rendering
        lines+=("$(grep -m1 -E "^[[:space:]]*${k}[[:space:]]*=" -- "$defaults" || printf '%s=%s' "$k" "$v")")
    done < <(_env_scan "$defaults" data 2>/dev/null || true)
    if ((${#added[@]}==0)); then printf 'unchanged\n'; return 0; fi
    {
        printf '\n# added by install.sh %s on %s: keys this version ships that this file lacked\n' "$version" "$today"
        printf '#   (values are .envdefault'"'"'s - review them)\n'
        printf '%s\n' "${lines[@]}"
    } >> "$file" || return 1
    printf 'added: %s\n' "${added[*]}"
}
