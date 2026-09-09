#!/usr/bin/env bash
#
# deploy.sh - the real deployment of cockpit-guac-rdp onto a host.
#
#   ./deploy.sh                       copy -> /opt/cockpit-guac-rdp, seed .env,
#                                     run the installed install.sh. Enables NOTHING.
#   ./deploy.sh --with-users          also create the edy-rdp group + edy-relay user
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

VERSION="$( [[ -f "$SRC/VERSION" ]] && cat "$SRC/VERSION" || echo "1.1.1" )"
ROOT="/opt/$PROJECT"
ACTION=deploy
KEEP=1
WITH_USERS=0; WITH_DEPS=0; WITH_IMAGE=0; WITH_UNITS=0; WITH_ALRD=0; ALRD_USER=""

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
    -h|--help)    sed -n '2,30p' "$SELF" | sed 's/^# \?//'; exit 0 ;;
    *)            die "unknown option: $1" ;;
  esac
done
[[ "$ROOT" == /* ]] || die "--install-to must be an absolute path (got: $ROOT)"

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
# OS prerequisites (--with-deps). Detection is by BINARY presence, so a re-run
# installs nothing new.
# ---------------------------------------------------------------------------
PREREQS=(cockpit podman python3 freerdp3 xvfb x11vnc nftables grd dbus)

detect_pm() { local pm; for pm in apt-get dnf yum pacman zypper; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }; done; echo ""; }

pkg_for() { case "$2:$1" in
    apt-get:cockpit)  echo "cockpit cockpit-system" ;;
    apt-get:freerdp3) echo "freerdp3-x11" ;;
    apt-get:xvfb)     echo "xvfb" ;;
    apt-get:grd)      echo "gnome-remote-desktop" ;;
    apt-get:dbus)     echo "dbus-bin" ;;
    apt-get:*)        echo "$1" ;;
    dnf:cockpit|yum:cockpit)   echo "cockpit cockpit-system" ;;
    dnf:freerdp3|yum:freerdp3) echo "freerdp" ;;
    dnf:xvfb|yum:xvfb)         echo "xorg-x11-server-Xvfb" ;;
    dnf:grd|yum:grd)           echo "gnome-remote-desktop" ;;
    dnf:dbus|yum:dbus)         echo "dbus-tools" ;;
    dnf:*|yum:*)               echo "$1" ;;
    pacman:cockpit)  echo "cockpit" ;;   pacman:freerdp3) echo "freerdp" ;;
    pacman:xvfb)     echo "xorg-server-xvfb" ;;  pacman:python3) echo "python" ;;
    pacman:grd)      echo "gnome-remote-desktop" ;;  pacman:dbus) echo "dbus" ;;
    pacman:*)        echo "$1" ;;
    zypper:cockpit)  echo "cockpit cockpit-bridge" ;;  zypper:freerdp3) echo "freerdp" ;;
    zypper:xvfb)     echo "xorg-x11-server-Xvfb" ;;
    zypper:grd)      echo "gnome-remote-desktop" ;;  zypper:dbus) echo "dbus-1-tools" ;;
    zypper:*)        echo "$1" ;;
    *) echo "$1" ;;
  esac; }

# The FreeRDP3 client is 'xfreerdp3' on Debian/Ubuntu, 'xfreerdp' (v3) elsewhere.
freerdp3_bin() {
  command -v xfreerdp3 >/dev/null 2>&1 && { echo xfreerdp3; return 0; }
  command -v xfreerdp  >/dev/null 2>&1 \
     && xfreerdp /version 2>/dev/null | grep -qE 'version 3\.' && { echo xfreerdp; return 0; }
  return 1
}

have_prereq() { case "$1" in
    cockpit)  command -v cockpit-bridge >/dev/null 2>&1 && [ -d /usr/share/cockpit/system ] ;;
    podman|python3|x11vnc) command -v "$1" >/dev/null 2>&1 ;;
    xvfb)     command -v Xvfb      >/dev/null 2>&1 ;;
    nftables) command -v nft       >/dev/null 2>&1 ;;
    grd)      command -v grdctl    >/dev/null 2>&1 ;;
    dbus)     command -v dbus-send >/dev/null 2>&1 ;;
    freerdp3) freerdp3_bin >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac; }

report_prereqs() {   # always runs; only --with-deps installs
    local p missing=()
    for p in "${PREREQS[@]}"; do have_prereq "$p" || missing+=("$p"); done
    if ((${#missing[@]}==0)); then
        ok "prerequisites: all present (FreeRDP3 client: $(freerdp3_bin))"
        return 0
    fi
    printf '%s\n' "  prerequisites MISSING: ${missing[*]}"
    MISSING_PREREQS=("${missing[@]}")
    return 1
}

install_deps() {
    local pm p pkgs=()
    report_prereqs && return 0
    pm="$(detect_pm)"
    [[ -n "$pm" ]] || die "no supported package manager found; install manually:
    ${MISSING_PREREQS[*]}  (see docs/COMPATIBILITY.md)"
    for p in "${MISSING_PREREQS[@]}"; do pkgs+=($(pkg_for "$p" "$pm")); done
    local cmd
    case "$pm" in
      apt-get) cmd="apt-get update && apt-get install -y ${pkgs[*]}" ;;
      dnf|yum) cmd="$pm install -y ${pkgs[*]}" ;;
      pacman)  cmd="pacman -Sy --noconfirm ${pkgs[*]}" ;;
      zypper)  cmd="zypper --non-interactive install ${pkgs[*]}" ;;
    esac
    say installing "$pm: ${pkgs[*]}"
    eval "$cmd" || die "prerequisite install failed (docs/COMPATIBILITY.md has the
    per-distro notes)"
    freerdp3_bin >/dev/null 2>&1 || die "a FreeRDP >= 3 client is still absent.
    Debian 12 and RHEL 8 ship only FreeRDP 2, which lacks RDSTLS - the protocol
    grd's port 3390 handover requires. See docs/COMPATIBILITY.md."
    # The bridge launcher invokes 'xfreerdp3' by name; alias where it is 'xfreerdp'.
    if ! command -v xfreerdp3 >/dev/null 2>&1 && [[ "$(freerdp3_bin)" == "xfreerdp" ]]; then
        ln -sf "$(command -v xfreerdp)" /usr/local/bin/xfreerdp3
        say aliased "xfreerdp3 -> $(command -v xfreerdp)"
    fi
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
    img="$(sed -n 's/^GUACD_IMAGE=//p' "$ENVF" | tail -1 | sed 's/^"//; s/"$//')"
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
    # NOT shipped: .git/, docs/, img/, patches/, pod/, relay/test_*.py,
    # run_tests.sh, requires.txt, CHANGELOG.md, README.md, any .env.
    # README.md in particular must not ship: it quotes the development root, and
    # `grep -rl <dev root> /opt/cockpit-guac-rdp` has to return nothing for the
    # one audit that catches a payload reaching back into a checkout.
    # relay/test_*.py are excluded by LIBEXEC naming them one by one, not by glob.
    return 0
}

keys_of() { grep -v '^[[:space:]]*#' "$1" | grep '=' | sed 's/=.*//' | sed 's/[[:space:]]//g' | sort -u; }

refuse_secret_shaped_values() {
    local k v
    while IFS='=' read -r k v; do
        k="${k// }"
        [[ "$k" =~ (PASS|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|PASSPHRASE) ]] || continue
        [[ "$k" =~ _(FILE|PATH|DIR|NAME|ID|USER)$ ]] && continue
        [[ -z "${v// }" ]] && continue
        die "$k in $ENVF looks like a secret VALUE. A deployed .env carries locations
    and settings, never secrets. The 3390 door key in particular belongs in grd's
    own credential store, which edy-rdp-rotate-rdplogin writes - not here."
    done < <(grep -v '^[[:space:]]*#' "$ENVF" | grep '=')
    ok "no secret-shaped value in $ENVF"
}

# The migration: /etc/default/edy-rdp used to be this project's settings file.
# It is now [install path]/.env, because it was `.envdefault` wearing the wrong
# hat (DEPLOY-CONTRACT section 5: behaviour is .envdefault, content is
# etcdefaults/). An operator's edits move ACROSS; nothing is deleted here.
seed_env() {
    if [[ -e "$ENVF" ]]; then
        say kept "$ENVF (not overwritten)"
        local new_keys
        new_keys="$(comm -23 <(keys_of "$SRC/$ENVDEFAULT") <(keys_of "$ENVF") | tr '\n' ' ')"
        [[ -z "${new_keys// }" ]] || warn "this version adds keys your .env does not set: $new_keys
       install.sh refuses until they are set - the known cost of never clobbering
       an operator's file, paid at the only moment it can be caught safely."
    elif [[ -f "$LEGACY_DEFAULT" ]]; then
        install -m 0644 "${OWN[@]}" -- "$LEGACY_DEFAULT" "$ENVF"
        say migrated "$LEGACY_DEFAULT -> $ENVF (your edits, carried across)"
        local new_keys
        new_keys="$(comm -23 <(keys_of "$SRC/$ENVDEFAULT") <(keys_of "$ENVF") | tr '\n' ' ')"
        [[ -z "${new_keys// }" ]] || warn "keys this version adds, not in your old file: $new_keys
       Add them to $ENVF from $SRC/$ENVDEFAULT before install.sh runs."
        warn "$LEGACY_DEFAULT is left in place and is NO LONGER READ. Nothing here
       deletes your file - but two config files where one is ignored is how a
       setting gets changed and never takes effect. Remove it once you agree."
    else
        install -m 0644 "${OWN[@]}" -- "$SRC/$ENVDEFAULT" "$ENVF"
        say seeded "$ENVF from $ENVDEFAULT - REVIEW IT BEFORE FIRST USE"
        warn "EDY_RDP_REMOTE_ALLOW is empty, so the Remote-host scenario is OFF.
       That is the fail-closed default and it is the right one; read the comment
       in $ENVF before you widen it."
    fi
    refuse_secret_shaped_values
}

preflight() {
    printf 'deploy pre-flight\n'
    [[ -f "$SRC/install.sh" && -f "$SRC/$ENVDEFAULT" ]] || die "install.sh or $ENVDEFAULT is missing"
    if [[ -z "$D" ]]; then
        local mp; mp="$(df -P "$(dirname -- "$ROOT")" 2>/dev/null | awk 'NR==2{print $6}')"
        if [[ -n "$mp" ]] && findmnt -no OPTIONS --target "$mp" 2>/dev/null | tr ',' '\n' | grep -qx noexec; then
            die "the filesystem holding $ROOT ($mp) is mounted noexec. Every script
    under $LIBEXECDIR would fail at first click. Use --install-to, or remount."
        fi
    fi
    ok "install path $ROOT is usable"
    report_prereqs || warn "deploy will copy files, but the relay cannot run until these
       exist. Re-run with --with-deps, or install them yourself."
    ok "manifest: ${#PAGE[@]} page files, ${#LIBEXEC[@]} libexec, ${#UNITS[@]} units, ${#SYSFILES[@]} system files"
}

do_deploy() {
    preflight
    ((WITH_DEPS)) && { printf '\nOS prerequisites\n'; install_deps; }
    printf '\ndeploy %s %s -> %s\n' "$PROJECT" "$VERSION" "$ROOT"
    install -d -m 0755 "${OWN[@]}" -- "$ROOT_D"

    rm -rf -- "$NEW.tmp"
    copy_declared_payload_into "$NEW.tmp"
    [[ -d "$NEW" ]] && remove_old_payload "$NEW"
    mv -T -- "$NEW.tmp" "$NEW"; say copied "$NEW"

    ln -sfn -- "payload-$VERSION" "$ROOT_D/payload.new"
    mv -T -- "$ROOT_D/payload.new" "$ROOT_D/payload"
    say swapped "$ROOT_D/payload -> payload-$VERSION"

    seed_env
    ((WITH_USERS)) && { printf '\nusers\n'; create_users; }
    ((WITH_IMAGE)) && { printf '\nguacd image\n'; pull_image; }

    local p keepers
    mapfile -t keepers < <(ls -1d "$ROOT_D"/payload-* 2>/dev/null | grep -v "payload-$VERSION\$" | sort -r)
    for p in "${keepers[@]:$KEEP}"; do [[ -n "$p" ]] && remove_old_payload "$p"; done

    printf '\nrunning the INSTALLED install.sh (not this checkout copy)\n'
    DESTDIR="$D" "$ROOT_D/payload/install.sh"

    if ((WITH_UNITS)) && [[ -z "$D" ]]; then
        printf '\nenabling units (--with-units)\n'
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
        warn "edy-rdp-rotate-rdplogin.timer was NOT enabled. It rotates the 3390
       greeter door credential, which only matters once that door is configured
       at all (docs/KNOWN_ISSUES.md I29). Enable it deliberately:
           systemctl enable --now edy-rdp-rotate-rdplogin.timer"
    else
        printf '\nunits were rendered and placed, and NOT enabled.\n'
    fi

    if ((WITH_ALRD)); then
        printf '\nlocked-remote-desktop extension (--with-locked-remote-desktop)\n'
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
  who may use it: usermod -aG $RELAY_GROUP <user>
  verify:        ss -tlnp | grep 4822          (127.0.0.1 only)
                 nft list table inet edy_rdp_guacd
                 ls -l /run/edy-rdp/guacd.sock
  rollback:      ln -sfn payload-<older> $ROOT/payload.new \\
                 && mv -T $ROOT/payload.new $ROOT/payload && $ROOT/payload/install.sh
  configure:     \$EDITOR $ENVF   then  systemctl restart edy-rdp-relay.service
  cockpit.socket was NOT touched.
EOF
}

do_verify() {
    printf 'deploy verify\n'
    local rc=0
    [[ -L "$ROOT_D/payload" ]] && ok "$ROOT_D/payload -> $(readlink -- "$ROOT_D/payload")" \
                               || { echo "  FAIL $ROOT_D/payload is not a symlink"; return 1; }
    [[ -f "$ENVF" ]] && ok "$ENVF present" || { echo "  FAIL $ENVF missing"; return 1; }
    refuse_secret_shaped_values
    if grep -RIn -e "$DEV_ROOT" -e "$RETIRED_ROOT" -- "$ROOT_D/payload/" "$ENVF" 2>/dev/null; then
        echo "  FAIL a deployed file names the development share or the retired root (above)"
        rc=1
    else
        ok "no deployed file names the development share or the retired root"
    fi
    "$ROOT_D/payload/install.sh" --verify || rc=1
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
