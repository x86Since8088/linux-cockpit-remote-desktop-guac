#!/usr/bin/env bash
#
# deploy.sh - the real deployment of cockpit-guac-rdp onto a host.
#
#   ./deploy.sh                       copy -> /opt/cockpit-guac-rdp, run the installed
#                                     install.sh (which places/validates .env). Enables NOTHING.
#   ./deploy.sh --with-users          also create the cockpit-guac-rdp group + edy-relay user
#   ./deploy.sh --with-deps           also install the OS prerequisites
#   ./deploy.sh --with-image          also pre-pull the pinned guacd image
#   ./deploy.sh --with-units          also ENABLE AND START the units
#   ./deploy.sh --all                 all four of the above
#   ./deploy.sh --with-locked-remote-desktop   opt-in: install+enable the "Allow
#                                     Locked Remote Desktop" extension for the
#                                     invoking user (remote-unlock the locked
#                                     screen; NOT in --all -- security tradeoff,
#                                     see docs/LOCKED-REMOTE-DESKTOP.md)
#   ./deploy.sh --install-to /srv/x   deploy somewhere else (absolute, recorded)
#   ./deploy.sh --wheels /path/dir    vendor these .whl files instead of `pip download`
#                                     (a host without index access; only matters once
#                                     requirements.txt names something)
#   ./deploy.sh --verify              check a deployed host, write nothing
#   ./deploy.sh --uninstall           run the installed install.sh --uninstall
#   ./deploy.sh --remove              ALSO delete the deployed payloads
#
# WHY THE FLAGS
#   This project brings up a container, a relay daemon, an nftables table that
#   decides who may reach guacd, a polkit rule and a D-Bus policy. A deployment
#   that silently started all of that is not a deployment anyone should run
#   twice. Copying files and rendering units is safe and is the default; changing
#   what this host is RUNNING is opt-in, per flag, and named in the output.
#
#   install.sh does none of it. It runs in both the dev and the deployed role,
#   and a dev install that enabled edy-rdp-relay.service would put two relays on
#   one host fighting over one socket and one firewall table.
#
# Self-contained on purpose: no shared framework, nothing sourced from outside
# this directory. This repo is cloned on its own.
set -Eeuo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SRC="$(cd -- "$(dirname -- "$SELF")" && pwd)"

# ONE declaration, and it is install.sh's. Sourced, never restated.
eval "$(sed -n '/^# BEGIN-MANIFEST/,/^# END-MANIFEST/p' "$SRC/install.sh")"
[[ -n "${PROJECT:-}" && ${#PAGE[@]} -gt 0 && ${#UNITS[@]} -gt 0 ]] \
    || { echo "FATAL could not read the manifest out of $SRC/install.sh" >&2; exit 1; }
# The same two libs install.sh and the start-time bootstrap run: ONE .env
# grammar (the secret-shape rule used to live only here), ONE reading of
# requires.txt (the PREREQS array used to live only here).
. "$SRC/lib/edy-rdp-env.sh"
. "$SRC/lib/edy-rdp-requires.sh"

VERSION="$( [[ -f "$SRC/VERSION" ]] && cat "$SRC/VERSION" || echo "1.1.1" )"
ROOT="/opt/$PROJECT"
ACTION=deploy
KEEP=1
WITH_USERS=0; WITH_DEPS=0; WITH_IMAGE=0; WITH_UNITS=0; WITH_ALRD=0; ALRD_USER=""
WHEELS=""

# The one true DEV location, and the RETIRED checkout-under-/opt this contract
# exists because of - assembled from named parts so that NEITHER appears as a
# literal anywhere in this file, including in this comment.
#
# These scripts ship into the payload. An audit whose own text matches its
# pattern is an audit with a permanent known exception, and an audit with a
# permanent known exception is one nobody runs a second time. So a recursive
# grep of a deployed tree for either root must come back completely empty,
# and the two lines below are what pay for that.
_ao=ai-orchestrator; _retired=git
DEV_ROOT="/srv/smb/share/sc/${_ao}-group/${_ao}-storage/projects"
RETIRED_ROOT="/opt/sc/${_retired}"

say()  { printf '  %-12s %s\n' "$1" "$2"; }
ok()   { printf '  ok   %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*" >&2; }
die()  { printf 'FATAL %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --install-to) ROOT="${2:-}"; shift 2 ;;
    --wheels)     WHEELS="${2:?--wheels needs a directory}"; shift 2 ;;
    --with-users) WITH_USERS=1; shift ;;
    --with-deps)  WITH_DEPS=1; shift ;;
    --with-image) WITH_IMAGE=1; shift ;;
    --with-units) WITH_UNITS=1; shift ;;
    --with-locked-remote-desktop) WITH_ALRD=1; shift ;;   # opt-in, NOT in --all (security tradeoff)
    --alrd-user)  ALRD_USER="${2:?--alrd-user needs a name}"; shift 2 ;;   # desktop user for the above
    --all)        WITH_USERS=1; WITH_DEPS=1; WITH_IMAGE=1; WITH_UNITS=1; shift ;;
    --verify)     ACTION=verify; shift ;;
    --uninstall)  ACTION=uninstall; shift ;;
    --remove)     ACTION=remove; shift ;;
    -h|--help)    sed -n '2,34p' "$SELF" | sed 's/^# \?//'; exit 0 ;;
    *)            die "unknown option: $1" ;;
  esac
done
[[ "$ROOT" == /* ]] || die "--install-to must be an absolute path (got: $ROOT)"
[[ -z "$WHEELS" || "$WHEELS" == /* ]] || die "--wheels must be an absolute path (got: $WHEELS)"

# The outcome, unmistakably. A job wrapper once masked this script's exit
# status and a deploy that had died half-way read as done (the Sep-18 deploy
# swapped the payload alias and never linked it). The last line is now either
# "DEPLOY OK <version>" or "DEPLOY FAILED (<step>)", whatever the wrapper does
# with the status; the EXIT trap covers die, set -e and a failing command alike.
STEP=start
step() { STEP=$1; printf '\n%s\n' "$1"; }
trap 'rc=$?; if (( rc != 0 )); then printf "\nDEPLOY FAILED (%s) rc=%d\n" "$STEP" "$rc" >&2; fi' EXIT

D="${DESTDIR:-}"
ROOT_D="$D$ROOT"
NEW="$ROOT_D/payload-$VERSION"
ENVF="$ROOT_D/.env"
LEGACY_DEFAULT="$D/etc/default/edy-rdp"

[[ $EUID -eq 0 || -n "$D" ]] || die "run as root, through the job runner
(/srv/jobs, submit-job.sh). Nothing was changed."

OWN=()
[[ $EUID -eq 0 && -z "$D" ]] && OWN=(-o root -g root)

remove_old_payload() {
    local p=$1 real root_real
    [[ -d "$p" && ! -L "$p" ]]  || die "refusing: $p is not a real directory"
    real="$(readlink -f -- "$p")"           || die "refusing: cannot resolve $p"
    root_real="$(readlink -f -- "$ROOT_D")" || die "refusing: cannot resolve $ROOT_D"
    [[ "$real" == "$root_real"/payload-* ]] \
        || die "refusing to recursively remove $real - not a payload dir under $root_real"
    [[ "$real" != "$root_real" ]] || die "refusing: that is the install root"
    rm -rf -- "$real"; say removed "$real"
}

# ---------------------------------------------------------------------------
# OS prerequisites (--with-deps), from requires.txt through lib/edy-rdp-requires.sh:
# the names, the minimum versions, the probes and the distro package mapping all
# live there, shared with install.sh (check 8b) and the relay's bootstrap. This
# file no longer carries a list of its own to disagree with. A re-run installs
# nothing that is present at or above its minimum.
# ---------------------------------------------------------------------------
MISSING_PREREQS=()

report_prereqs() {   # always runs; only --with-deps installs
    req_load "$SRC/$REQUIRES" || die "cannot parse $SRC/$REQUIRES"
    if req_check; then
        ok "prerequisites: all ${#REQ_NAMES[@]} present at or above minimum (FreeRDP3 client: $(req_freerdp_bin))"
        return 0
    fi
    MISSING_PREREQS=("${REQ_MISSING[@]}" "${REQ_OUTDATED[@]}")
    printf '%s\n' "  prerequisites MISSING or below minimum: ${MISSING_PREREQS[*]}"
    return 1
}

install_deps() {
    local cmd
    report_prereqs && return 0
    cmd="$(req_fix_command "${MISSING_PREREQS[@]}")"
    [[ "$cmd" != "install manually"* ]] || die "no supported package manager found; $cmd
    (see docs/COMPATIBILITY.md)"
    say installing "$cmd"
    eval "$cmd" || die "prerequisite install failed (docs/COMPATIBILITY.md has the
    per-distro notes)"
    req_freerdp_bin >/dev/null 2>&1 || die "a FreeRDP >= 3 client is still absent.
    Debian 12 and RHEL 8 ship only FreeRDP 2, which lacks RDSTLS - the protocol
    grd's port 3390 handover requires. See docs/COMPATIBILITY.md."
    # The bridge launcher invokes 'xfreerdp3' by name; alias where it is 'xfreerdp'.
    if ! command -v xfreerdp3 >/dev/null 2>&1 && [[ "$(req_freerdp_bin)" == "xfreerdp" ]]; then
        ln -sf "$(command -v xfreerdp)" /usr/local/bin/xfreerdp3
        say aliased "xfreerdp3 -> $(command -v xfreerdp)"
    fi
}

# The migration: this project's relay group used to be named edy-rdp. A host
# deployed before the rename has real members in that group; a plain
# check-and-create here would leave THAT group alone and groupadd a brand-new,
# EMPTY $RELAY_GROUP, so the next unit restart picks up the new group and every
# existing edy-rdp member silently loses access. groupmod -n renames in place -
# same GID, same members, nothing dropped.
#
# Runs UNCONDITIONALLY in do_deploy(), NOT gated behind --with-users, same
# reasoning as migrate_legacy_env() above: renaming an EXISTING group to the
# name this version's units now reference is a compatibility carry-forward for
# a host that already opted in once, not a new grant of capability. install.sh's
# own preflight (check 8) requires $RELAY_GROUP to exist UNCONDITIONALLY,
# regardless of --with-users - it always has, on the assumption that a fresh
# host ran --with-users exactly once at initial setup and every plain redeploy
# since has relied on the group already being there. Gating the rename itself
# behind --with-users broke that assumption for every host deployed before this
# rename (this project's own edt1 included): a plain, no-flags redeploy - the
# pattern used for every routine update this project makes, and the ONLY one
# self-update's own deploy.sh invocation ever uses - would otherwise hit
# install.sh's fatal group-missing check on every such host until an operator
# remembered to pass --with-users first. A brand-new host where NEITHER name
# exists is untouched here (return 0) and still needs --with-users on its
# first-ever deploy, exactly as it always has - only the RENAME of an existing
# group is unconditional, not the creation of a new one.
migrate_group_rename() {
    # A staged/DESTDIR deploy (the test suite's own roundtrip tests, run on a
    # real developer/CI host that may itself have a genuine "edy-rdp" group)
    # exercises the file-copying/rendering logic only and must NEVER touch the
    # actual host's real system accounts -- unlike create_users(), which is
    # implicitly protected because no test ever passes --with-users, this
    # function is unconditional and needs its OWN explicit guard, the same one
    # preflight's noexec check and the --with-units unit-enabling step already
    # use. Found by this project's own test suite: without this guard, running
    # the staged roundtrip test on a host that already has a real "edy-rdp"
    # group renamed THAT REAL GROUP.
    [[ -z "$D" ]] || return 0
    getent group "$RELAY_GROUP" >/dev/null && return 0
    getent group edy-rdp >/dev/null || return 0
    groupmod -n "$RELAY_GROUP" edy-rdp \
        || die "could not rename group edy-rdp -> $RELAY_GROUP. Fix by hand
    (groupmod -n $RELAY_GROUP edy-rdp) and re-run. Nothing else was changed."
    say renamed "group edy-rdp -> $RELAY_GROUP (GID and members preserved)"
}

create_users() {
    getent group "$RELAY_GROUP" >/dev/null \
        || { groupadd --system "$RELAY_GROUP"; say created "group $RELAY_GROUP"; }
    getent passwd "$RELAY_USER" >/dev/null \
        || { useradd --system --no-create-home --shell /usr/sbin/nologin \
                     -g "$RELAY_GROUP" "$RELAY_USER"; say created "user $RELAY_USER"; }
    ok "$RELAY_USER:$RELAY_GROUP present (uid $(id -u "$RELAY_USER"))"
}

pull_image() {
    local img
    img="$(env_get "$ENVF" GUACD_IMAGE || true)"
    [[ -n "$img" ]] || die "GUACD_IMAGE is not set in $ENVF"
    command -v podman >/dev/null 2>&1 || die "podman is not installed (--with-deps)"
    say pulling "$img"
    podman pull "$img" >/dev/null && ok "guacd image ready: $img" \
        || warn "could not pull $img; edy-rdp-guacd.service will pull it on first start"
}

# ---------------------------------------------------------------------------
copy_declared_payload_into() {
    local dst=$1 f d
    install -d -m 0755 "${OWN[@]}" -- "$dst"
    for f in "${PAGE[@]}"; do install -m 0644 "${OWN[@]}" -- "$SRC/$f" "$dst/$f"; done
    for f in "${PAGE_DIRS[@]}"; do
        install -d -m 0755 -- "$dst/$f"
        find "$SRC/$f" -maxdepth 1 -type f -exec install -m 0644 -- {} "$dst/$f/" \;
    done
    for f in "${LIBEXEC[@]}"; do
        d="$dst/$(dirname -- "${f%%:*}")"
        install -d -m 0755 -- "$d"
        install -m 0755 "${OWN[@]}" -- "$SRC/${f%%:*}" "$dst/${f%%:*}"
    done
    # libs are sourced, never executed: 0644, and install.sh links them beside
    # the scripts under $LIBEXECDIR
    for f in "${LIBS[@]}"; do
        d="$dst/$(dirname -- "${f%%:*}")"
        install -d -m 0755 -- "$d"
        install -m 0644 "${OWN[@]}" -- "$SRC/${f%%:*}" "$dst/${f%%:*}"
    done
    install -d -m 0755 -- "$dst/systemd" "$dst/hardening"
    for f in "${UNITS[@]}"; do
        [[ -f "$SRC/systemd/$f.in" ]] && install -m 0644 -- "$SRC/systemd/$f.in" "$dst/systemd/$f.in"
        [[ -f "$SRC/systemd/$f"    ]] && install -m 0644 -- "$SRC/systemd/$f"    "$dst/systemd/$f"
    done
    for f in "${SYSFILES[@]}"; do
        d="$dst/$(dirname -- "${f%%:*}")"
        install -d -m 0755 -- "$d"
        install -m 0644 "${OWN[@]}" -- "$SRC/${f%%:*}" "$dst/${f%%:*}"
    done
    install -m 0644 "${OWN[@]}" -- "$SRC/$ENVDEFAULT" "$dst/$ENVDEFAULT"
    # requires.txt SHIPS now: the bootstrap verifies the host against it at every
    # relay start. requirements.txt ships with it; when it names anything, the
    # wheels the bootstrap installs OFFLINE ride along under wheels/ - a service
    # start must never reach an index, so the fetch happens HERE, once, on a host
    # with access (or comes pre-fetched via --wheels on one without).
    install -m 0644 "${OWN[@]}" -- "$SRC/$REQUIRES"     "$dst/$REQUIRES"
    install -m 0644 "${OWN[@]}" -- "$SRC/$REQUIREMENTS" "$dst/$REQUIREMENTS"
    if (( $(req_pip_count "$SRC/$REQUIREMENTS") > 0 )); then
        install -d -m 0755 -- "$dst/wheels"
        if [[ -n "$WHEELS" ]]; then
            local nw=0
            for f in "$WHEELS"/*.whl; do
                [[ -f "$f" ]] || continue
                install -m 0644 "${OWN[@]}" -- "$f" "$dst/wheels/"; nw=$((nw+1))
            done
            (( nw > 0 )) || die "--wheels $WHEELS holds no .whl file"
            say vendored "$nw wheel(s) from $WHEELS"
        else
            python3 -m pip download -q -d "$dst/wheels" -r "$SRC/$REQUIREMENTS" \
                || die "pip download failed. A host without index access needs the wheels supplied:
    ./deploy.sh --wheels <dir of .whl built with 'pip download -d <dir> -r requirements.txt' on a connected host>"
            say vendored "wheels for $REQUIREMENTS into $dst/wheels (pip download)"
        fi
    fi
    install -m 0755 "${OWN[@]}" -- "$SRC/install.sh"  "$dst/install.sh"
    printf '%s\n' "$VERSION" > "$dst/VERSION"; chmod 0644 "$dst/VERSION"
    [[ -f "$SRC/LICENSE" ]] && install -m 0644 -- "$SRC/LICENSE" "$dst/LICENSE"
    # Opt-in "Allow Locked Remote Desktop" bundle + its enabler, so a deployed host
    # can run --with-locked-remote-desktop. Third-party (GPL, see extensions/*/COPYING).
    if [[ -d "$SRC/extensions/allowlockedremotedesktop@kamens.us" ]]; then
        install -d -m 0755 -- "$dst/extensions/allowlockedremotedesktop@kamens.us"
        install -m 0755 "${OWN[@]}" -- "$SRC/extensions/enable-locked-remote-desktop.sh" "$dst/extensions/enable-locked-remote-desktop.sh"
        find "$SRC/extensions/allowlockedremotedesktop@kamens.us" -maxdepth 1 -type f \
             -exec install -m 0644 -- {} "$dst/extensions/allowlockedremotedesktop@kamens.us/" \;
    fi
    # NOT shipped: .git/, docs/, img/, patches/, pod/, relay/test_*.py, tests/,
    # run_tests.sh, deploy.sh itself, CHANGELOG.md, README.md, any .env.
    # README.md in particular must not ship: it quotes the development root, and
    # `grep -rl <dev root> /opt/cockpit-guac-rdp` has to return nothing for the
    # one audit that catches a payload reaching back into a checkout.
    # relay/test_*.py are excluded by LIBEXEC naming them one by one, not by glob.
    return 0
}

# The migration: /etc/default/edy-rdp used to be this project's settings file.
# It is now [install path]/.env, because it was `.envdefault` wearing the wrong
# hat (DEPLOY-CONTRACT section 5: behaviour is .envdefault, content is
# etcdefaults/). An operator's edits move ACROSS; nothing is deleted here.
#
# ONLY the migration remains. Placing a missing .env from .envdefault, adding the
# keys a new version ships to a present one, and validating the result are
# install.sh's place_env now (it runs next, from the installed payload): the
# byte-copy this function used to do could not add a key to an operator's file,
# so an upgrade that added one died in install.sh's check 7 until somebody
# edited by hand - the Sep-18 deploy. The keys a legacy file lacks are appended
# by that same reconcile, so nothing here has to warn about them.
migrate_legacy_env() {
    if [[ -e "$ENVF" ]]; then
        say kept "$ENVF (install.sh places or reconciles it next)"
    elif [[ -f "$LEGACY_DEFAULT" ]]; then
        install -m 0644 "${OWN[@]}" -- "$LEGACY_DEFAULT" "$ENVF"
        say migrated "$LEGACY_DEFAULT -> $ENVF (your edits, carried across)"
        warn "$LEGACY_DEFAULT is left in place and is NO LONGER READ. Nothing here
       deletes your file - but two config files where one is ignored is how a
       setting gets changed and never takes effect. Remove it once you agree."
    fi
}

preflight() {
    printf 'deploy pre-flight\n'
    [[ -f "$SRC/install.sh" && -f "$SRC/$ENVDEFAULT" && -f "$SRC/$REQUIRES" && -f "$SRC/$REQUIREMENTS" ]] \
        || die "install.sh, $ENVDEFAULT, $REQUIRES or $REQUIREMENTS is missing"
    if [[ -z "$D" ]]; then
        local mp; mp="$(df -P "$(dirname -- "$ROOT")" 2>/dev/null | awk 'NR==2{print $6}')"
        if [[ -n "$mp" ]] && findmnt -no OPTIONS --target "$mp" 2>/dev/null | tr ',' '\n' | grep -qx noexec; then
            die "the filesystem holding $ROOT ($mp) is mounted noexec. Every script
    under $LIBEXECDIR would fail at first click. Use --install-to, or remount."
        fi
    fi
    ok "install path $ROOT is usable"
    # The .env this host ALREADY has, vetted BEFORE anything is copied or the
    # alias swapped. install.sh's check 7 makes this same call - but it runs from
    # the INSTALLED payload, after the swap, and a refusal there is the Sep-18
    # half-deployed state all over again (alias new, links old; I43), only louder.
    # A stale or invalid operator value (a 1.3.x PULSE_SERVER, a LOUD log level)
    # must stop the deploy while the host is still exactly as it was. Required-
    # ness is not asked: reconcile appends the keys a new version adds. A legacy
    # /etc/default/edy-rdp about to be migrated is the same file one step earlier.
    local envf_now="" problems
    if   [[ -f "$ENVF" ]];           then envf_now="$ENVF"
    elif [[ -f "$LEGACY_DEFAULT" ]]; then envf_now="$LEGACY_DEFAULT"; fi
    if [[ -n "$envf_now" ]]; then
        # shellcheck disable=SC2086
        if problems="$(env_validate "$envf_now" "$SRC/$ENVDEFAULT" ${D:+--staged} --present-only)"; then
            ok "$envf_now validates (present keys)"
        else
            die "$envf_now would be refused by install.sh - stopping BEFORE anything is copied or swapped:
$(sed 's/^/    /' <<<"$problems")
    Fix the named key(s) and re-run. Nothing was changed."
        fi
    fi
    report_prereqs || warn "deploy will copy files, but the relay cannot run until these
       exist. Re-run with --with-deps, or install them yourself."
    ok "manifest: ${#PAGE[@]} page files, ${#LIBEXEC[@]} libexec, ${#LIBS[@]} libs, ${#UNITS[@]} units, ${#SYSFILES[@]} system files"
}

do_deploy() {
    STEP=pre-flight
    preflight
    ((WITH_DEPS)) && { step "OS prerequisites"; install_deps; }
    step "deploy $PROJECT $VERSION -> $ROOT"
    install -d -m 0755 "${OWN[@]}" -- "$ROOT_D"

    rm -rf -- "$NEW.tmp"
    copy_declared_payload_into "$NEW.tmp"
    [[ -d "$NEW" ]] && remove_old_payload "$NEW"
    mv -T -- "$NEW.tmp" "$NEW"; say copied "$NEW"

    ln -sfn -- "payload-$VERSION" "$ROOT_D/payload.new"
    mv -T -- "$ROOT_D/payload.new" "$ROOT_D/payload"
    say swapped "$ROOT_D/payload -> payload-$VERSION"

    step "configuration"
    migrate_legacy_env
    migrate_group_rename
    ((WITH_USERS)) && { step "users"; create_users; }

    # install.sh BEFORE the image pull: it places .env, and GUACD_IMAGE is read
    # from that file. (Users before install.sh: its check 8 wants them.)
    step "running the INSTALLED install.sh (not this checkout copy)"
    DESTDIR="$D" "$ROOT_D/payload/install.sh"

    ((WITH_IMAGE)) && { step "guacd image"; pull_image; }

    STEP="pruning old payloads"
    local p keepers
    mapfile -t keepers < <(ls -1d "$ROOT_D"/payload-* 2>/dev/null | grep -v "payload-$VERSION\$" | sort -r)
    for p in "${keepers[@]:$KEEP}"; do [[ -n "$p" ]] && remove_old_payload "$p"; done

    if ((WITH_UNITS)) && [[ -z "$D" ]]; then
        step "enabling units (--with-units)"
        # Order matters: the firewall table first, so 4822 is never briefly
        # world-reachable; then guacd; then the sockets that activate the relay.
        systemd-tmpfiles --create /usr/lib/tmpfiles.d/edy-rdp.conf || true
        systemctl daemon-reload
        dbus-send --system --type=method_call --dest=org.freedesktop.DBus \
            / org.freedesktop.DBus.ReloadConfig 2>/dev/null || true
        systemctl enable --now edy-rdp-firewall.service && say enabled edy-rdp-firewall.service
        systemctl enable --now edy-rdp-guacd.service    && say enabled edy-rdp-guacd.service
        systemctl enable --now edy-rdp-relay.socket edy-rdp-control.socket \
                               edy-rdp-reaper.timer && say enabled "relay+control sockets, reaper timer"
        systemctl start edy-rdp-relay.service || true
        # Audio: the path unit for the seat uid binds the pulse socket into the
        # shared dir at every login, so it reaches the running container (I42).
        local uid
        uid="$(env_get "$ENVF" EDY_RDP_PULSE_SEAT_UID || echo 1000)"
        systemctl enable --now "edy-rdp-pulse-seat@${uid}.path" \
            && say enabled "edy-rdp-pulse-seat@${uid}.path (audio bind on seat login)"
        # PathChanged= fires on the NEXT change in the pulse directory, never for a
        # socket that already exists when the watch starts (and PathExists= would
        # busy-loop the path unit to death - see the unit). A seat logged in right
        # now is bound by this one explicit run; the script is idempotent.
        systemctl start "edy-rdp-pulse-rebind@${uid}.service" \
            && say bound "seat ${uid} pulse socket, if logged in (edy-rdp-pulse-rebind@${uid}.service)" \
            || warn "edy-rdp-pulse-rebind@${uid}.service failed: journalctl -t edy-rdp-pulse-bind"
        warn "edy-rdp-rotate-rdplogin.timer was NOT enabled. It rotates the 3390
       greeter door credential, which only matters once that door is configured
       at all (docs/KNOWN_ISSUES.md I29). Enable it deliberately:
           systemctl enable --now edy-rdp-rotate-rdplogin.timer"
    else
        printf '\nunits were rendered and placed, and NOT enabled.\n'
    fi

    if ((WITH_ALRD)); then
        step "locked-remote-desktop extension (--with-locked-remote-desktop)"
        # Opt-in and security-sensitive: it lets a remote RDP client unlock the
        # locked screen (and, mirroring the physical seat, the console itself).
        # Per-USER: the dconf write needs the target's live session. SUDO_USER is
        # empty on the /srv/jobs root path, so require an explicit --alrd-user there
        # rather than guessing (never target root).
        local au="${ALRD_USER:-${SUDO_USER:-}}"
        if [[ -z "$au" || "$au" == root ]]; then
            warn "skipped --with-locked-remote-desktop: no desktop user resolved (pass
       --alrd-user NAME, or run it yourself as that user, IN their session):
           $ROOT_D/payload/extensions/enable-locked-remote-desktop.sh"
        else
            "$ROOT_D/payload/extensions/enable-locked-remote-desktop.sh" --user "$au" \
                || warn "enable-locked-remote-desktop failed (run it in $au's graphical session)"
        fi
    fi

    cat <<EOF

deployed. This host no longer depends on the development share.

  bring it up:   sudo $SELF --with-units
  who may use it: usermod -aG $RELAY_GROUP <user>  (docs/GROUP-ACCESS-MODEL.md - who that
                 actually admits, and what console/remote/vnc need on top of it)
  verify:        ss -tlnp | grep 4822          (127.0.0.1 only)
                 nft list table inet edy_rdp_guacd
                 ls -l /run/edy-rdp/guacd.sock
  rollback:      ln -sfn payload-<older> $ROOT/payload.new \\
                 && mv -T $ROOT/payload.new $ROOT/payload && $ROOT/payload/install.sh
  configure:     \$EDITOR $ENVF   then  systemctl restart edy-rdp-relay.service
  cockpit.socket was NOT touched.

DEPLOY OK $VERSION
EOF
}

do_verify() {
    STEP=verify
    printf 'deploy verify\n'
    local rc=0 problems p
    [[ -L "$ROOT_D/payload" ]] && ok "$ROOT_D/payload -> $(readlink -- "$ROOT_D/payload")" \
                               || { echo "  FAIL $ROOT_D/payload is not a symlink"; printf 'DEPLOY VERIFY FAILED\n'; return 1; }
    [[ -f "$ENVF" ]] && ok "$ENVF present" || { echo "  FAIL $ENVF missing"; printf 'DEPLOY VERIFY FAILED\n'; return 1; }
    # the whole .env gate (grammar, required keys, secret shapes, per-key rules) -
    # the same lib install.sh placed it with and the bootstrap starts the relay with.
    # --staged under DESTDIR: the admin group named there belongs to another host.
    # shellcheck disable=SC2086
    if problems="$(env_validate "$ENVF" "$SRC/$ENVDEFAULT" ${D:+--staged} "${REQUIRED_ENV[@]}")"; then
        ok "$ENVF validates with every REQUIRED_ENV key"
    else
        while IFS= read -r p; do [[ -n "$p" ]] && echo "  FAIL .env: $p"; done <<<"$problems"
        rc=1
    fi
    if grep -RIn -e "$DEV_ROOT" -e "$RETIRED_ROOT" -- "$ROOT_D/payload/" "$ENVF" 2>/dev/null; then
        echo "  FAIL a deployed file names the development share or the retired root (above)"
        rc=1
    else
        ok "no deployed file names the development share or the retired root"
    fi
    "$ROOT_D/payload/install.sh" --verify || rc=1
    if (( rc == 0 )); then printf '\nDEPLOY VERIFY OK\n'; else printf '\nDEPLOY VERIFY FAILED\n'; fi
    return $rc
}

do_uninstall() {
    [[ -x "$ROOT_D/payload/install.sh" ]] \
        || die "no installed payload at $ROOT_D/payload; nothing to uninstall"
    "$ROOT_D/payload/install.sh" --uninstall
}

do_remove() {
    [[ -x "$ROOT_D/payload/install.sh" ]] && "$ROOT_D/payload/install.sh" --uninstall || true
    local p
    for p in "$ROOT_D"/payload-*; do [[ -d "$p" ]] && remove_old_payload "$p"; done
    [[ -L "$ROOT_D/payload" ]] && { rm -f -- "$ROOT_D/payload"; say unlinked "$ROOT_D/payload"; }
    cat <<EOF

  KEPT: $ENVF, $ROOT_D itself, the $RELAY_GROUP group, the $RELAY_USER user,
  the guacd container image, and every OS package this script installed.
  --remove removes what this script COPIED. It does not un-provision a host:
  deleting a system uid that files elsewhere may still be owned by, or removing
  packages another service now depends on, is not something a deploy script
  should decide. Each is one deliberate command if you want it.
EOF
}

case "$ACTION" in
    deploy)    do_deploy ;;
    verify)    do_verify ;;
    uninstall) do_uninstall ;;
    remove)    do_remove ;;
esac
