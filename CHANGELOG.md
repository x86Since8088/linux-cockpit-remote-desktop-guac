## 1.2.4.20260913 - 2026-09-13

Pop-out: keep the mirror below the monitor picker.

- The `#seat` monitor picker is a fixed bar at the top, but the mirror filled the
  whole window from `top:0`, so the bar sat OVER the guest's top rows and the
  pointer could not reach them. The seatbar now has a fixed height and the display
  starts below it (`margin-top`/`height: calc(100vh - bar)`), so the guest's full
  height — top row included — is live.

## 1.2.3.20260913 - 2026-09-13

Mirror resolution policy: downscale on the server, upscale in the browser.

- **The mirror now caps the requested resolution at native and downscales
  server-side when the window is smaller** (`guac-rdp.js`). 1.2.2 always sent the
  full native resolution, which wasted bandwidth when the window was smaller than
  the monitor. Now the geometry is the native resolution scaled by
  `min(1, winW/nativeW, winH/nativeH)`: below native, grd/guacd downscale to the
  window size (fewer pixels on the wire — a half-size window sends ~¼ the pixels),
  preserving the native aspect; at or above native the browser upscales (never
  send more pixels than the monitor has). Non-mirror scenarios are unchanged.

## 1.2.2.20260913 - 2026-09-13

Mirror runs at native resolution; the browser does all the scaling.

- **The console mirror now requests the monitor's NATIVE resolution** as the RDP
  geometry (`guac-rdp.js`), instead of the browser window size. Previously the
  bridge was sized to the window, so grd scaled the native primary framebuffer to
  that size SERVER-side and the browser scaled again — double-scaling, and the
  pop-out and main window (different sizes) never aligned. Now `queryNativeGeom()`
  reads the primary monitor's current mode from Mutter `DisplayConfig` (1920×1080
  here) and the whole internal path (grd → xfreerdp → Xvfb → x11vnc → guacd) runs
  1:1 at native resolution with no server-side scaling. Falls back to the window
  size if the resolution can't be read, so a parse miss never blocks a connect.
- **The browser does all the scaling.** `display.onresize` now re-fits whenever the
  guest framebuffer size becomes known, so the native frame is scaled into the
  window client-side; with the 1.2.1 pointer-scale fix the mouse stays aligned.
  Every window that mirrors the same seat now shows identical native pixels, each
  scaled to its own size — so the pop-out and the main view align.

## 1.2.1.20260913 - 2026-09-13

Fix mouse alignment at non-100% scale and on window resize.

- **Mouse coordinates are now divided by the live display scale** (`guac-rdp.js`).
  The bundled `Guacamole.Mouse.fromClientPosition` maps pointer events through the
  display element's LAYOUT box (offsetLeft/offsetParent) and does NOT divide by the
  scale, while `display.scale(f)` sets that element's layout size to `guest*f` — so
  the reported state was in RENDERED pixels (0..guest*f) but `sendMouseState` needs
  guest pixels. Clicks therefore drifted at any zoom other than 100%, which is
  exactly what a resized "Fit to window" produces. A new `guestMouseState()`
  divides x/y by the tracked `curScale` before sending, keeping the pointer aligned
  at every zoom, on letterboxed aspect ratios, and while scrolled.
- **Resize now re-fits and re-syncs the pointer** (debounced, with a trailing
  `requestAnimationFrame`): `applyScale()` recomputes `curScale` (Fit follows the
  window; a pinned factor stays put) and the mouse handler reads it live, so the
  surface stays aligned after a resize. (The guest resolution itself is fixed at
  connect — the bridge's Xvfb is a fixed size — so this scales+aligns rather than
  re-resolutioning.)

## 1.2.0.20260913 - 2026-09-13

**Pop-out** — the mirrored seat in its own chromeless window, with a monitor picker.

- **NEW: "Pop-out" button** (`index.html`, `guac-rdp.js`, `guac-rdp.css`). It
  re-opens this page in a minimal pop-up (no tabs/toolbar/address bar) marked
  `#seat`: chromeless, titled `Physical Monitor — <host>`, auto-connecting the
  console mirror at the window's size. Unlike Add Monitor, closing the window only
  **disconnects this view** — it never terminates the physical desktop.
- A slim **physical-monitor picker** overlays the top of the pop-out, populated
  from the seat's real outputs via Mutter `DisplayConfig` (grd's own "Virtual
  remote monitor" entries are filtered out). NOTE: grd mirrors the *primary*
  monitor, so with several physical monitors the picker currently reflects the
  layout and shows the primary; mirroring a chosen non-primary output needs a grd
  capability that does not exist yet. On a single-monitor seat it simply shows that
  monitor.

## 1.1.9.20260913 - 2026-09-13

Fix a connection regression from 1.1.7's always-on audio / eager clipboard.

- **`enable-audio` is opt-in again** (`guac-rdp.js`). 1.1.7 negotiated audio on
  every connect, so guacd tried and failed a PulseAudio connection each time
  (`Connecting to PulseAudio... PulseAudio connection failed`) — noise at best,
  and implicated in a login-screen connect regression. Audio is once more
  negotiated only when Sound is on at connect; live mute/unmute still works while
  connected.
- **Outbound clipboard only fires on a fully-open session.** The focus reader that
  pushes the local clipboard now checks `currentUuid` (set on tunnel OPEN), so it
  no longer writes to the RDP clipboard channel during connect/teardown (which
  surfaced `cliprdr VirtualChannelWrite failed`).

## 1.1.8.20260913 - 2026-09-13

**Add Monitor** — a virtual monitor in its own chromeless window.

- **NEW: "Add Monitor" button** in the connect bar (`index.html`, `guac-rdp.js`,
  `guac-rdp.css`). It re-opens this Cockpit page in a minimal pop-up window (no
  tabs, toolbar or address bar; `window.open(..., "popup,…")`) marked with
  `#monitor` in the hash. That pop-up goes chromeless (a `html.monitor` CSS class
  hides the tabs/bar/footer and makes the display fill the window), sets a
  descriptive title (`Virtual Monitor N — <host>`), and auto-connects a fresh
  **virtual** monitor (grd `extend` mode) at the window's size. The pop-up carries
  its own Cockpit transport (shared session cookie).
- **Closing the window closes the monitor.** On `pagehide`/`beforeunload` the
  pop-up disconnects and sends `terminate` for its session; even absent that, the
  window's transport drop makes the relay reap the bridge and grd drop the virtual
  monitor, so the virtual desktop never lingers.
- The button is available in every mode (not just the mirror), so you can spin up
  extra virtual monitors alongside a console mirror or any other session.

## 1.1.7.20260913 - 2026-09-13

Sound and clipboard passthrough are now gated by **live** toggles.

- **Clipboard passthrough is now actually wired to the browser** and gated live by
  the Clipboard checkbox (`guac-rdp.js`). Previously the checkbox only set guacd's
  `disable-copy`/`disable-paste` at connect while the plugin implemented no
  client-side clipboard at all, so nothing reached the browser. Now
  `client.onclipboard` writes the remote clipboard into the browser (remote →
  local) and a display-focus reader pushes the local clipboard into the session
  (local → remote), each honouring a live `clipboardOn` flag — the browser's own
  clipboard is touched only while the toggle is on. Best-effort: the browser
  Clipboard API can be restricted inside a Cockpit iframe, so every access is
  guarded and a denial degrades to "no sync", never an error.
- **Sound gates live** (`guac-rdp.js`). Audio is now always negotiated with guacd
  and playback is muted/unmuted instantly by suspending/resuming Guacamole's
  shared `AudioContext` — so Sound toggles mid-session with no reconnect (resume
  runs from the toggle click, satisfying autoplay policy). guacd produces silence
  when the deployment has no audio source, so always offering the channel is
  harmless.
- Both toggles are wired to apply on `change` during a live session; `guacdValues`
  no longer sets `disable-copy`/`disable-paste` (a connect-time gate that would
  defeat a live toggle) — the gate now lives in the browser.

## 1.1.6.20260913 - 2026-09-13

On-screen **Num Lock** toggle, and lock sync is now edge-triggered.

- **NEW: a "Num Lock" toggle button** in the connect bar (`index.html`,
  `guac-rdp.js`, `guac-rdp.css`). It sends NumLock into the session on demand —
  for laptops/keyboards with no numpad key, or browsers that will not forward
  NumLock — shows its on/off state (accent fill), and refocuses the display so
  typing keeps landing in the session. Enabled only while connected.
- **Lock sync is now edge-triggered, not level-forced.** The reconcile added in
  1.1.5 aligned the session to the browser on the first keystroke; it now mirrors
  only *subsequent changes* to the browser's locks (tracked in `browserLocks`).
  That is what lets the manual toggle coexist: it moves the session but not
  `browserLocks`, so the next keystroke no longer reverts it. Physical lock-key
  presses still ride Guacamole's own path and are tracked, never double-toggled.

## 1.1.5.20260913 - 2026-09-13

Keyboard lock-state (NumLock / CapsLock / ScrollLock) sync.

- **NEW: lock-key sync in the plugin** (`guac-rdp.js`). The bundled
  `Guacamole.Keyboard` forwards a lock KEY when it is pressed live, but it does
  not know the browser's CURRENT lock state, so a session opened while the
  browser already holds NumLock started with the opposite state: x11vnc then had
  to fake the missing modifier when it XTEST-injected `KP_*` keysyms into the
  Xvfb and mis-typed the numpad (End instead of 1, and so on). The plugin now
  reconciles NumLock/CapsLock/ScrollLock to the browser's actual state (read via
  the DOM `getModifierState`) on the first keystroke, and self-heals on drift, by
  sending the lock keysym — which rides the normal key path
  (guacd → x11vnc XTEST → Xvfb → xfreerdp3 → grd), toggling every hop, including
  grd's own RDP lock sync. Live lock-key presses still ride Guacamole's own path
  (the handler only tracks them, so it never double-toggles). The session's
  baseline is all-off (a fresh Xvfb, synced to grd on connect); no bridge, relay
  or guacd change was needed.

## 1.1.4.20260909 - 2026-09-09

Greeter (3390 Remote Login) works again, and NLA no longer hangs on a dead DC.

- **NEW: Kerberos preflight for local-grd NLA** (`bridge/edy-rdp-krb-preflight.sh`,
  wired into the bridge for loopback targets). FreeRDP3 tries Kerberos first, so a
  down AD DC made xfreerdp3 hang ~2 min before falling back to NTLM. The preflight
  probes every configured KDC's port 88 **in parallel with a 500 ms timeout**, points
  krb5 at only the ones that answer, and — when none do — writes a krb5.conf with no
  KDC so Kerberos fails instantly and NLA drops straight to NTLM (the door/gate users
  are local grd credentials, never AD principals). Every attempt/result/decision is
  logged to `<key>.krblog`. This unblocked the greeter, which was failing NLA before
  the handover ever ran.
- **grd handover patch re-deployed on edt1** (KNOWN_ISSUES I29): the method-call
  handover daemon (`patches/grd-handover-method-call.patch`, sha `5c08514e`) is
  installed over stock (backed up to `.orig-edt1`) and the package is held. With the
  preflight in front of it, the GDM greeter renders and logs in over the browser path.

## 1.1.3.20260909 - 2026-09-09

Opt-in remote-unlock of a locked screen, and a keyboard-mode correction.

- **NEW (opt-in, off by default): "Allow Locked Remote Desktop".** Bundled the pinned
  third-party GNOME extension `allowlockedremotedesktop@kamens.us` (GPL) under
  `extensions/`, with an enabler `extensions/enable-locked-remote-desktop.sh` and a
  `deploy.sh --with-locked-remote-desktop` flag. It no-ops grd's teardown-on-lock so the
  console/virtual mirror stays connected through a lock and can be unlocked remotely —
  the resolution to KNOWN_ISSUES I38. Security tradeoff (it also unlocks the physical
  console): see `docs/LOCKED-REMOTE-DESKTOP.md`. Verified end-to-end on Ubuntu 26.04 /
  GNOME 50.
- **REVERTED `/kbd:unicode:on` in the bridge (I39a).** A VM test showed unicode mode
  mangles keys injected through the x11vnc→Xvfb path (`MultiByteToWideChar` buffer
  errors → wrong password); scancode is faithful. Back to scancode.
- Keyboard capture in the plugin now binds to the focusable display element (not the
  document) so keystrokes reach the session.

## 1.1.2.20260907 - 2026-09-07

Install classification is now decided by LAYOUT, not by a development-root path
prefix, and this plugin was deployed to its real install path on edt1.

- `install.sh` decides dev vs deployed by asking whether its own directory is
  what a sibling `payload` symlink resolves to. The old test compared `$SRC`
  against a hardcoded development root and got a checkout sitting ANYWHERE ELSE
  wrong: such a checkout classified itself `deployed`, so it skipped the
  group-writable warning, wrote INSTALL_KIND=deployed for a host that was not
  self-sustaining, and dropped "the checkout is not touched" from
  `--uninstall`. Reproduced before the change and confirmed fixed after.
- Because that literal is gone, pre-flight check 9 now scans `install.sh`
  itself. The carve-out that exempted it is removed. Both of the check's own
  patterns are split so the scanner cannot match itself; the string it searches
  for is unchanged, so nothing is weakened.
- `owned_by_us` recognises a dev link by `$SRC` rather than by "anywhere
  under the development root", which is tighter: it no longer adopts a link
  belonging to a different checkout of the same project.
- The uninstall notice and the dev warning ask the LINK TARGET's layout, so
  they stay correct when the deployed installer tears down links a dev install
  made.
- Deployed to /opt/cockpit-guac-rdp on edt1. Relay configuration migrated from
  /etc/default/edy-rdp into the install path's .env, every key value compared and
  identical; the old file is left in place for the operator to remove.
- All ten units were re-rendered and daemon-reloaded. Nothing was enabled,
  started, stopped or restarted, and cockpit.socket was not touched.
A recursive grep of the deployed tree for the development root or the retired
checkout path now returns nothing at all.

# Changelog

## 1.1.1.20260903 — 2026-09-03

### Fixed
- **Clear error when the physical screen is locked (I38).** grd refuses to mirror a locked
  desktop (`Session creation inhibited`), which reached the client as an opaque
  `Broken pipe` / `ERRCONNECT_CONNECT_TRANSPORT_FAILED`. The relay now detects a locked
  active graphical seat session on a console/virtual bridge failure and returns
  *"the physical screen is locked — unlock it … then reconnect."* The check fails open
  (never blocks a working connection) and does not affect the isolated scenario.

## 1.1.0.20260902 — 2026-09-02

### Added — Remote-host RDP scenario
- New **"Remote host"** scenario: RDP from the browser into another host on the network
  (Windows or Linux RDP server), rendered through the same FreeRDP 3 bridge. Enter an IPv4
  target + port + your RDP credentials for that host.
- **Fail-closed, admin-configurable allow-list** `EDY_RDP_REMOTE_ALLOW` in
  `/etc/default/edy-rdp` (empty = feature off / deny-all; `any` = allow-all; IPv4/CIDR[:port]).
  The relay validates the target to a strict IPv4 literal and checks the allow-list **before**
  any bridge/slot side-effect — the SSRF gate. Optional `EDY_RDP_REMOTE_ADMIN_ONLY`.
- Remote credentials are per-connection and never stored; markers are stripped server-side so
  guacd never sees the target or the credential. The remote leg **negotiates NLA+TLS with plain
  RDP-standard security disabled** (`/sec:rdp:off`) — Windows uses NLA, other RDP servers use
  TLS, never weak encryption — and pins the cert with `/cert:tofu` (MITM-on-change detected)
  vs `/cert:ignore` for the trusted local grd.
- Verified end-to-end: a container relay RDP'd into a live xrdp host and rendered an
  interactive remote desktop.
- 10 new relay unit tests (allow-list matching, deny-before-dial, malformed-target rejection,
  admin gate); adversarially security-reviewed (KNOWN_ISSUES I33–I35).

### Security hardening (found by the adversarial review)
- **Fixed a pre-existing SSRF (I36):** a newline in a client-supplied RDP credential could forge
  `HOST=`/`PORT=` lines in the bridge request file and redirect the dial — affecting the
  loopback-only `virtual`/`console` paths too, not just remote. Now rejected at three layers
  (relay credential check, `bridge.py` per-field check, launcher `.req` line-count + first-wins).
- **Added a per-uid concurrent-bridge cap (I37)** to prevent display-slot exhaustion (DoS).

## 1.0.0.20260901 — 2026-09-01

First tagged release. Browser-based RDP into a host's GNOME desktop from inside Cockpit,
with guacd never on a host port and no session hijacking.

### Features
- Three scenarios: **isolated** (your own persistent headless GNOME desktop), **virtual
  monitor**, and **console** (admin-only mirror of the physical screen).
- **FreeRDP 3 bridge** rendering path (xfreerdp3 → Xvfb → x11vnc → guacd VNC), because
  guacd's bundled FreeRDP 2 cannot negotiate NLA/RDSTLS to gnome-remote-desktop.
- **Security gates:** SO_PEERCRED peer auth; per-user UUID binding (anti-hijack); an
  elevation-proven server-side console admin gate; a uid-bound 256-bit session token;
  a per-connection VNC password; an RDP-target allow-list; guacd on host loopback behind
  an nftables owner-match.
- **Session lifecycle:** registry + control API (list/terminate/register/elevate); the
  connection is torn down on disconnect while a persistent desktop is kept for reconnect
  (same `DESKTOP_ID`), then reaped once idle. Daily rotation of the 3390 door credential.
- A redacting trace logger (`edy-rdp-trace`) that logs everything except secrets.

### Packaging
- `install.sh` **auto-installs OS prerequisites** on a vanilla system (apt/dnf/pacman/
  zypper) with `--deps-only` / `--skip-deps`; pinned prerequisites in `requires.txt`.
- Pinned guacd image `guacamole/guacd:1.6.0`.
- Config surface `/etc/default/edy-rdp` (installed from `etcdefaults/`, preserved on upgrade).
- Per-distro compatibility matrix (`docs/COMPATIBILITY.md`); FreeRDP ≥ 3 required, with an
  `xfreerdp3` alias auto-created where the client binary is `xfreerdp`.

### Verified
- Deployed and tested on a vanilla Ubuntu 26.04 **container** (rootless podman) and a
  **VM** (192.168.122.169, real systemd, native podman, nftables owner-gate active).
- Browser observation suite (`cockpit-e2e/`) green across all scenarios; 46 relay unit tests pass.

### Known limitations
- Full desktop rendering requires a real GNOME session on the host (the console/virtual
  scenarios); a container has no desktop backend and cannot load nftables (host-privilege).
- The isolated opt-in credential auto-login flow and the single-port 3389 mux are specced
  but not built (`docs/SPEC-3389-mux.md`).
