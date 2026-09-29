#!/usr/bin/env bash
#
# install.sh - in-place install of cockpit-guac-rdp, BY SYMLINK.
#
#   ./install.sh                install / re-install from wherever this file is
#   ./install.sh --with-units   also render units in a DEV install (see below)
#   ./install.sh --uninstall    remove what we installed, keep every byte of data
#   ./install.sh --verify       report this host's state, write nothing
#
# It does not copy the payload. It LINKS the files beside it into the places
# Cockpit, systemd and the shell look, so the same script gives a live-editing
# dev install when run from a checkout and a production install when run from
# /opt/cockpit-guac-rdp/payload. Nothing below branches on which one it is to
# decide WHAT to link - only to record which it did.
#
# WHAT THIS NO LONGER DOES, and why
#   It does not install OS packages, create the cockpit-guac-rdp group or the edy-relay
#   user, pull the guacd image, or enable/start/stop a single unit. All of that
#   changes the RUNNING STATE of a host, and it belongs to deploy.sh - the script
#   that only ever runs on a host being deployed to. install.sh runs in both
#   roles, and a dev install that enables edy-rdp-relay.service would put two
#   relays on one host fighting over one socket and one nftables table.
#   It VERIFIES those prerequisites: the relay user and group it refuses without
#   (naming the command that creates them); the OS packages it REPORTS against
#   requires.txt (check 8b) and links anyway - the relay's start-time bootstrap
#   is what refuses to start until they exist, with the exact fix command.
#
#   It never touches cockpit.socket. Cockpit is live on this host and rescans its
#   package directory when a session starts; a page reload is enough.
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# BEGIN-MANIFEST
# The ONE declaration. deploy.sh sources these very lines out of this file, so
# there is no second list to disagree with this one.
PROJECT=cockpit-guac-rdp
PAGE_NAME=guac-rdp
PAGE=(manifest.json index.html guac-rdp.js guac-proto.js guac-rdp.css)
# An asset directory linked WHOLE - the JC-6 escape hatch, and the only one.
# It must contain servable assets and nothing else; the top level stays per-file
# and the payload root is never linked.
PAGE_DIRS=(guacamole-common-js)
HELPERS=()                       # nothing here is called from /usr/local/sbin
# Internal executables and the modules they import. "src:installed-name" pairs.
# /usr/libexec/<pkg> is where FHS puts programs a package runs but a user does
# not; the units name it, and it is NOT /usr/local/sbin because none of these is
# an operator command.
LIBEXEC=(relay/edy_rdp_relay.py:edy_rdp_relay.py
         relay/edy_rdp_reaper.py:edy_rdp_reaper.py
         relay/session_registry.py:session_registry.py
         relay/control.py:control.py
         relay/bridge.py:bridge.py
         relay/selfupdate.py:selfupdate.py
         bridge/edy-rdp-bridge-start.sh:edy-rdp-bridge-start
         bridge/edy-rdp-krb-preflight.sh:edy-rdp-krb-preflight.sh
         headless/edy-rdp-headless-start.sh:edy-rdp-headless-start
         headless/edy-rdp-headless-stop.sh:edy-rdp-headless-stop
         waylandvnc/edy-rdp-waylandvnc-start.sh:edy-rdp-waylandvnc-start
         waylandvnc/edy-rdp-waylandvnc-stop.sh:edy-rdp-waylandvnc-stop
         unlock/edy-rdp-unlock.sh:edy-rdp-unlock
         deskui/edy-rdp-deskui.sh:edy-rdp-deskui
         rotate/edy-rdp-rotate-rdplogin.sh:edy-rdp-rotate-rdplogin
         bootstrap/edy-rdp-bootstrap.sh:edy-rdp-bootstrap
         pulse/edy-rdp-pulse-bind.sh:edy-rdp-pulse-bind
         selfupdate/edy-rdp-selfupdate-apply.py:edy-rdp-selfupdate-apply
         selfupdate/edy-rdp-selfupdate-rollback.py:edy-rdp-selfupdate-rollback)
# Sourced libraries (not entry points): linked into $LIBEXECDIR beside the scripts
# that source them, so a deployed host has ONE copy of the .env grammar and ONE
# reading of requires.txt - the same code install.sh, deploy.sh and the start-time
# bootstrap run.
LIBS=(lib/edy-rdp-env.sh:edy-rdp-env.sh
      lib/edy-rdp-requires.sh:edy-rdp-requires.sh)
UNITS=(edy-rdp-guacd.service edy-rdp-relay.socket edy-rdp-control.socket
       edy-rdp-relay.service edy-rdp-reaper.service edy-rdp-reaper.timer
       edy-rdp-headless@.service edy-rdp-firewall.service
       edy-rdp-rotate-rdplogin.service edy-rdp-rotate-rdplogin.timer
       # Template units the relay starts on demand (edy-relay is polkit-granted to
       # start these families). They MUST be placed by a clean install; they render
       # from their .in and their ExecStart resolves to a shipped LIBEXEC helper.
       # unlock@/waylandvnc@ were previously omitted here and only ever worked on
       # the dev host, where the units had been hand-placed (see docs/KNOWN_ISSUES).
       edy-rdp-unlock@.service edy-rdp-waylandvnc@.service edy-rdp-deskui@.service
       # Audio: a path unit per seat uid that binds the seat's pulse socket into the
       # SHARED /run/edy-rdp-pulse the moment it appears (login), so it propagates into
       # the running guacd container without a restart (KNOWN_ISSUES I42).
       edy-rdp-pulse-seat@.path edy-rdp-pulse-rebind@.service
       # Self-update: deliberately NOT templated (no %i) -- see
       # systemd/edy-rdp-selfupdate-apply.service.in for why that is a stronger
       # property here than the %i-templated units above.
       edy-rdp-selfupdate-apply.service edy-rdp-selfupdate-rollback.service)
# System files that are COPIED (rendered where they carry a placeholder), because
# the software that reads them - systemd-tmpfiles, dbus, polkit, nft - does not
# follow a symlink out of its own configuration directory in every distro's
# policy. "src:absolute-destination" pairs.
SYSFILES=(systemd/edy-rdp-tmpfiles.conf:/usr/lib/tmpfiles.d/edy-rdp.conf
          hardening/org.gnome.RemoteDesktop.handover.conf:/etc/dbus-1/system.d/org.gnome.RemoteDesktop.handover.conf
          hardening/edy-rdp-headless.rules:/etc/polkit-1/rules.d/49-edy-rdp-headless.rules
          hardening/edy-rdp-guacd.nft:/etc/nftables.d/edy-rdp-guacd.nft
          hardening/edy-rdp-headless.nft:/etc/nftables.d/edy-rdp-headless.nft)
SEEDS=()
ENVDEFAULT=.envdefault
REQUIRES=requires.txt          # OS prerequisites + guacd image (parsed by lib/edy-rdp-requires.sh)
REQUIREMENTS=requirements.txt  # pip requirements for the relay (empty today); non-empty => venv
# Present AND non-empty in a placed .env, unless .envdefault ships the key empty
# on purpose (EDY_RDP_REMOTE_ALLOW= is "feature off"; it is not listed here).
REQUIRED_ENV=(EDY_RDP_GUACD EDY_RDP_ADMIN_GROUP EDY_RDP_STATE_FILE
              EDY_RDP_LOG_LEVEL EDY_RDP_ALLOW_ARGS GUACD_IMAGE GUACD_ENTRYPOINT
              EDY_RDP_PULSE_SEAT_UID)
UNITDIR=/etc/systemd/system
LIBEXECDIR=/usr/libexec/edy-rdp
RELAY_USER=edy-relay
RELAY_GROUP=cockpit-guac-rdp
# END-MANIFEST
# ---------------------------------------------------------------------------

# readlink -f FIRST, then dirname. `dirname "${BASH_SOURCE[0]}"` alone - which is
# what this script used to do - makes an install.sh invoked through a symlink
# resolve its payload relative to the LINK's directory.
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SRC="$(cd -- "$(dirname -- "$SELF")" && pwd)"

# Shared with deploy.sh and the start-time bootstrap: ONE .env grammar, ONE reading
# of requires.txt. Sourced from the payload beside this file, so the deployed copy
# and the checkout run the same code.
. "$SRC/lib/edy-rdp-env.sh"
. "$SRC/lib/edy-rdp-requires.sh"

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

# WHICH KIND OF INSTALL IS THIS? Decided by LAYOUT, never by a path prefix.
# DEV_ROOT above is now ONLY an audit pattern for check 9; nothing branches on
# it any more.
#
# deploy.sh writes <install path>/payload-<version>/ and points a sibling
# `payload` symlink at it; swapping that symlink IS an upgrade or rollback, so
# this is a DEPLOYED payload exactly when our own directory is what that
# symlink resolves to. A checkout has no such symlink.
#
# The old `$SRC == $DEV_ROOT/*` test got a checkout ANYWHERE ELSE wrong: it
# called itself `deployed`, so it skipped the group-writable warning, recorded
# INSTALL_KIND=deployed for a host that was not self-sustaining, and dropped
# "THE CHECKOUT IS NOT TOUCHED" from an uninstall. Layout cannot drift when a
# tree moves. Computed from $SRC, never $ROOT, which may be derived from KIND.
# Two ways to be a deployed payload. The first is the normal one: the `payload`
# alias points at us. The second covers a PREVIOUS payload being run directly -
# a rollback done without swapping the alias first - which is still a deployed
# tree, not a checkout, and must not be told to go and create a test .env.
if [[ "$(readlink -f -- "$SRC/../payload" 2>/dev/null)" == "$SRC" ]] \
   || { [[ "${SRC##*/}" == payload-* ]] && [[ -L "$SRC/../payload" ]]; }
then KIND=deployed
else KIND=dev
fi

D="${DESTDIR:-}"
CPKGDIR="$D/usr/share/cockpit/$PAGE_NAME"
LIBEXECDIR_D="$D$LIBEXECDIR"
ETCDIR="$D/etc/$PROJECT"
INSTALL_CONF="$ETCDIR/install.conf"
UNITDIR_D="$D$UNITDIR"

if [[ "$KIND" == deployed && "$(basename -- "$SRC")" == payload* ]]; then
    ROOT="$(dirname -- "$SRC")"
else
    ROOT="$SRC"
fi
ROOT_REAL="$(readlink -f -- "$ROOT")"
ENV_FILE="$ROOT/.env"
VERSION="$( [[ -f "$SRC/VERSION" ]] && cat "$SRC/VERSION" || echo "1.1.1" )"
LEGACY_DEFAULT="$D/etc/default/edy-rdp"

WITH_UNITS=0
ACTION=install
RC=0
say()  { printf '  %-12s %s\n' "$1" "$2"; }
ok()   { printf '  ok   %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*" >&2; }
fail() { printf '  FAIL %s\n' "$*"; RC=1; }
die()  { printf 'FATAL %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --uninstall)  ACTION=uninstall; shift ;;
    --verify)     ACTION=verify; shift ;;
    --with-units) WITH_UNITS=1; shift ;;
    -h|--help)    sed -n '2,27p' "$SELF" | sed 's/^# \?//'; exit 0 ;;
    *)            die "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# removal primitives (DEPLOY-CONTRACT section 2.4)
#
# This installer used to run `rm -rf -- "$CTARGET"` and `rm -rf "$LIBEXEC"`.
# That is correct only while those are real directories - which is exactly the
# assumption this contract changes. With the symlink model, one trailing slash
# on `rm -rf /usr/share/cockpit/guac-rdp/` follows the link and deletes the
# checkout. So: no rm -r, no find -delete, no rsync --delete anywhere under
# /usr/share/cockpit, /usr/local/sbin, /usr/libexec, /etc or /var. Removal is
# per declared entry, which also means it cannot touch what another project put
# there.
# ---------------------------------------------------------------------------
remove_link() {
    local p=$1
    if [[ -L "$p" ]]; then rm -f -- "$p"; say unlinked "$p"
    elif [[ -e "$p" ]]; then warn "$p is not a symlink - left in place"; fi
}
remove_file() {
    local p=$1
    [[ -e "$p" || -L "$p" ]] || return 0
    [[ -d "$p" && ! -L "$p" ]] && { warn "$p is a directory - left in place"; return 0; }
    rm -f -- "$p"; say removed "$p"
}
remove_dir_if_empty() {
    local p=$1
    [[ -d "$p" && ! -L "$p" ]] || return 0
    rmdir -- "$p" 2>/dev/null && say removed "empty $p" \
        || say kept "$p (not empty - something else lives there)"
}

owned_by_us() {
    local link=$1 cur
    [[ -e "$link" || -L "$link" ]] || return 0
    [[ -L "$link" ]] || { warn "$link exists and is NOT a symlink"; return 1; }
    cur="$(readlink -f -- "$link")" || return 1
    [[ "$cur" == "$ROOT_REAL"/* || "$cur" == "$SRC"/* ]] \
        || { warn "$link -> $cur, which is not under $ROOT_REAL"; return 1; }
    return 0
}

link_one() {
    local target=$1 link=$2
    owned_by_us "$link" || die "refusing to take over $link (warning above).
    Whatever owns it must be uninstalled first, or this project must stop
    claiming that name."
    ln -sfn -- "$target" "$link"
    say linked "$link -> $target"
}

# An asset DIRECTORY must be a real directory holding per-file links, never a
# symlink to a directory. cockpit-ws serves a symlinked FILE inside a package
# but will not serve anything through a symlinked DIRECTORY: the request comes
# back 404 with nothing logged, so the page loads and then dies on the first
# reference to whatever the directory held. Measured on a clean Rocky 9 install,
# every per-file link answered 200 while the one directory link answered
#     404  /cockpit/@localhost/guac-rdp/guacamole-common-js/all.min.js
# and the page threw "ReferenceError: Guacamole is not defined". This is the
# same rule install already applies to $CPKGDIR itself, one level down.
link_dir() {
    local src=$1 dir=$2 base
    if [[ -L "$dir" ]]; then rm -f -- "$dir"; say unlinked "$dir (was a directory symlink)"; fi
    install -d -m 0755 -- "$dir"
    local f
    for f in "$src"/*; do
        [[ -e "$f" ]] || continue
        link_one "$f" "$dir/$(basename -- "$f")"
    done
    # sweep entries that the payload no longer ships
    while IFS= read -r -d '' stale; do
        base="$(basename -- "$stale")"
        [[ -e "$src/$base" ]] || { say sweeping "$base (gone from $src)"; remove_link "$stale"; }
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
}

render_unit_to_stdout() {
    # Two statements, not one. `local n=$1 tpl="$SRC/systemd/$n.in"` expands
    # BOTH assignment words before either binds, so $n is still unset when tpl
    # is built - under `set -u` that aborts, and without it you would silently
    # render the wrong file. ('tpl' rather than 'in' for the second name, too:
    # `in` is a bash reserved word.)
    local n=$1 tpl
    tpl="$SRC/systemd/$n.in"
    [[ -f "$tpl" ]] || tpl="$SRC/systemd/$n"
    [[ -f "$tpl" ]] || { echo "FATAL missing unit template for $n" >&2; return 1; }
    sed -e "s|@PAYLOAD@|$SRC|g" -e "s|@INSTALL_PATH@|$ROOT|g" \
        -e "s|@ENV_FILE@|$ENV_FILE|g" -e "s|@LIBEXEC@|$LIBEXECDIR|g" \
        -e "s|@SBIN@|/usr/local/sbin|g" "$tpl"
}

# @RELAY_UID@ in the nftables owner-match is the ONE placeholder whose value is
# not a path: it is the uid the relay runs as, and the rule that keeps every
# other local uid off guacd's port depends on it being right.
render_sysfile_to_stdout() {
    local src=$1 uid=""
    if [[ -z "$D" ]]; then uid="$(id -u "$RELAY_USER" 2>/dev/null || true)"; fi
    sed -e "s|@RELAY_UID@|${uid:-@RELAY_UID@}|g" -e "s|@LIBEXEC@|$LIBEXECDIR|g" \
        -e "s|@ENV_FILE@|$ENV_FILE|g" "$src"
}

# Placeholders left on DIRECTIVE lines only. A '@WORD@' inside a '#' comment (the
# @DEFAULT_MONITOR@ pulse note in the guacd unit) is documentation. ALWAYS exits 0:
# under `set -Eeuo pipefail` a `grep -o` that matches nothing - the SUCCESS case -
# returns 1, and `x="$(... | grep -o ...)"` then aborts the script with no message.
# That is exactly how every install and --verify died silently after "ok 3b." from
# 1.3.0 to 1.3.2 (KNOWN_ISSUES I41). `|| true` is load-bearing here.
leftover_placeholders() {   # $1 = file, or '-' for stdin; prints "@A@ @B@ " or nothing
    grep -v '^[[:space:]]*#' -- "${1:--}" | grep -o '@[A-Z_]\+@' | sort -u | tr '\n' ' ' || true
}

libexec_src()  { printf '%s\n' "$SRC/${1%%:*}"; }
libexec_name() { printf '%s\n' "${1#*:}"; }

# ---------------------------------------------------------------------------
# the completeness gate (DEPLOY-CONTRACT section 7.2)
# ---------------------------------------------------------------------------
preflight() {
    printf 'pre-flight (%s payload at %s)\n' "$KIND" "$SRC"
    local f miss=()

    for f in "${PAGE[@]}";      do [[ -f "$SRC/$f" ]] || miss+=("$f"); done
    for f in "${PAGE_DIRS[@]}"; do [[ -d "$SRC/$f" ]] || miss+=("$f/"); done
    for f in "${LIBEXEC[@]}";   do [[ -f "$(libexec_src "$f")" ]] || miss+=("${f%%:*}"); done
    for f in "${LIBS[@]}";      do [[ -f "$(libexec_src "$f")" ]] || miss+=("${f%%:*}"); done
    for f in "${UNITS[@]}"; do
        [[ -f "$SRC/systemd/$f.in" || -f "$SRC/systemd/$f" ]] || miss+=("systemd/$f")
    done
    for f in "${SYSFILES[@]}";  do [[ -f "$SRC/${f%%:*}" ]] || miss+=("${f%%:*}"); done
    for f in "$ENVDEFAULT" "$REQUIRES" "$REQUIREMENTS"; do [[ -f "$SRC/$f" ]] || miss+=("$f"); done
    ((${#miss[@]}==0)) || die "declared but missing from $SRC: ${miss[*]}
    Nothing was changed."
    ok "1. every declared file is present (${#LIBEXEC[@]} libexec, ${#LIBS[@]} libs, ${#UNITS[@]} units, ${#SYSFILES[@]} system files)"

    # 2. the page asks only for what is shipped. Parsed, not grepped.
    local refs r bad=()
    refs="$(python3 - "$SRC/index.html" <<'PY'
import html.parser, sys
class P(html.parser.HTMLParser):
    def __init__(self): super().__init__(); self.refs=[]
    def handle_starttag(self, tag, attrs):
        for k, v in attrs:
            if k in ("src", "href", "data") and v:
                self.refs.append(v)
p = P(); p.feed(open(sys.argv[1], encoding="utf-8").read())
for r in p.refs:
    r = r.split("?")[0].split("#")[0]
    if not r or "://" in r or r.startswith(("/", "../", "data:", "mailto:")):
        continue
    print(r)
PY
)" || die "could not parse index.html"
    while read -r r; do
        [[ -z "$r" ]] && continue
        printf '%s\n' "${PAGE[@]}" | grep -qxF -- "$r" && continue
        # a reference INTO a declared asset directory is satisfied by that dir
        printf '%s\n' "${PAGE_DIRS[@]}" | grep -qxF -- "${r%%/*}" && continue
        bad+=("$r")
    done <<<"$refs"
    ((${#bad[@]}==0)) || die "index.html references files PAGE does not ship: ${bad[*]}
    Add them to PAGE (or to PAGE_DIRS), or stop the page referencing them."
    ok "2. index.html references only what PAGE and PAGE_DIRS ship"

    # 3. every helper the page NAMES is shipped and will be linked.
    local named h
    named="$(grep -oh '/usr/local/sbin/[A-Za-z0-9_.-]\+' "${PAGE[@]/#/$SRC/}" 2>/dev/null \
             | sed 's#.*/##' | sort -u || true)"
    for h in $named; do
        printf '%s\n' "${HELPERS[@]:-}" | grep -qxF -- "$h" \
          || die "a shipped page file calls /usr/local/sbin/$h, which HELPERS does not
    install. Add it to HELPERS, or stop the page calling it."
    done
    ok "3. the page names no undeclared /usr/local/sbin helper"

    # 3b. the same check one level down, for THIS project's real coupling: the
    #     relay and the units reach into /usr/libexec/edy-rdp. This is where
    #     edy-rdp-rotate-rdplogin was found - shipped in the repo, named by a
    #     unit, and installed by nothing.
    local wanted names
    names="$(for f in "${LIBEXEC[@]}" "${LIBS[@]}"; do libexec_name "$f"; done | sort -u)"
    wanted="$(grep -ohE "$LIBEXECDIR/[A-Za-z0-9_.-]+" \
                 "$SRC"/systemd/* "$SRC"/relay/*.py "$SRC"/bridge/* "$SRC"/headless/* \
                 "$SRC"/bootstrap/* "$SRC"/pulse/* "$SRC"/lib/* 2>/dev/null \
              | sed 's#.*/##' | sort -u || true)"
    # units carry @LIBEXEC@ rather than the literal, so render them too
    for f in "${UNITS[@]}"; do
        wanted+=$'\n'"$(render_unit_to_stdout "$f" | grep -ohE "$LIBEXECDIR/[A-Za-z0-9_.-]+" | sed 's#.*/##' || true)"
    done
    local w
    for w in $(printf '%s\n' $wanted | sort -u); do
        [[ -z "$w" ]] && continue
        printf '%s\n' "$names" | grep -qxF -- "$w" \
          || die "a unit or a shipped script calls $LIBEXECDIR/$w, which LIBEXEC does not
    install. Add it, or stop calling it. This is the check that caught
    edy-rdp-rotate-rdplogin: a unit and a timer shipped for it, and no installer
    ever put the script on the host."
    done
    ok "3b. every $LIBEXECDIR/<x> a unit or script names is installed"

    # 5. every unit renders clean, and every rendered ExecStart points at
    #    something this install actually produces.
    local out p
    for f in "${UNITS[@]}"; do
        out="$(render_unit_to_stdout "$f")" || exit 1
        local leftover
        leftover="$(leftover_placeholders - <<<"$out")"
        [[ -z "$leftover" ]] || die "unrendered placeholder in $f: $leftover"
        # The program is the first word after the Exec*= prefix flags ('+' runs the
        # bootstrap as root, '-' tolerates failure). systemd will not take a variable
        # as the program, so the python units exec '/usr/bin/env ${EDY_RDP_PYTHON}
        # <script>': skip that prefix or the relay and reaper silently drop out of
        # this check. `|| true`: the no-match case is not an error here either.
        while read -r p; do
            [[ -z "$p" ]] && continue
            case "$p" in
              "$LIBEXECDIR"/*)
                 printf '%s\n' "$names" | grep -qxF -- "${p##*/}" \
                   || die "$f: ExecStart=$p is not something LIBEXEC installs" ;;
            esac
        done < <(grep -oE '^Exec[A-Za-z]*=[-+!@:]*(/usr/bin/env +\$\{EDY_RDP_PYTHON\} +)?[^ ]+' <<<"$out" \
                 | sed -E 's/^Exec[A-Za-z]*=[-+!@:]*//; s#^/usr/bin/env +\$\{EDY_RDP_PYTHON\} +##' || true)
    done
    ok "5. every unit renders clean and every ExecStart resolves to a shipped file"

    # 6. .envdefault - the seed every placed .env derives from - must itself pass
    #    the whole gate (grammar, every REQUIRED_ENV key, no secret shape, every
    #    per-key rule), or place_env would ship a file it then refuses. Same lib
    #    the bootstrap runs at every relay start. --staged: the seed's
    #    EDY_RDP_ADMIN_GROUP describes a deploy host, not this one.
    local problems
    if ! problems="$(env_validate "$SRC/$ENVDEFAULT" "$SRC/$ENVDEFAULT" --staged "${REQUIRED_ENV[@]}")"; then
        die "$SRC/$ENVDEFAULT does not validate:
$(sed 's/^/    /' <<<"$problems")
    The seed must pass what a placed .env must pass."
    fi
    ok "6. $ENVDEFAULT parses, validates and defines every REQUIRED_ENV key"

    # 7. the host's .env, read-only here. Absent on install is fine: place_env
    #    derives it from .envdefault before anything is linked. Present: the keys
    #    it HAS must be well-formed; required-ness is not asked yet because
    #    reconcile is about to append whatever a new version adds - the Sep-18
    #    deploy died right here, refusing two missing keys it could have added.
    local staged=""
    [[ -n "$D" ]] && staged=--staged
    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ "$ACTION" == install ]]; then ok "7. $ENV_FILE absent - will be placed from $ENVDEFAULT"
        else fail "$ENV_FILE is missing"; fi
    else
        # shellcheck disable=SC2086
        if problems="$(env_validate "$ENV_FILE" "$SRC/$ENVDEFAULT" $staged --present-only)"; then
            ok "7. $ENV_FILE validates (present keys)"
        elif [[ "$ACTION" == install ]]; then
            die ".env does not validate:
$(sed 's/^/    /' <<<"$problems")
  Nothing was changed. Fix $ENV_FILE and re-run."
        else
            while IFS= read -r p; do [[ -n "$p" ]] && fail ".env: $p"; done <<<"$problems"
        fi
    fi
    if [[ "$ACTION" == install && -e "$LEGACY_DEFAULT" ]]; then
        # The migration this version performs, stated where it is noticed.
        warn "$LEGACY_DEFAULT still exists and is NO LONGER READ.
       Its settings now live in $ENV_FILE. Nothing here deletes it - it is your
       file - but two config files where one is ignored is how an operator
       changes a setting that never takes effect. Compare them, then remove it."
    fi

    # 8. prerequisites this installer verifies but does not create
    if [[ "$ACTION" == install && -z "$D" ]]; then
        local prereq_bad=0
        getent group "$RELAY_GROUP" >/dev/null || { fail "group $RELAY_GROUP does not exist"; prereq_bad=1; }
        getent passwd "$RELAY_USER" >/dev/null || { fail "user $RELAY_USER does not exist"; prereq_bad=1; }
        ((prereq_bad)) && die "the relay's dedicated user/group are missing. install.sh does
    not create them: creating a system account changes the host, which is
    deploy.sh's job. Run:
        sudo ./deploy.sh --with-users            (or, by hand:)
        groupadd --system $RELAY_GROUP
        useradd --system --no-create-home --shell /usr/sbin/nologin -g $RELAY_GROUP $RELAY_USER"
        ok "8. $RELAY_USER:$RELAY_GROUP exist (uid $(id -u "$RELAY_USER"))"

        # 8b. the OS prerequisites, from the one list (requires.txt), presence and
        #     minimum version. REPORT ONLY, never die: a dev install on a box that
        #     lacks x11vnc must still link, and the relay's bootstrap is where a
        #     missing prerequisite actually stops something.
        req_load "$SRC/$REQUIRES" || die "cannot parse $REQUIRES"
        if req_check; then
            ok "8b. $REQUIRES: all ${#REQ_NAMES[@]} prerequisites present at or above minimum"
        else
            warn "prerequisites missing or below minimum (above). The relay's bootstrap refuses to
       start until they exist. Fix: $(req_fix_command "${REQ_MISSING[@]}" "${REQ_OUTDATED[@]}")
       (or: sudo ./deploy.sh --with-deps)"
        fi
    fi

    # 9. no retired path, and no dev root, in anything being shipped.
    # $SELF is scanned too. It carries no full dev-root literal: DEV_ROOT is
    # assembled from parts precisely so this audit can include its own scanner.
    local shipped=("${PAGE[@]/#/$SRC/}" "$SRC/$ENVDEFAULT" "$SRC/$REQUIRES" "$SRC/$REQUIREMENTS"
                   "$SRC"/systemd/* "$SRC"/hardening/* "$SELF")
    for f in "${LIBEXEC[@]}" "${LIBS[@]}"; do shipped+=("$(libexec_src "$f")"); done
    if grep -RIn -e "$RETIRED_ROOT" -e "$DEV_ROOT" -- "${shipped[@]}" 2>/dev/null; then
        die "a shipped file hardcodes a retired or development path (above).
    It belongs in .env."
    fi
    ok "9. no shipped file names the retired root or the dev root"
}

# ---------------------------------------------------------------------------
dev_install_notice() {
    # A regular file where a link belongs is not ours at all - a hand copy
    # (edt1 had one, plus ~45 .bak files: KNOWN_ISSUES I43). readlink -f on it
    # returns its own path, and the layout test below then called it "a checkout
    # at /usr/share/cockpit/guac-rdp". Say what it is instead.
    if [[ -e "$CPKGDIR/index.html" && ! -L "$CPKGDIR/index.html" ]]; then
        printf '\n  NOTE: %s/index.html is NOT a symlink (hand-copied?). This installer only ever\n        links; a regular file here is not ours and blocks owned_by_us. See docs/KNOWN_ISSUES.md I43.\n\n' "$CPKGDIR"
        return 0
    fi
    # Ask the LINK TARGET's layout, not this script's: an operator may be
    # running the deployed installer to tear down links a dev install made.
    local t
    t="$(readlink -f -- "$CPKGDIR/index.html" 2>/dev/null || true)"
    [[ -n "$t" ]] \
      && [[ "$(readlink -f -- "${t%/*}/../payload" 2>/dev/null)" != "${t%/*}" ]] && cat <<EOF

  NOTE: this is a DEV install. $CPKGDIR/index.html resolves into a checkout at
        ${t%/*}
        Only symlinks are removed; THE CHECKOUT IS NOT TOUCHED.

EOF
    return 0
}

do_verify() {
    printf 'verify (writes nothing)\n'
    preflight
    printf 'installed state\n'
    local f t n
    for f in "${PAGE[@]}"; do
        if   [[ ! -L "$CPKGDIR/$f" ]]; then fail "$CPKGDIR/$f is not a symlink"
        elif ! t="$(readlink -f -- "$CPKGDIR/$f")" || [[ ! -e "$t" ]]; then
             fail "$CPKGDIR/$f DANGLES"
        else ok "$CPKGDIR/$f -> $t"; fi
    done
    for f in "${PAGE_DIRS[@]}"; do
        if   [[ -L "$CPKGDIR/$f" ]]; then fail "$CPKGDIR/$f is a directory SYMLINK (cockpit will 404 through it)"
        elif [[ ! -d "$CPKGDIR/$f" ]]; then fail "$CPKGDIR/$f is not a directory"
        else ok "$CPKGDIR/$f is a real directory of $(find "$CPKGDIR/$f" -mindepth 1 -maxdepth 1 | wc -l) link(s)"; fi
    done
    for f in "${LIBEXEC[@]}" "${LIBS[@]}"; do
        n="$(libexec_name "$f")"
        [[ -L "$LIBEXECDIR_D/$n" ]] && ok "$LIBEXECDIR_D/$n -> $(readlink -f -- "$LIBEXECDIR_D/$n")" \
                                    || fail "$LIBEXECDIR_D/$n is not a symlink"
    done
    for f in "${UNITS[@]}"; do
        [[ -f "$UNITDIR_D/$f" ]] && ok "$UNITDIR_D/$f present" || { fail "$UNITDIR_D/$f is missing"; continue; }
        [[ -z "$(leftover_placeholders "$UNITDIR_D/$f")" ]] || fail "$UNITDIR_D/$f has an unsubstituted placeholder"
    done
    for f in "${SYSFILES[@]}"; do
        [[ -f "$D${f#*:}" ]] && ok "$D${f#*:} present" || fail "$D${f#*:} is missing"
    done
    [[ -f "$INSTALL_CONF" ]] && ok "$INSTALL_CONF present" || fail "$INSTALL_CONF is missing"
    [[ -f "$ENV_FILE" ]] && ok "$ENV_FILE present" || fail "$ENV_FILE is missing"
    verify_host_state
    dev_install_notice
    [[ $RC -eq 0 ]] && printf 'verify: PASS\n' || printf 'verify: FAIL\n'
    return $RC
}

# The checks that ask the HOST, not the tree: does what is RUNNING match what is
# CONFIGURED. Each says 'skipped' with the reason when it cannot know (staged,
# not root, unit not active) rather than reporting a FAIL it did not observe -
# a --verify run unprivileged must stay honest and stay green.
verify_host_state() {
    printf 'host state\n'
    local problems p want running seat uid sock n ve py sha
    # 1. the .env, the whole gate this time (check 7 asked only about present keys)
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC2086
        if problems="$(env_validate "$ENV_FILE" "$SRC/$ENVDEFAULT" ${D:+--staged} "${REQUIRED_ENV[@]}")"; then
            ok ".env validates with every REQUIRED_ENV key"
        else
            while IFS= read -r p; do [[ -n "$p" ]] && fail ".env: $p"; done <<<"$problems"
        fi
    fi
    # 2. the running guacd image is the configured one (a hand-switched .env with
    #    a container started before the switch is exactly the drift this catches)
    if   [[ -n "$D" ]];      then say skipped "running guacd image (staged)"
    elif [[ $EUID -ne 0 ]];  then say skipped "running guacd image (needs root)"
    elif ! systemctl is-active -q edy-rdp-guacd.service 2>/dev/null; then
         say skipped "running guacd image (edy-rdp-guacd.service not active)"
    else
        running="$(podman inspect edy-rdp-guacd --format '{{.ImageName}}' 2>/dev/null || true)"
        want="$(env_get "$ENV_FILE" GUACD_IMAGE 2>/dev/null || true)"
        if [[ -n "$want" && "$running" == "$want" ]]; then ok "running guacd image matches GUACD_IMAGE ($want)"
        else fail "running guacd image is '$running', GUACD_IMAGE is '$want' (systemctl restart edy-rdp-guacd.service)"; fi
    fi
    # 3. the patched gnome-remote-desktop must survive apt (patches/README.md):
    #    held, and different from the stock backup the patch procedure leaves.
    if [[ -z "$D" ]]; then
        if ! command -v apt-mark >/dev/null 2>&1; then
            say skipped "gnome-remote-desktop hold (no apt-mark on this host)"
        elif apt-mark showhold 2>/dev/null | grep -qx gnome-remote-desktop; then
            ok "gnome-remote-desktop is apt-mark held"
        else
            fail "gnome-remote-desktop is NOT apt-mark held - an upgrade will clobber the patched daemon (see patches/README.md)"
        fi
        local daemon=/usr/libexec/gnome-remote-desktop-daemon
        if [[ ! -e "$daemon.orig-edt1" ]]; then
            say skipped "gnome-remote-desktop patch state (no .orig-edt1 stock backup on this host)"
        elif cmp -s "$daemon" "$daemon.orig-edt1"; then
            fail "gnome-remote-desktop daemon is STOCK - 3390 greeter will fail; see patches/README.md"
        else
            ok "gnome-remote-desktop daemon is patched (differs from .orig-edt1 stock backup)"
        fi
    fi
    # 4. the audio bind: once the seat socket exists it must be bound into the
    #    SHARED dir the container mounts, or audio is dead until a restart (I42)
    if [[ -z "$D" ]]; then
        uid="$(env_get "$ENV_FILE" EDY_RDP_PULSE_SEAT_UID 2>/dev/null || true)"
        sock="$(env_get "$ENV_FILE" EDY_RDP_PULSE_SEAT_SOCKET 2>/dev/null || true)"
        seat="${EDY_RDP_PULSE_SEAT_SOCKET:-${sock:-/run/user/${uid:-1000}/pulse/native}}"
        if [[ ! -S "$seat" ]]; then
            say skipped "pulse bind (seat socket $seat absent - no seat login)"
        elif ! findmnt -no PROPAGATION /run/edy-rdp-pulse 2>/dev/null | grep -q shared; then
            fail "/run/edy-rdp-pulse is not a SHARED mountpoint (a later bind cannot reach the container; run edy-rdp-pulse-bind)"
        elif mountpoint -q /run/edy-rdp-pulse/native 2>/dev/null; then
            ok "/run/edy-rdp-pulse/native is a mountpoint (seat socket bound)"
        else
            fail "/run/edy-rdp-pulse/native is not a mountpoint while the seat socket exists (run /usr/libexec/edy-rdp/edy-rdp-pulse-bind, or check edy-rdp-pulse-seat@<uid>.path)"
        fi
    fi
    # 5. venv.env agrees with requirements.txt (the bootstrap rewrites it at
    #    every relay start; a mismatch here means the relay has not restarted
    #    since requirements.txt changed, or the bootstrap failed - see the journal)
    if [[ -n "$D" ]]; then
        say skipped "venv.env (staged)"
    else
        n="$(req_pip_count "$SRC/$REQUIREMENTS")"; ve="$ROOT/venv.env"
        sha="$(req_sha256 "$SRC/$REQUIREMENTS")"
        if [[ ! -f "$ve" ]]; then
            # "the relay is running" only means something when the running relay
            # is THIS install: a checkout verified beside a deployed host must not
            # report the deployed relay's venv.env as its own missing file.
            local ip; ip="$(env_get "$INSTALL_CONF" INSTALL_PATH 2>/dev/null || true)"
            if [[ -n "$ip" && "$ip" != "$ROOT" ]]; then
                say skipped "venv.env (the running relay is another install, at $ip)"
            elif systemctl is-active -q edy-rdp-relay.service 2>/dev/null; then
                fail "$ve is missing although the relay is running (edy-rdp-bootstrap should have written it)"
            else
                say skipped "venv.env (edy-rdp-bootstrap has not run yet; it runs at relay start)"
            fi
        else
            py="$(env_get "$ve" EDY_RDP_PYTHON 2>/dev/null || true)"
            if (( n == 0 )); then
                [[ "$py" == /usr/bin/python3 ]] && ok "venv.env: EDY_RDP_PYTHON=/usr/bin/python3 ($REQUIREMENTS is empty)" \
                    || fail "venv.env points at $py but $REQUIREMENTS is empty (stale; the bootstrap rewrites it at relay start)"
            elif [[ "$py" == "$ROOT/venv/bin/python3" && -x "$py" \
                    && "$(cat "$ROOT/venv/.requirements.sha" 2>/dev/null)" == "$sha" ]]; then
                ok "venv.env: venv current (requirements sha ${sha:0:8})"
            else
                fail "venv.env/venv is stale for $REQUIREMENTS (sha ${sha:0:8}); the bootstrap rebuilds it at relay start"
            fi
        fi
    fi
    # 6. the OS prerequisites, from the one list: presence AND minimum version,
    #    one line per tool. Check 8b does this on a live install; --verify is
    #    "the per-host report" (docs/COMPATIBILITY.md) and until 1.4.0 it said
    #    nothing about them at all. Needs no root. Staged: a DESTDIR describes
    #    some other machine, so its host is not asked.
    if [[ -n "$D" ]]; then
        say skipped "prerequisites (staged)"
    elif ! req_load "$SRC/$REQUIRES"; then
        fail "cannot parse $REQUIRES (above)"
    elif req_check; then
        ok "$REQUIRES: all ${#REQ_NAMES[@]} prerequisites present at or above minimum"
    else
        fail "prerequisites missing or below minimum: ${REQ_MISSING[*]} ${REQ_OUTDATED[*]} - the relay's bootstrap refuses to start. Fix: $(req_fix_command "${REQ_MISSING[@]}" "${REQ_OUTDATED[@]}")"
    fi
}

do_uninstall() {
    dev_install_notice
    local f n
    if [[ -z "$D" ]]; then
        # Sockets before their service, or systemd starts the service again on
        # the next connection. Template units need their INSTANCES stopped.
        systemctl stop 'edy-rdp-headless@*' 2>/dev/null || true
        systemctl stop 'edy-rdp-pulse-seat@*' 2>/dev/null || true
        systemctl stop 'edy-rdp-pulse-rebind@*' 2>/dev/null || true
        for f in edy-rdp-relay.socket edy-rdp-control.socket "${UNITS[@]}"; do
            systemctl stop    "$f" 2>/dev/null || true
            systemctl disable "$f" 2>/dev/null || true
        done
    fi
    for f in "${UNITS[@]}"; do remove_file "$UNITDIR_D/$f"; done
    if [[ -z "$D" ]]; then
        systemctl daemon-reload || true
        systemctl reset-failed 2>/dev/null || true   # else a removed unit lingers as failed
    fi
    for f in "${SYSFILES[@]}"; do remove_file "$D${f#*:}"; done
    for f in "${LIBEXEC[@]}" "${LIBS[@]}"; do n="$(libexec_name "$f")"; remove_link "$LIBEXECDIR_D/$n"; done
    # A __pycache__ left by a version that ran before PYTHONDONTWRITEBYTECODE.
    # Swept file by file and then rmdir'd - NOT `rm -r`, which is banned under
    # every one of these trees, and which here would be one typo away from
    # following a symlink into the payload.
    if [[ -d "$LIBEXECDIR_D/__pycache__" && ! -L "$LIBEXECDIR_D/__pycache__" ]]; then
        find "$LIBEXECDIR_D/__pycache__" -maxdepth 1 -type f -name '*.pyc' \
             -exec rm -f -- {} + 2>/dev/null || true
        rmdir -- "$LIBEXECDIR_D/__pycache__" 2>/dev/null \
            && say removed "$LIBEXECDIR_D/__pycache__ (stale bytecode cache)"
    fi
    remove_dir_if_empty "$LIBEXECDIR_D"
    for f in "${PAGE[@]}"; do remove_link "$CPKGDIR/$f"; done
    for f in "${PAGE_DIRS[@]}"; do
        # a real directory of links: empty it, then drop the directory itself
        if [[ -d "$CPKGDIR/$f" && ! -L "$CPKGDIR/$f" ]]; then
            while IFS= read -r -d '' e; do remove_link "$e"; done \
                < <(find "$CPKGDIR/$f" -mindepth 1 -maxdepth 1 -print0)
            remove_dir_if_empty "$CPKGDIR/$f"
        else
            remove_link "$CPKGDIR/$f"
        fi
    done
    remove_dir_if_empty "$CPKGDIR"
    remove_file "$INSTALL_CONF"
    remove_dir_if_empty "$ETCDIR"
    cat <<EOF

  KEPT, deliberately - uninstall removes software, never data or host identity:
    $ENV_FILE                 (your configuration)
    the $RELAY_GROUP group and the $RELAY_USER user  (uids outlive packages; a
      reused uid is a permission that silently belongs to somebody else)
    /run/edy-rdp                             (tmpfs; gone at reboot)
    /run/edy-rdp-pulse                       (tmpfs; a seat socket bind, gone at reboot)
    $ROOT/venv and $ROOT/venv.env            (the bootstrap's; only it removes them)
    the payload at $SRC
  cockpit.socket was NOT touched.

  NOT reverted here, because this installer never did them: the OS packages, the
  guacd image, the gnome-remote-desktop greeter patch and its apt hold, and the
  3390 door credential. See deploy.sh --remove and docs/KNOWN_ISSUES.md (I29).
EOF
}

# The configuration, BEFORE anything is linked: a missing .env is derived from
# .envdefault; a present one gains only the keys this version ships and it
# lacks, values untouched; then the whole gate runs and a bad value refuses
# the install naming the key. deploy.sh used to byte-copy the seed missing-only
# and could not add a key to an operator's file - so an upgrade that added a key
# died in check 7 until someone edited by hand (the Sep-18 deploy). --verify
# never comes through here: it validates and writes nothing.
place_env() {
    printf '\nconfiguration\n'
    local r problems
    r="$(env_place "$SRC/$ENVDEFAULT" "$ENV_FILE" "$VERSION")" || die "could not place $ENV_FILE"
    say "$( [[ $r == placed* ]] && echo placed || echo reconciled )" "$ENV_FILE ($r)"
    # shellcheck disable=SC2086
    if ! problems="$(env_validate "$ENV_FILE" "$SRC/$ENVDEFAULT" ${D:+--staged} "${REQUIRED_ENV[@]}")"; then
        die "$ENV_FILE does not validate (fail closed; nothing was linked):
$(sed 's/^/    /' <<<"$problems")
    Fix the named key(s) in $ENV_FILE and re-run."
    fi
    ok "$ENV_FILE validates ($(env_keys "$ENV_FILE" | wc -l) keys)"
}

do_install() {
    preflight
    place_env
    printf '\ninstall (%s)\n' "$KIND"

    install -d -m 0755 -- "$CPKGDIR"
    [[ -L "$CPKGDIR" ]] && die "$CPKGDIR is a symlink. /usr/share/cockpit/<name> is a
    WEB ROOT and must be a real directory of per-file links."
    local f n
    for f in "${PAGE[@]}";      do link_one "$SRC/$f" "$CPKGDIR/$f"; done
    for f in "${PAGE_DIRS[@]}"; do link_dir  "$SRC/$f" "$CPKGDIR/$f"; done

    local base keep stale
    while IFS= read -r -d '' stale; do
        base="$(basename -- "$stale")"; keep=0
        for f in "${PAGE[@]}" "${PAGE_DIRS[@]}"; do [[ "$base" == "$f" ]] && { keep=1; break; }; done
        ((keep)) || { say sweeping "$base (not in PAGE/PAGE_DIRS)"; remove_link "$stale"; }
    done < <(find "$CPKGDIR" -mindepth 1 -maxdepth 1 -print0)

    # libexec: per-file symlinks into the payload. Verified, not assumed: Python
    # resolves a symlinked script for sys.path[0], so edy_rdp_relay.py linked
    # here still imports session_registry/control/bridge out of the payload.
    install -d -m 0755 -- "$LIBEXECDIR_D"
    # LIBS ride along: the scripts source them by the SAME directory, so a
    # deployed host and a checkout resolve `$LIBEXECDIR/edy-rdp-env.sh` alike.
    for f in "${LIBEXEC[@]}" "${LIBS[@]}"; do
        n="$(libexec_name "$f")"
        link_one "$(libexec_src "$f")" "$LIBEXECDIR_D/$n"
    done

    # system files: copied and rendered. Not linked - systemd-tmpfiles, dbus,
    # polkit and nft read their own directories under policies that do not all
    # follow a link out of them.
    for f in "${SYSFILES[@]}"; do
        local dst="$D${f#*:}"
        install -d -m 0755 -- "$(dirname -- "$dst")"
        render_sysfile_to_stdout "$SRC/${f%%:*}" > "$dst.new"
        if [[ -n "$(leftover_placeholders "$dst.new")" ]]; then
            if [[ -n "$D" ]]; then
                say staged "$dst (placeholders left: no live $RELAY_USER while staging)"
            else
                rm -f "$dst.new"; die "unrendered placeholder in ${f%%:*}"
            fi
        fi
        chmod 0644 "$dst.new"; mv -f -- "$dst.new" "$dst"; say installed "$dst"
    done

    # units: rendered and PLACED. Never enabled, started, stopped or disabled.
    if [[ "$KIND" == dev && $WITH_UNITS -eq 0 ]]; then
        say skipped "units (dev install; --with-units places them anyway, still not enabled)"
    else
        install -d -m 0755 -- "$UNITDIR_D"
        for f in "${UNITS[@]}"; do
            render_unit_to_stdout "$f" > "$UNITDIR_D/$f.new"
            [[ -z "$(leftover_placeholders "$UNITDIR_D/$f.new")" ]] || { rm -f "$UNITDIR_D/$f.new"
                die "unrendered placeholder in $f"; }
            chmod 0644 "$UNITDIR_D/$f.new"
            mv -f -- "$UNITDIR_D/$f.new" "$UNITDIR_D/$f"; say rendered "$UNITDIR_D/$f"
        done
        [[ -z "$D" ]] && systemctl daemon-reload
    fi

    install -d -m 0755 -- "$ETCDIR"
    cat > "$INSTALL_CONF.new" <<EOF
# Written by install.sh. Do not edit; re-run install.sh instead.
INSTALL_KIND=$KIND
INSTALL_PATH=$ROOT
PAYLOAD=$SRC
ENV_FILE=$ENV_FILE
UNITDIR=$UNITDIR
LIBEXECDIR=$LIBEXECDIR
REQUIRED_ENV=${REQUIRED_ENV[*]}
ENVDEFAULT=$SRC/$ENVDEFAULT
REQUIRES=$SRC/$REQUIRES
REQUIREMENTS=$SRC/$REQUIREMENTS
WHEELS=$SRC/wheels
VERSION=$VERSION
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INSTALLED_BY=install.sh
EOF
    chmod 0644 "$INSTALL_CONF.new"; mv -f -- "$INSTALL_CONF.new" "$INSTALL_CONF"
    say wrote "$INSTALL_CONF ($KIND)"

    printf '\npost-install assertion\n'
    local t
    for f in "${PAGE[@]}"; do
        [[ -L "$CPKGDIR/$f" ]] || die "post-install: $CPKGDIR/$f is not a symlink"
        t="$(readlink -f -- "$CPKGDIR/$f")"
        [[ -e "$t" && "$t" == "$SRC"/* ]] || die "post-install: $CPKGDIR/$f -> $t"
    done
    for f in "${PAGE_DIRS[@]}"; do
        [[ -L "$CPKGDIR/$f" ]] && die "post-install: $CPKGDIR/$f is a directory symlink.
    cockpit-ws returns 404 for every file requested through one."
        [[ -d "$CPKGDIR/$f" ]] || die "post-install: $CPKGDIR/$f is not a directory"
        local e n_e=0
        while IFS= read -r -d '' e; do
            t="$(readlink -f -- "$e")"
            [[ -e "$t" && "$t" == "$SRC"/* ]] || die "post-install: $e -> $t"
            n_e=$((n_e+1))
        done < <(find "$CPKGDIR/$f" -mindepth 1 -maxdepth 1 -print0)
        (( n_e > 0 )) || die "post-install: $CPKGDIR/$f is empty"
    done
    ok "${#PAGE[@]} page links + ${#PAGE_DIRS[@]} asset dir(s) resolve inside $SRC"
    for f in "${LIBEXEC[@]}"; do
        n="$(libexec_name "$f")"; t="$(readlink -f -- "$LIBEXECDIR_D/$n")"
        [[ -e "$t" ]] || die "post-install: $LIBEXECDIR_D/$n dangles"
        case "$n" in
          *.py|edy-rdp-*) [[ "$n" == session_registry.py || "$n" == control.py \
                             || "$n" == bridge.py || "$n" == selfupdate.py ]] \
                          || [[ -x "$t" ]] || die "post-install: $t is not executable" ;;
        esac
    done
    ok "every libexec link resolves, and every entry point is executable"
    for f in "${LIBS[@]}"; do
        n="$(libexec_name "$f")"; t="$(readlink -f -- "$LIBEXECDIR_D/$n")"
        [[ -e "$t" ]] || die "post-install: $LIBEXECDIR_D/$n dangles"
    done
    ok "every lib link resolves (sourced, not executed: no exec bit asked)"
    [[ "$(sed -n 's/^PAYLOAD=//p' "$INSTALL_CONF")" == "$SRC" ]] \
        || die "post-install: install.conf PAYLOAD does not match $SRC"
    ok "install.conf PAYLOAD resolves to the payload we linked"

    cat <<EOF

installed ($KIND). NOTHING WAS ENABLED OR STARTED - that is deploy.sh's job.

  which install is this?   readlink -f $CPKGDIR/index.html
  bring it up:             sudo ./deploy.sh --with-units    (or, unit by unit,
                           systemctl enable --now edy-rdp-firewall.service
                                                  edy-rdp-guacd.service
                                                  edy-rdp-relay.socket
                                                  edy-rdp-control.socket
                                                  edy-rdp-reaper.timer)
  who may use it:          usermod -aG $RELAY_GROUP <user>  (docs/GROUP-ACCESS-MODEL.md -
                           who that actually admits, and what console/remote/vnc need
                           on top of it)
  cockpit.socket was NOT touched. Reload the browser (Ctrl-Shift-R for the menu).
EOF
    [[ "$KIND" == dev ]] && cat <<EOF
  This is a DEV install: Cockpit is serving the checkout, and units were skipped
  unless you passed --with-units. Two relays on one host fight over one socket.
EOF
    return 0
}

[[ "$ACTION" == verify || -n "$D" || $EUID -eq 0 ]] || die "run as root, or stage with
DESTDIR=. Nothing was changed."

case "$ACTION" in
    verify)    do_verify ;;
    uninstall) do_uninstall ;;
    install)   do_install ;;
esac
