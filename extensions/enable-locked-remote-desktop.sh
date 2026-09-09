#!/usr/bin/env bash
#
# enable-locked-remote-desktop.sh - OPT-IN. Install the bundled third-party GNOME
# Shell extension "Allow Locked Remote Desktop" for a desktop user and enable it.
#
#   ./enable-locked-remote-desktop.sh [--user NAME] [--uninstall] [--verify]
#
# WHY
#   By GNOME's own design, gnome-remote-desktop (grd) TEARS DOWN the screen-share
#   the instant the session locks (gnome-shell's unlock-dialog mode inhibits remote
#   access), and refuses a new one while locked. That is exactly why this project's
#   console/virtual mirror is refused on a locked seat (docs/KNOWN_ISSUES I38/I39).
#   This extension no-ops that one inhibit call, so the mirror STAYS connected
#   through a lock and the lock screen can be unlocked remotely. Verified end-to-end
#   on Ubuntu 26.04 / GNOME 50 (memory: allow-locked-remote-desktop-vm).
#
# SECURITY TRADEOFF - read before enabling
#   This REMOVES a deliberate boundary. Anyone who can reach the grd RDP port with
#   valid credentials can not only view the locked screen but type the password and
#   unlock it -- and because the user screen-share mirrors the PHYSICAL seat,
#   unlocking remotely also unlocks the physical console for a bystander. grd binds
#   ALL interfaces by default (*:3389), so restrict the RDP port with a firewall rule
#   (or rebind grd to loopback) on any untrusted or PUBLIC interface; a fully trusted
#   internal LAN is the operator's call. Use strong, unique RDP credentials. This is
#   why it is opt-in and never enabled by default.
#
# NOTES
#   * Third-party: github.com/jikamens/allow-locked-remote-desktop (GPL; see the
#     bundled COPYING). We ship a pinned copy under this directory; we do not fetch.
#   * Per-USER: the extension patches the user's gnome-shell, so it is installed
#     into that user's ~/.local/share and enabled in that user's dconf. Run it AS
#     the desktop user, or as root with --user NAME.
#   * WAYLAND: a newly-installed extension only LOADS on the next gnome-shell start
#     (log out and back in, or reboot) -- there is no live reload on Wayland. This
#     script enables it in dconf so it activates automatically on that next login.
set -Eeuo pipefail

UUID="allowlockedremotedesktop@kamens.us"
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$UUID"
ACTION=install
USER_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --user)      USER_NAME="${2:?--user needs a name}"; shift 2 ;;
    --uninstall) ACTION=uninstall; shift ;;
    --verify)    ACTION=verify; shift ;;
    -h|--help)   sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve the target desktop user. Default: the invoking non-root user.
[ -n "$USER_NAME" ] || USER_NAME="${SUDO_USER:-$USER}"
[ "$USER_NAME" = "root" ] && { echo "refusing to target root; pass --user NAME" >&2; exit 2; }
id "$USER_NAME" >/dev/null 2>&1 || { echo "no such user: $USER_NAME" >&2; exit 2; }
UID_N="$(id -u "$USER_NAME")"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
DEST="$HOME_DIR/.local/share/gnome-shell/extensions/$UUID"

# Run a command in the target user's session/dconf context.
asuser() {
  if [ "$(id -u)" = "0" ] && [ "$USER_NAME" != "root" ]; then
    runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR="/run/user/$UID_N" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" "$@"
  else
    XDG_RUNTIME_DIR="/run/user/$UID_N" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" "$@"
  fi
}

# Append/remove the uuid in dconf's enabled-extensions without clobbering the rest
# (gsettings prints an empty typed array as "@as []", which literal-eval chokes on).
edit_enabled() {  # $1 = add|remove
  asuser python3 - "$1" "$UUID" <<'PY'
import ast, subprocess, sys
op, uuid = sys.argv[1], sys.argv[2]
k = ['org.gnome.shell', 'enabled-extensions']
out = subprocess.check_output(['gsettings', 'get', *k]).decode().strip()
if out.startswith('@as '):
    out = out[4:]
cur = ast.literal_eval(out) if out.strip() else []
if op == 'add' and uuid not in cur:
    cur.append(uuid)
elif op == 'remove' and uuid in cur:
    cur.remove(uuid)
subprocess.run(['gsettings', 'set', *k, str(cur)])
# Read back: a dconf write with no live session bus can no-op SILENTLY, so verify the
# change actually landed rather than trusting the set's exit code.
back = subprocess.check_output(['gsettings', 'get', *k]).decode().strip()
if back.startswith('@as '):
    back = back[4:]
now = ast.literal_eval(back) if back.strip() else []
landed = (uuid in now) if op == 'add' else (uuid not in now)
if not landed:
    sys.stderr.write("  FAILED: dconf did not persist enabled-extensions -- run this INSIDE "
                     "the desktop user's graphical session (a session bus is required)\n")
    sys.exit(1)
print('  enabled-extensions:', now)
PY
}

case "$ACTION" in
  verify)
    echo "target user   : $USER_NAME (uid $UID_N)"
    echo "bundled source: $SRC"
    [ -f "$SRC/metadata.json" ] && echo "  metadata: $(grep -oE '"(shell-version|session-modes)"[^]]*]' "$SRC/metadata.json" | tr '\n' ' ')" || echo "  MISSING bundled extension"
    echo "installed     : $([ -d "$DEST" ] && echo "$DEST" || echo no)"
    asuser gnome-extensions info "$UUID" 2>/dev/null | grep -iE 'state' | sed 's/^/  /' || echo "  (not loaded yet / no session)"
    ;;
  install)
    [ -f "$SRC/metadata.json" ] && [ -f "$SRC/extension.js" ] || { echo "bundled extension missing at $SRC" >&2; exit 1; }
    install -d -o "$USER_NAME" -m 0755 "$DEST"
    install -o "$USER_NAME" -m 0644 "$SRC/metadata.json" "$SRC/extension.js" "$DEST/"
    [ -f "$SRC/COPYING" ] && install -o "$USER_NAME" -m 0644 "$SRC/COPYING" "$DEST/" || true
    echo "installed extension for $USER_NAME -> $DEST"
    asuser gnome-extensions enable "$UUID" 2>/dev/null || true   # no-op if shell hasn't rescanned yet
    edit_enabled add
    echo
    echo "ENABLED. It activates on ${USER_NAME}'s NEXT login/reboot (Wayland has no live reload)."
    echo "SECURITY: this lets a remote RDP client unlock the locked screen AND the physical"
    echo "          console. grd binds ALL interfaces (*:3389) -- restrict the RDP port on any"
    echo "          untrusted/public interface (a trusted internal LAN is your call); use strong"
    echo "          RDP credentials."
    ;;
  uninstall)
    edit_enabled remove || true
    asuser gnome-extensions disable "$UUID" 2>/dev/null || true
    [ -d "$DEST" ] && rm -rf "$DEST" && echo "removed $DEST"
    echo "disabled + removed for $USER_NAME (takes full effect on next login)."
    ;;
esac
