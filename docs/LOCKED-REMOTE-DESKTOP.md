# Remote-unlock a locked screen (opt-in "Allow Locked Remote Desktop")

**Default: OFF.** This is a deliberate, security-weakening opt-in. Read the tradeoff
before enabling it.

## The problem it solves

By GNOME's own design, `gnome-remote-desktop` (grd) **tears the screen-share down the
instant the session locks** and refuses to start one while locked: gnome-shell enters
`unlock-dialog` session mode (`allowScreencast=false`) and calls
`MetaRemoteAccessController.inhibit_remote_access()`, which stops the running remote
session and blocks new ones. That is exactly why this project's **console / virtual
mirror is refused on a locked seat** — the relay relabels the resulting transport error
"the physical screen is locked" (see [KNOWN_ISSUES](KNOWN_ISSUES.md) **I38/I39**). The
sanctioned recovery is the panel's **Unlock** button (`control.py` `unlock` op →
`loginctl unlock-session` of the caller's own seat), and that is enough for most cases.

If instead you want the mirror to **stay connected through a lock and let you type your
password to unlock remotely**, that requires defeating the inhibit call — which stock
GNOME provides no supported switch for. The third-party GNOME Shell extension
**"Allow Locked Remote Desktop"** (jikamens, UUID `allowlockedremotedesktop@kamens.us`)
does it in a few lines:

```js
global.backend.get_remote_access_controller().inhibit_remote_access = () => {};
```

Its `metadata.json` ships `session-modes: ["user","unlock-dialog"]`, so gnome-shell keeps
the extension **running while the shield is up** — that is what makes the no-op hold
through the lock. Verified working on GNOME Shell 50 (mutter 50 still defines the patched
API). A pinned copy is bundled under `extensions/allowlockedremotedesktop@kamens.us/`
(GPL; see its `COPYING`). We ship it; we do not fetch it at install time.

## Enable it

Per-user (the extension patches *that user's* gnome-shell):

```bash
# as the desktop user, from the source or deployed tree:
extensions/enable-locked-remote-desktop.sh
# or as root for another user:
sudo extensions/enable-locked-remote-desktop.sh --user alice
```

Or fold it into a deployment (opt-in, **not** part of `--all`):

```bash
sudo ./deploy.sh --with-locked-remote-desktop                 # targets $SUDO_USER
# on a root / no-sudo path (e.g. the /srv/jobs runner), name the desktop user:
sudo ./deploy.sh --with-locked-remote-desktop --alrd-user alice
```

The enable step writes the target user's dconf, which needs that user's **live session
bus** — run it while they are logged in (the enabler read-backs and fails loudly if the
write did not persist).

**Wayland caveat:** a newly-installed extension only *loads* on the next gnome-shell
start — there is no live reload on Wayland (`Alt-F2 r` is X11-only). The enabler flips the
`org.gnome.shell enabled-extensions` key so it **activates automatically at the user's next
log out / log in or reboot**. Confirm afterwards:

```bash
gnome-extensions info allowlockedremotedesktop@kamens.us   # State: ACTIVE
```

## Use it

With the extension active, connect the **Console (mirror)** scenario as usual. When the
seat locks, the browser session stays connected and shows the GNOME lock screen; type the
password to unlock. (Keyboard note: the bridge deliberately uses xfreerdp3's **scancode**
mode — `/kbd:unicode:on` mangles keys injected through the x11vnc→Xvfb path and lands the
wrong password; see [KNOWN_ISSUES](KNOWN_ISSUES.md) **I39a**.)

## The security tradeoff — the reason it is off by default

This **removes a deliberate boundary**. Anyone who can reach the grd RDP port with valid
credentials can not only *view* the locked screen but **type the password and unlock it**
— and because the user screen-share mirrors the **physical seat**, unlocking remotely also
unlocks the **physical console** for anyone standing at the machine. GNOME blocks this on
purpose; the extension undoes that block.

Compensating controls:

- **Keep the grd RDP port off untrusted networks.** grd binds **all interfaces** by default
  (`*:3389`, greeter `*:3390`) — it is *not* loopback-only — so the locked screen is reachable
  from anything that can route to the host. A source-restricting rule (nftables/ufw) or
  rebinding grd to loopback is **required on any untrusted or public interface**; on a fully
  trusted internal LAN it is the operator's call. The browser bridge itself dials
  `127.0.0.1:3389`, so restricting 3389 to loopback + the local bridge does not break it.
- Use **strong, unique** RDP credentials; keep the TLS cert private.
- Treat the console as effectively unlocked whenever a remote operator unlocks it.

## Disable / remove

```bash
extensions/enable-locked-remote-desktop.sh --uninstall           # this user
sudo extensions/enable-locked-remote-desktop.sh --uninstall --user alice
```

Full effect (the shield resuming its normal teardown-on-lock) takes hold at the next login.

## Verified

End-to-end on a fresh **Ubuntu 26.04.1 / GNOME 50.1 / grd 50.2** VM matching the target
host: RDP into the live desktop → lock → the RDP session **survived** (stock grd would drop
it) and the lock screen rendered → typed the password → **unlocked**. Recipe and gotchas
(the gnome-keyring-under-autologin trap, scancode-vs-unicode input) are recorded in the
session memory `allow-locked-remote-desktop-vm`.
