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
#   It does not install OS packages, create the edy-rdp group or the edy-relay
#   user, pull the guacd image, or enable/start/stop a single unit. All of that
#   changes the RUNNING STATE of a host, and it belongs to deploy.sh - the script
#   that only ever runs on a host being deployed to. install.sh runs in both
#   roles, and a dev install that enables edy-rdp-relay.service would put two
#   relays on one host fighting over one socket and one nftables table.
#   It VERIFIES those prerequisites and refuses with the command that fixes them.
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
         bridge/edy-rdp-bridge-start.sh:edy-rdp-bridge-start
         headless/edy-rdp-headless-start.sh:edy-rdp-headless-start
         headless/edy-rdp-headless-stop.sh:edy-rdp-headless-stop
         waylandvnc/edy-rdp-waylandvnc-start.sh:edy-rdp-waylandvnc-start
         waylandvnc/edy-rdp-waylandvnc-stop.sh:edy-rdp-waylandvnc-stop
         unlock/edy-rdp-unlock.sh:edy-rdp-unlock
         rotate/edy-rdp-rotate-rdplogin.sh:edy-rdp-rotate-rdplogin)
LIBS=()
UNITS=(edy-rdp-guacd.service edy-rdp-relay.socket edy-rdp-control.socket
       edy-rdp-relay.service edy-rdp-reaper.service edy-rdp-reaper.timer
       edy-rdp-headless@.service edy-rdp-firewall.service
       edy-rdp-rotate-rdplogin.service edy-rdp-rotate-rdplogin.timer)
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
REQUIRED_ENV=(EDY_RDP_GUACD EDY_RDP_ADMIN_GROUP EDY_RDP_STATE_FILE
              EDY_RDP_LOG_LEVEL EDY_RDP_ALLOW_ARGS GUACD_IMAGE)
UNITDIR=/etc/systemd/system
LIBEXECDIR=/usr/libexec/edy-rdp
RELAY_USER=edy-relay
RELAY_GROUP=edy-rdp
# END-MANIFEST
# ---------------------------------------------------------------------------

# readlink -f FIRST, then dirname. `dirname "${BASH_SOURCE[0]}"` alone - which is
# what this script used to do - makes an install.sh invoked through a symlink
# resolve its payload relative to the LINK's directory.
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SRC="$(cd -- "$(dirname -- "$SELF")" && pwd)"

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
    for f in "${UNITS[@]}"; do
        [[ -f "$SRC/systemd/$f.in" || -f "$SRC/systemd/$f" ]] || miss+=("systemd/$f")
    done
    for f in "${SYSFILES[@]}";  do [[ -f "$SRC/${f%%:*}" ]] || miss+=("${f%%:*}"); done
    [[ -f "$SRC/$ENVDEFAULT" ]] || miss+=("$ENVDEFAULT")
    ((${#miss[@]}==0)) || die "declared but missing from $SRC: ${miss[*]}
    Nothing was changed."
    ok "1. every declared file is present (${#LIBEXEC[@]} libexec, ${#UNITS[@]} units, ${#SYSFILES[@]} system files)"

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
    names="$(for f in "${LIBEXEC[@]}"; do libexec_name "$f"; done | sort -u)"
    wanted="$(grep -ohE "$LIBEXECDIR/[A-Za-z0-9_.-]+" \
                 "$SRC"/systemd/* "$SRC"/relay/*.py "$SRC"/bridge/* "$SRC"/headless/* 2>/dev/null \
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
        grep -q '@[A-Z_]\+@' <<<"$out" \
            && die "unrendered placeholder in $f: $(grep -o '@[A-Z_]*@' <<<"$out" | sort -u | tr '\n' ' ')"
        while read -r p; do
            [[ -z "$p" ]] && continue
            case "$p" in
              "$LIBEXECDIR"/*)
                 printf '%s\n' "$names" | grep -qxF -- "${p##*/}" \
                   || die "$f: ExecStart=$p is not something LIBEXEC installs" ;;
            esac
        done < <(grep -oE '^Exec[A-Za-z]*=-?[^ ]+' <<<"$out" | sed 's/^Exec[A-Za-z]*=-\?//')
    done
    ok "5. every unit renders clean and every ExecStart resolves to a shipped file"

    # 6. .envdefault parses and defines every REQUIRED_ENV key
    python3 - "$SRC/$ENVDEFAULT" "${REQUIRED_ENV[@]}" <<'PY' || exit 1
import re, sys
path, required = sys.argv[1], sys.argv[2:]
seen = {}
for n, raw in enumerate(open(path, encoding="utf-8"), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        sys.exit("FATAL %s:%d: not KEY=VALUE" % (path, n))
    k, v = (x.strip() for x in line.split("=", 1))
    if not re.match(r"^[A-Z][A-Z0-9_]*$", k):
        sys.exit("FATAL %s:%d: bad key %r" % (path, n, k))
    if len(v) >= 2 and v[0] == v[-1] == '"':
        v = v[1:-1]
    if "$" in v or "`" in v:
        sys.exit("FATAL %s:%d: %s contains $ or ` - no interpolation "
                 "(DEPLOY-CONTRACT 4.1)" % (path, n, k))
    seen[k] = v
missing = [k for k in required if k not in seen]
if missing:
    sys.exit("FATAL %s does not define: %s" % (path, " ".join(missing)))
PY
    ok "6. $ENVDEFAULT parses and defines every REQUIRED_ENV key"

    # 7. on install: .env exists and sets every REQUIRED_ENV key
    if [[ "$ACTION" == install ]]; then
        [[ -f "$ENV_FILE" ]] || die "$ENV_FILE does not exist.
    Run deploy.sh first, or create it from $SRC/$ENVDEFAULT. install.sh never
    writes .env - seeding is deploy.sh's job, and missing-only."
        local k v missing_k=()
        for k in "${REQUIRED_ENV[@]}"; do
            v="$(sed -n "s/^${k}=//p" "$ENV_FILE" | tail -1 | sed 's/^"//; s/"$//')"
            [[ -n "$v" ]] || missing_k+=("$k")
        done
        ((${#missing_k[@]}==0)) || die "$ENV_FILE does not set: ${missing_k[*]}
    Copy them from $SRC/$ENVDEFAULT. deploy.sh seeds missing-only and cannot add
    a key to a file you already own."
        ok "7. $ENV_FILE sets every REQUIRED_ENV key"

        # The migration this version performs, stated where it is noticed.
        if [[ -e "$LEGACY_DEFAULT" ]]; then
            warn "$LEGACY_DEFAULT still exists and is NO LONGER READ.
       Its settings now live in $ENV_FILE. Nothing here deletes it - it is your
       file - but two config files where one is ignored is how an operator
       changes a setting that never takes effect. Compare them, then remove it."
        fi
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
    fi

    # 9. no retired path, and no dev root, in anything being shipped.
    # $SELF is scanned too. It carries no full dev-root literal: DEV_ROOT is
    # assembled from parts precisely so this audit can include its own scanner.
    local shipped=("${PAGE[@]/#/$SRC/}" "$SRC/$ENVDEFAULT" "$SRC"/systemd/* "$SRC"/hardening/* "$SELF")
    for f in "${LIBEXEC[@]}"; do shipped+=("$(libexec_src "$f")"); done
    if grep -RIn -e "$RETIRED_ROOT" -e "$DEV_ROOT" -- "${shipped[@]}" 2>/dev/null; then
        die "a shipped file hardcodes a retired or development path (above).
    It belongs in .env."
    fi
    ok "9. no shipped file names the retired root or the dev root"
}

# ---------------------------------------------------------------------------
dev_install_notice() {
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
    for f in "${PAGE[@]}" "${PAGE_DIRS[@]}"; do
        if   [[ ! -L "$CPKGDIR/$f" ]]; then fail "$CPKGDIR/$f is not a symlink"
        elif ! t="$(readlink -f -- "$CPKGDIR/$f")" || [[ ! -e "$t" ]]; then
             fail "$CPKGDIR/$f DANGLES"
        else ok "$CPKGDIR/$f -> $t"; fi
    done
    for f in "${LIBEXEC[@]}"; do
        n="$(libexec_name "$f")"
        [[ -L "$LIBEXECDIR_D/$n" ]] && ok "$LIBEXECDIR_D/$n -> $(readlink -f -- "$LIBEXECDIR_D/$n")" \
                                    || fail "$LIBEXECDIR_D/$n is not a symlink"
    done
    for f in "${UNITS[@]}"; do
        [[ -f "$UNITDIR_D/$f" ]] && ok "$UNITDIR_D/$f present" || fail "$UNITDIR_D/$f is missing"
        grep -q '@[A-Z_]\+@' "$UNITDIR_D/$f" 2>/dev/null && fail "$UNITDIR_D/$f has an unsubstituted placeholder"
    done
    for f in "${SYSFILES[@]}"; do
        [[ -f "$D${f#*:}" ]] && ok "$D${f#*:} present" || fail "$D${f#*:} is missing"
    done
    [[ -f "$INSTALL_CONF" ]] && ok "$INSTALL_CONF present" || fail "$INSTALL_CONF is missing"
    [[ -f "$ENV_FILE" ]] && ok "$ENV_FILE present" || fail "$ENV_FILE is missing"
    dev_install_notice
    [[ $RC -eq 0 ]] && printf 'verify: PASS\n' || printf 'verify: FAIL\n'
    return $RC
}

do_uninstall() {
    dev_install_notice
    local f n
    if [[ -z "$D" ]]; then
        # Sockets before their service, or systemd starts the service again on
        # the next connection. Template units need their INSTANCES stopped.
        systemctl stop 'edy-rdp-headless@*' 2>/dev/null || true
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
    for f in "${LIBEXEC[@]}"; do n="$(libexec_name "$f")"; remove_link "$LIBEXECDIR_D/$n"; done
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
    for f in "${PAGE[@]}" "${PAGE_DIRS[@]}"; do remove_link "$CPKGDIR/$f"; done
    remove_dir_if_empty "$CPKGDIR"
    remove_file "$INSTALL_CONF"
    remove_dir_if_empty "$ETCDIR"
    cat <<EOF

  KEPT, deliberately - uninstall removes software, never data or host identity:
    $ENV_FILE                 (your configuration)
    the $RELAY_GROUP group and the $RELAY_USER user  (uids outlive packages; a
      reused uid is a permission that silently belongs to somebody else)
    /run/edy-rdp                             (tmpfs; gone at reboot)
    the payload at $SRC
  cockpit.socket was NOT touched.

  NOT reverted here, because this installer never did them: the OS packages, the
  guacd image, the gnome-remote-desktop greeter patch and its apt hold, and the
  3390 door credential. See deploy.sh --remove and docs/KNOWN_ISSUES.md (I29).
EOF
}

do_install() {
    preflight
    printf '\ninstall (%s)\n' "$KIND"

    install -d -m 0755 -- "$CPKGDIR"
    [[ -L "$CPKGDIR" ]] && die "$CPKGDIR is a symlink. /usr/share/cockpit/<name> is a
    WEB ROOT and must be a real directory of per-file links."
    local f n
    for f in "${PAGE[@]}" "${PAGE_DIRS[@]}"; do link_one "$SRC/$f" "$CPKGDIR/$f"; done

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
    for f in "${LIBEXEC[@]}"; do
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
        if grep -q '@[A-Z_]\+@' "$dst.new"; then
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
            grep -q '@[A-Z_]\+@' "$UNITDIR_D/$f.new" && { rm -f "$UNITDIR_D/$f.new"
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
VERSION=$VERSION
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INSTALLED_BY=install.sh
EOF
    chmod 0644 "$INSTALL_CONF.new"; mv -f -- "$INSTALL_CONF.new" "$INSTALL_CONF"
    say wrote "$INSTALL_CONF ($KIND)"

    printf '\npost-install assertion\n'
    local t
    for f in "${PAGE[@]}" "${PAGE_DIRS[@]}"; do
        [[ -L "$CPKGDIR/$f" ]] || die "post-install: $CPKGDIR/$f is not a symlink"
        t="$(readlink -f -- "$CPKGDIR/$f")"
        [[ -e "$t" && "$t" == "$SRC"/* ]] || die "post-install: $CPKGDIR/$f -> $t"
    done
    ok "${#PAGE[@]} page links + ${#PAGE_DIRS[@]} asset dir(s) resolve inside $SRC"
    for f in "${LIBEXEC[@]}"; do
        n="$(libexec_name "$f")"; t="$(readlink -f -- "$LIBEXECDIR_D/$n")"
        [[ -e "$t" ]] || die "post-install: $LIBEXECDIR_D/$n dangles"
        case "$n" in
          *.py|edy-rdp-*) [[ "$n" == session_registry.py || "$n" == control.py || "$n" == bridge.py ]] \
                          || [[ -x "$t" ]] || die "post-install: $t is not executable" ;;
        esac
    done
    ok "every libexec link resolves, and every entry point is executable"
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
  who may use it:          usermod -aG $RELAY_GROUP <user>
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
