#!/usr/bin/env bash
#
# install.sh - install cockpit-guac-rdp: the OS prerequisites, the Cockpit plugin,
#              the guacd relay + FreeRDP3 bridge, systemd units, hardening drop-ins,
#              and the edy-rdp group.
#
# Usage:
#   sudo ./install.sh                 # system install (deps + plugin + relay + units)
#   sudo ./install.sh --uninstall     # remove everything this installed
#   sudo ./install.sh --deps-only     # only install the OS prerequisites, then stop
#   sudo ./install.sh --skip-deps     # do not touch OS packages (assume prereqs present)
#   ./install.sh --user               # plugin only, into ~/.local/share/cockpit
#   ./install.sh --plugin-only        # plugin only, system-wide (no relay/units)
#   DESTDIR=/tmp/stage ./install.sh   # stage into a package build root (implies --skip-deps)
#
# A vanilla-system install auto-installs the OS prerequisites (Cockpit, podman,
# xfreerdp3/FreeRDP3, Xvfb, x11vnc, nftables, gnome-remote-desktop, python3) using
# the host's package manager (apt/dnf/pacman/zypper). See docs/COMPATIBILITY.md for
# the per-distro matrix. The plugin itself is plain HTML/CSS/JS (no build step, no
# node); the relay is stdlib Python 3; guacd runs from the guacamole/guacd container.
set -Eeuo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NAME="guac-rdp"
VERSION="$(cat "$SRC/VERSION" 2>/dev/null || echo 1.0.0.20260901)"
# Pinned guacd container image (record: version 1.6.0). requires.txt carries the digest.
GUACD_IMAGE="docker.io/guacamole/guacd:1.6.0"
MODE="system"
ACTION="install"
PLUGIN_ONLY=0
DEPS=1          # auto-install OS prerequisites on a full system install
DEPS_ONLY=0     # --deps-only: install prerequisites and stop

# The Cockpit package payload (flat), mirrored by the stale-file sweep.
PLUGIN=(manifest.json index.html guac-rdp.js guac-rdp.css guac-proto.js)
PLUGIN_DIRS=(guacamole-common-js)

usage() { sed -n '2,20p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --user) MODE="user"; PLUGIN_ONLY=1; DEPS=0; shift ;;
    --system) MODE="system"; shift ;;
    --plugin-only) PLUGIN_ONLY=1; DEPS=0; shift ;;
    --deps-only) DEPS_ONLY=1; shift ;;
    --skip-deps) DEPS=0; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done
# staging a package build root never touches the live OS package set
[[ -n "${DESTDIR:-}" ]] && DEPS=0

if [[ "$MODE" == "user" ]]; then
  CBASE="${XDG_DATA_HOME:-$HOME/.local/share}/cockpit"
else
  CBASE="${DESTDIR:-}/usr/share/cockpit"
fi
CTARGET="$CBASE/$NAME"
LIBEXEC="${DESTDIR:-}/usr/libexec/edy-rdp"
UNITDIR="${DESTDIR:-}/etc/systemd/system"
TMPFILESD="${DESTDIR:-}/usr/lib/tmpfiles.d"
DBUSDIR="${DESTDIR:-}/etc/dbus-1/system.d"
DEFAULTDIR="${DESTDIR:-}/etc/default"

# ---------------- OS prerequisites (auto-install) ----------------
# The prereq set and per-distro package names are documented in docs/COMPATIBILITY.md.
# Detection is by BINARY presence (idempotent: a re-run installs nothing new).

detect_pm() { # first supported package manager on PATH, or "" (unsupported distro)
  local pm
  for pm in apt-get dnf yum pacman zypper; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }
  done
  echo ""
}

pkg_for() { # $1=canonical prereq  $2=package manager  -> package name(s)
  case "$2:$1" in
    apt-get:cockpit)  echo "cockpit cockpit-system" ;;   # metapackage pulls bridge+ws; -system is the shell UI
    apt-get:freerdp3) echo "freerdp3-x11" ;;
    apt-get:xvfb)     echo "xvfb" ;;
    apt-get:grd)      echo "gnome-remote-desktop" ;;
    apt-get:dbus)     echo "dbus-bin" ;;
    apt-get:*)        echo "$1" ;;                       # podman python3 x11vnc nftables

    dnf:cockpit|yum:cockpit)     echo "cockpit cockpit-system" ;;
    dnf:freerdp3|yum:freerdp3)   echo "freerdp" ;;
    dnf:xvfb|yum:xvfb)           echo "xorg-x11-server-Xvfb" ;;
    dnf:grd|yum:grd)             echo "gnome-remote-desktop" ;;
    dnf:dbus|yum:dbus)           echo "dbus-tools" ;;
    dnf:*|yum:*)                 echo "$1" ;;

    pacman:cockpit)  echo "cockpit" ;;
    pacman:freerdp3) echo "freerdp" ;;
    pacman:xvfb)     echo "xorg-server-xvfb" ;;
    pacman:python3)  echo "python" ;;
    pacman:grd)      echo "gnome-remote-desktop" ;;
    pacman:dbus)     echo "dbus" ;;
    pacman:*)        echo "$1" ;;

    zypper:cockpit)  echo "cockpit cockpit-bridge" ;;
    zypper:freerdp3) echo "freerdp" ;;
    zypper:xvfb)     echo "xorg-x11-server-Xvfb" ;;
    zypper:grd)      echo "gnome-remote-desktop" ;;
    zypper:dbus)     echo "dbus-1-tools" ;;
    zypper:*)        echo "$1" ;;
    *) echo "$1" ;;
  esac
}

# The FreeRDP3 client is 'xfreerdp3' on Debian/Ubuntu but 'xfreerdp' (v3) elsewhere.
# Echo whichever is present AND FreeRDP major >= 3; fail if only FreeRDP2 exists.
freerdp3_bin() {
  if command -v xfreerdp3 >/dev/null 2>&1; then echo xfreerdp3; return 0; fi
  if command -v xfreerdp  >/dev/null 2>&1 \
     && xfreerdp /version 2>/dev/null | grep -qE 'version 3\.'; then echo xfreerdp; return 0; fi
  return 1
}

have_prereq() { # $1=canonical prereq -> 0 if satisfied
  case "$1" in
    cockpit)  command -v cockpit-bridge >/dev/null 2>&1 && [ -d /usr/share/cockpit/system ] ;;  # bridge + shell UI
    podman)   command -v podman    >/dev/null 2>&1 ;;
    python3)  command -v python3   >/dev/null 2>&1 ;;
    xvfb)     command -v Xvfb      >/dev/null 2>&1 ;;
    x11vnc)   command -v x11vnc    >/dev/null 2>&1 ;;
    nftables) command -v nft       >/dev/null 2>&1 ;;
    grd)      command -v grdctl    >/dev/null 2>&1 ;;
    dbus)     command -v dbus-send >/dev/null 2>&1 ;;
    freerdp3) freerdp3_bin >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

PREREQS=(cockpit podman python3 freerdp3 xvfb x11vnc nftables grd dbus)

preflight_deps() {
  local pm; pm="$(detect_pm)"
  local p missing=() pkgs=()
  for p in "${PREREQS[@]}"; do have_prereq "$p" || missing+=("$p"); done

  if ((${#missing[@]}==0)); then
    echo "prerequisites: all present (FreeRDP3 client: $(freerdp3_bin))"
  else
    echo "prerequisites missing: ${missing[*]}"
    [[ -n "$pm" ]] || die "no supported package manager found; install manually: ${missing[*]} (see docs/COMPATIBILITY.md)"
    for p in "${missing[@]}"; do pkgs+=($(pkg_for "$p" "$pm")); done
    local cmd
    case "$pm" in
      apt-get) cmd="apt-get update && apt-get install -y ${pkgs[*]}" ;;
      dnf|yum) cmd="$pm install -y ${pkgs[*]}" ;;
      pacman)  cmd="pacman -Sy --noconfirm ${pkgs[*]}" ;;
      zypper)  cmd="zypper --non-interactive install ${pkgs[*]}" ;;
    esac
    [[ "$(id -u)" == "0" ]] || die "need root to install prerequisites. Run as root, or run:
    $cmd"
    echo "installing prerequisites via $pm: ${pkgs[*]}"
    eval "$cmd" || die "prerequisite install failed (see docs/COMPATIBILITY.md for per-distro notes)"
    freerdp3_bin >/dev/null 2>&1 || die "FreeRDP3 client still absent after install; a FreeRDP>=3 package is required (Debian 12/RHEL8 ship only FreeRDP2 — see docs/COMPATIBILITY.md)"
  fi

  # The bridge launcher invokes 'xfreerdp3' by name. Where the client is 'xfreerdp'
  # (Fedora/Arch/openSUSE), symlink an 'xfreerdp3' alias so the launcher stays portable.
  if [[ -z "${DESTDIR:-}" ]] && ! command -v xfreerdp3 >/dev/null 2>&1; then
    if [[ "$(freerdp3_bin 2>/dev/null)" == "xfreerdp" && "$(id -u)" == "0" ]]; then
      ln -sf "$(command -v xfreerdp)" /usr/local/bin/xfreerdp3 \
        && echo "aliased xfreerdp3 -> $(command -v xfreerdp)"
    fi
  fi

  # guacd runs from a container image: pre-pull so the first connect isn't slow and
  # an offline/air-gapped install surfaces the missing image now, not at runtime.
  if [[ -z "${DESTDIR:-}" ]] && command -v podman >/dev/null 2>&1; then
    echo "pulling guacd image ($GUACD_IMAGE)..."
    podman pull "$GUACD_IMAGE" >/dev/null 2>&1 \
      && echo "guacd image ready" \
      || echo "warning: could not pre-pull guacd image; edy-rdp-guacd.service pulls it on first start"
  fi
}

# ---------------- uninstall ----------------
if [[ "$ACTION" == "uninstall" ]]; then
  if [[ "$MODE" != "user" ]]; then
    systemctl disable --now edy-rdp-pod.service edy-rdp-reaper.timer edy-rdp-firewall.service 2>/dev/null || true
    rm -f  "$UNITDIR"/edy-rdp-firewall.service /etc/nftables.d/edy-rdp-headless.nft 2>/dev/null || true
    # stop any running per-user isolated headless sessions (I29)
    for u in $(systemctl list-units 'edy-rdp-headless@*' --no-legend 2>/dev/null | awk '{print $1}'); do
      systemctl stop "$u" 2>/dev/null || true
    done
    rm -f  "$UNITDIR"/edy-rdp-pod.service "$UNITDIR"/edy-rdp-reaper.service \
           "$UNITDIR"/edy-rdp-reaper.timer "$UNITDIR"/edy-rdp-headless@.service \
           "$UNITDIR"/ALT-host-relay.edy-rdp-relay.* 2>/dev/null || true
    rm -f  "${DESTDIR:-}/etc/polkit-1/rules.d/49-edy-rdp-headless.rules" \
           /etc/nftables.d/edy-rdp-headless.nft \
           "$LIBEXEC"/edy-rdp-headless-start "$LIBEXEC"/edy-rdp-headless-stop 2>/dev/null || true
    rm -f  "$TMPFILESD/edy-rdp.conf" "$DBUSDIR/org.gnome.RemoteDesktop.handover.conf" \
           "$DEFAULTDIR/edy-rdp" 2>/dev/null || true
    rm -rf "$LIBEXEC" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    if [[ -z "${DESTDIR:-}" ]]; then
      # revert the greeter handover D-Bus policy on the RUNNING bus, not just next boot
      dbus-send --system --type=method_call --dest=org.freedesktop.DBus \
        / org.freedesktop.DBus.ReloadConfig 2>/dev/null || true
      # I29: restore the STOCK grd daemon if the greeter patch was deployed over it,
      # so uninstall does not silently leave a dpkg-divergent daemon + open 3390 door.
      GRD_BIN=/usr/libexec/gnome-remote-desktop-daemon
      if [[ -f "${GRD_BIN}.orig-edt1" ]]; then
        install -m0755 "${GRD_BIN}.orig-edt1" "$GRD_BIN" \
          && rm -f "${GRD_BIN}.orig-edt1" \
          && systemctl restart gnome-remote-desktop.service 2>/dev/null \
          && echo "restored stock gnome-remote-desktop-daemon (greeter patch reverted)"
        apt-mark unhold gnome-remote-desktop 2>/dev/null || true
      fi
      # I29: remove the 3390 Remote-Login door credential set for the greeter
      grdctl --system rdp clear-credentials 2>/dev/null || true
    fi
  fi
  rm -rf -- "$CTARGET" && echo "removed $CTARGET" || echo "nothing at $CTARGET"
  exit 0
fi

# ---------------- pre-flight ----------------
echo "cockpit-guac-rdp v$VERSION — $MODE install"
for f in "${PLUGIN[@]}"; do [[ -f "$SRC/$f" ]] || die "missing $SRC/$f"; done
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SRC/manifest.json" \
    || die "manifest.json is not valid JSON"
fi
if [[ "$MODE" == "system" && -z "${DESTDIR:-}" && "$(id -u)" != "0" ]]; then
  die "system install needs root; use sudo, or --user for the plugin only"
fi

# ---------------- OS prerequisites ----------------
if ((DEPS_ONLY)); then
  preflight_deps
  echo "prerequisites complete (--deps-only). Re-run without --deps-only to install the plugin+relay."
  exit 0
fi
((DEPS)) && preflight_deps

# ---------------- plugin ----------------
install -d -m 0755 "$CTARGET"
for f in "${PLUGIN[@]}"; do install -m 0644 "$SRC/$f" "$CTARGET/$f"; done
for d in "${PLUGIN_DIRS[@]}"; do
  install -d -m 0755 "$CTARGET/$d"
  find "$SRC/$d" -maxdepth 1 -type f -exec install -m 0644 {} "$CTARGET/$d/" \;
done
# stale-file sweep (top level only; a bad leftover makes Cockpit drop the package)
while IFS= read -r -d '' stale; do
  base="$(basename "$stale")"; keep=0
  for f in "${PLUGIN[@]}"; do [[ "$base" == "$f" ]] && keep=1 && break; done
  ((keep)) || { rm -f -- "$stale"; echo "removed stale $base"; }
done < <(find "$CTARGET" -maxdepth 1 -type f -print0)
echo "installed plugin to $CTARGET"

if ((PLUGIN_ONLY)); then
  echo "plugin-only install complete."
  exit 0
fi

# ---------------- users / group ----------------
if [[ -z "${DESTDIR:-}" ]]; then
  getent group edy-rdp >/dev/null || { groupadd --system edy-rdp && echo "created group edy-rdp"; }
  # dedicated uid the relay runs as; the nftables owner-match keys on it.
  if ! getent passwd edy-relay >/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g edy-rdp edy-relay \
      && echo "created user edy-relay"
  fi
  echo "note: add each Cockpit user who may use the plugin to 'edy-rdp': usermod -aG edy-rdp <user>"
fi

# ---------------- relay + reaper code ----------------
install -d -m 0755 "$LIBEXEC"
install -m 0755 "$SRC/relay/edy_rdp_relay.py"    "$LIBEXEC/edy_rdp_relay.py"
install -m 0755 "$SRC/relay/edy_rdp_reaper.py"   "$LIBEXEC/edy_rdp_reaper.py"
install -m 0644 "$SRC/relay/session_registry.py" "$LIBEXEC/session_registry.py"
install -m 0644 "$SRC/relay/control.py"           "$LIBEXEC/control.py"
install -m 0644 "$SRC/relay/bridge.py"            "$LIBEXEC/bridge.py"
# FreeRDP3 bridge launcher (xfreerdp3 -> Xvfb -> x11vnc; guacd VNC bridges to browser).
# Needs xfreerdp3 (freerdp3-x11), Xvfb (xvfb) and x11vnc installed on the host.
install -m 0755 "$SRC/bridge/edy-rdp-bridge-start.sh" "$LIBEXEC/edy-rdp-bridge-start"
# per-user isolated headless-session lifecycle scripts (I29)
install -m 0755 "$SRC/headless/edy-rdp-headless-start.sh" "$LIBEXEC/edy-rdp-headless-start"
install -m 0755 "$SRC/headless/edy-rdp-headless-stop.sh"  "$LIBEXEC/edy-rdp-headless-stop"

# ---------------- config defaults (/etc/default/edy-rdp) ----------------
# Ship the relay's tunable defaults. PRESERVE an operator-edited file on upgrade
# (conffile semantics); only install it when absent or when staging into DESTDIR.
install -d -m 0755 "$DEFAULTDIR"
if [[ -e "$DEFAULTDIR/edy-rdp" && -z "${DESTDIR:-}" ]]; then
  echo "kept existing /etc/default/edy-rdp (not overwritten)"
else
  install -m 0644 "$SRC/etcdefaults/edy-rdp" "$DEFAULTDIR/edy-rdp"
  echo "installed /etc/default/edy-rdp"
fi

# ---------------- units + tmpfiles + dbus ----------------
install -d -m 0755 "$UNITDIR" "$TMPFILESD" "$DBUSDIR"
install -m 0644 "$SRC/systemd/edy-rdp-guacd.service"  "$UNITDIR/edy-rdp-guacd.service"
install -m 0644 "$SRC/systemd/edy-rdp-relay.socket"   "$UNITDIR/edy-rdp-relay.socket"
install -m 0644 "$SRC/systemd/edy-rdp-control.socket" "$UNITDIR/edy-rdp-control.socket"
install -m 0644 "$SRC/systemd/edy-rdp-relay.service"  "$UNITDIR/edy-rdp-relay.service"
install -m 0644 "$SRC/systemd/edy-rdp-reaper.service" "$UNITDIR/edy-rdp-reaper.service"
install -m 0644 "$SRC/systemd/edy-rdp-reaper.timer"   "$UNITDIR/edy-rdp-reaper.timer"
install -m 0644 "$SRC/systemd/edy-rdp-headless@.service" "$UNITDIR/edy-rdp-headless@.service"
install -m 0644 "$SRC/systemd/edy-rdp-firewall.service"  "$UNITDIR/edy-rdp-firewall.service"
# polkit: let edy-relay start ONLY the per-user headless units (I29)
POLKITRULES="${DESTDIR:-}/etc/polkit-1/rules.d"; install -d -m 0755 "$POLKITRULES"
install -m 0644 "$SRC/hardening/edy-rdp-headless.rules" "$POLKITRULES/49-edy-rdp-headless.rules"
install -m 0644 "$SRC/systemd/edy-rdp-tmpfiles.conf"  "$TMPFILESD/edy-rdp.conf"
install -m 0644 "$SRC/hardening/org.gnome.RemoteDesktop.handover.conf" \
                "$DBUSDIR/org.gnome.RemoteDesktop.handover.conf"

# ---------------- nftables owner-match (guacd reachable only by the relay uid) ----------------
if [[ -z "${DESTDIR:-}" ]]; then
  RELAY_UID="$(id -u edy-relay)"
  NFTDIR=/etc/nftables.d; install -d -m 0755 "$NFTDIR"
  sed "s/@RELAY_UID@/$RELAY_UID/g" "$SRC/hardening/edy-rdp-guacd.nft" > "$NFTDIR/edy-rdp-guacd.nft"
  chmod 0644 "$NFTDIR/edy-rdp-guacd.nft"
  # per-user headless RDP ports (33000-33999) reachable only via loopback (I29)
  install -m 0644 "$SRC/hardening/edy-rdp-headless.nft" "$NFTDIR/edy-rdp-headless.nft"
fi

if [[ -z "${DESTDIR:-}" ]]; then
  systemd-tmpfiles --create "$TMPFILESD/edy-rdp.conf" || true
  systemctl daemon-reload
  # make the handover D-Bus policy drop-in take effect now (not just next boot)
  dbus-send --system --type=method_call --dest=org.freedesktop.DBus \
    / org.freedesktop.DBus.ReloadConfig 2>/dev/null || true
  # firewall loader: applies the nft rules now AND on every boot (before guacd),
  # since this host uses ufw and nftables.service is disabled -> /etc/nftables.d
  # is otherwise never loaded, leaving 4822 world-reachable after a reboot.
  systemctl enable --now edy-rdp-firewall.service \
    && echo "enabled edy-rdp-firewall (nft owner-match + headless loopback, persistent)"
  systemctl enable --now edy-rdp-guacd.service
  sleep 2
  systemctl enable --now edy-rdp-relay.socket edy-rdp-control.socket edy-rdp-reaper.timer
  systemctl start edy-rdp-relay.service || true
  echo
  echo "Verify:"
  echo "  guacd loopback-only + nft-gated:  ss -tlnp | grep 4822   (127.0.0.1 only)"
  echo "  only edy-relay reaches it:        nft list table inet edy_rdp_guacd"
  echo "  relay socket:                     ls -l /run/edy-rdp/guacd.sock"
fi

cat <<'NOTE'

Installed (host-loopback guacd + nftables uid-gate; no pod).
  * guacd binds 127.0.0.1:4822 in the host netns; the nftables owner-match admits
    ONLY the edy-relay uid (and root). Every other local uid is dropped.
  * Add users to the edy-rdp group so their Cockpit bridge can reach the relay socket.
  * Load hardening/edy-rdp-firewall.nft too if you want 3389/3390/3391 off the LAN.
Cockpit picks up the plugin on next page load (Ctrl-Shift-R clears the cached manifest).

3390 "Remote Login" GREETER (native RDSTLS clients: xfreerdp3/mstsc; see KNOWN_ISSUES I29) needs, IN
ADDITION to this install (which ships the corrected handover D-Bus policy):
  * the grd handover patch built + deployed over /usr/libexec/gnome-remote-desktop-daemon
    (source/patches/grd-handover-method-call.patch; back up the stock daemon to .orig-edt1 first).
    An apt upgrade of gnome-remote-desktop reverts the daemon, so also:
        apt-mark hold gnome-remote-desktop      # release with 'apt-mark unhold' on uninstall
    and
  * a door credential:  grdctl --system rdp set-credentials rdplogin <key>   (the client passes NLA
    against this; the real user login happens at the GDM greeter).
The browser plugin's Isolated scenario uses the per-user headless path instead (guacd/FreeRDP2 can't RDSTLS).
NOTE
