## 1.3.0.20260918 - 2026-09-18

Desktop UI control: enable / disable / start / stop the host's graphical desktop
from a new **Desktop UI** tab.

- **The four verbs, mapped to the graphical stack.** Enable = `set-default
  graphical.target` + enable the display manager; Disable = `set-default
  multi-user.target` + disable it; Start/Stop = start/stop the display manager
  (falling back to `isolate graphical.target` / `multi-user.target` on a host with
  no DM). The **display manager is detected** from systemd's
  `display-manager.service` alias (then a probe of gdm/gdm3/lightdm/sddm/…), never
  assumed. The tab also shows a read-only state on any host: boot target, DM
  running/enabled, and how many desktop sessions are in use right now. See
  [docs/DESKTOP-UI-CONTROL.md](docs/DESKTOP-UI-CONTROL.md).
- **Off by default, fail closed.** Writes refuse unless the host sets
  `EDY_RDP_DESKUI_ENABLE=1` (`.envdefault`); status stays readable. **Never set
  this on a workstation whose console you use** — a Stop there ends the local
  session. Enforced at the relay *and* re-checked in the privileged helper.
- **Guarded, admin-only, confirmed.** Every write needs a Cockpit administrator
  (`SO_PEERCRED` + admin group). Stop and Disable refuse unless the operator types
  the host's name; Stop additionally refuses while a graphical seat session is in
  use unless that confirmation is given (`stop-force`). All gates are server-side.
- **Same read/write pattern as the rest of the plugin.** Reads run unprivileged in
  the relay; writes go through a new `edy-rdp-deskui@<action>` oneshot unit that a
  polkit rule lets `edy-relay` start (that unit family only), backed by
  `deskui/edy-rdp-deskui.sh` which validates the action against a **fixed enum** —
  no arbitrary systemctl. New control ops `deskui-status` / `deskui`
  (`relay/control.py`, `relay/edy_rdp_relay.py`), 14 new unit tests
  (`relay/test_control.py`), UI in `index.html` / `guac-rdp.js` / `guac-rdp.css`.
- **Packaging fix (found by this feature).** `edy-rdp-unlock@.service` and
  `edy-rdp-waylandvnc@.service` — template units the relay starts on demand — were
  never in the installer's `UNITS` list, so a **clean install never placed them**
  (they only ever worked on the dev host, where they had been hand-placed). Added
  them alongside the new `edy-rdp-deskui@.service`. Standing checks in
  `run_tests.sh` now assert all three are placed, that the helper keeps its enum +
  opt-in gates, and that polkit grants the unit family.
- Corrected a pre-existing false positive in the deploy-contract audit: a `@WORD@`
  token inside a `#` comment (the `@DEFAULT_MONITOR@` pulse note in the guacd unit)
  was flagged as an unrendered placeholder by `run_tests.sh` and `install.sh
  --verify`; the scan now skips comment lines.

## 1.2.16.20260917 - 2026-09-17

Clipboard Send/Receive buttons, and NumLock reachable from the pop-out.

- **Explicit clipboard buttons.** New "Send clip" (browser → session) and "Receive
  clip" (session → browser) buttons in the main bar and in every pop-out/monitor
  window. They are the reliable clipboard path: running on a click gives them the
  browser's transient user activation, so `navigator.clipboard` read/write is
  permitted where the checkbox's gesture-less auto-sync gets blocked. The session's
  latest clipboard is now always captured (`lastRemoteClip`) so "Receive" has
  something to hand over; the Clipboard checkbox still drives best-effort auto-sync
  (`guac-rdp.js`). This restores clipboard in the pop-out, which had no clipboard
  control at all.
- **NumLock in the pop-out.** The `#numlock` button (which flips the *remote*
  NumLock — for when the guest and your local NumLock drift out of sync) is now
  surfaced in the pop-out/monitor control strip, not just the main window.
- Seatbar now scrolls horizontally instead of clipping, with compact buttons, so
  the extra controls all stay reachable (`guac-rdp.css`).

## 1.2.15.20260917 - 2026-09-17

Follow-ups from an opus self-audit of the v1.2.13–v1.2.14 keyboard work.

- **The ⊞ Win soft button now actually renders.** v1.2.14 defined it but never
  called it, so the button the changelog advertised didn't appear;
  `addWinKeyButton(bar)` is now wired into both pop-out modes (`guac-rdp.js`).
- **Mac Option/Alt fixed (same class as the Win key).** On a Mac the browser
  reports Option/Alt as `ISO_Level3_Shift`, which reaches the guest as AltGr — a Mac
  client could never send a plain Left Alt, breaking Alt-combos. `remapKeysym` now
  maps `ISO_Level3_Shift → Alt_L` **on Mac only** (genuine AltGr from non-Mac
  international keyboards is left alone).
- Known/accepted, unchanged: under `-nomodtweak` the numpad **digit** keys (KP_0–9)
  depend on the guest's NumLock being latched (fine when it is / lock-sync is on) —
  spot-check the numpad; numpad Enter is delivered as Return; the paren remap
  assumes a US client layout.

## 1.2.14.20260917 - 2026-09-17

Keyboard fidelity: the Windows key, 3-key modifier combos, and a soft ⊞ Win button.

- **Windows/Super key now works.** Guacamole maps the physical Win key (keyCode
  91/92) to `Meta_L`/`Meta_R`, which the guest sees as an Alt-ish key — so neither
  GNOME's Activities overview nor a Windows host's Start menu fired. The plugin now
  remaps `Meta_L/R → Super_L/R` (`remapKeysym` in `guac-rdp.js`), so it arrives as
  the real Super/LWin key.
- **Ctrl+Shift+[key] / Alt+Shift+[key] and other 3-key combos work.** x11vnc's
  default modtweak was *releasing a held Shift* before injecting a key that
  "doesn't need" it (turning Ctrl+Shift+Tab into Ctrl+Tab, Shift+Arrow into Arrow,
  etc.). The bridge now runs x11vnc with **`-nomodtweak`**, trusting the modifier
  keysyms Guacamole already sends (`bridge/edy-rdp-bridge-start.sh`).
- **Parentheses moved browser-side.** `-nomodtweak` disables `-skip_keycodes`
  (xkb-only), so the v1.2.12 paren fix moves into the plugin: `remapKeysym` sends
  the plain `9`/`0` keysym for `(`/`)`, and the held Shift that `-nomodtweak`
  preserves makes keycode 18/19 produce the parens. Same result, mode-compatible.
- **New "⊞ Win" soft button** in the pop-out/monitor windows sends the Super key
  explicitly (for combos, or where the local OS won't release the physical key).
- All verified with `x11vnc -debug_keyboard`. Takes effect on the next connection
  (the bridge is per-connection); no service restart. NOTE: `-nomodtweak` changes
  how the numpad/lock keys inject — worth a numpad spot-check.

## 1.2.13.20260917 - 2026-09-17

Pop-out windows: a "Special keys" toggle to redirect system shortcuts to the session.

- The pop-out (#seat) and virtual-monitor (#monitor) windows now carry a **Special
  keys** toggle in their top strip. When on, it puts the window into fullscreen and
  calls the **Keyboard Lock API** (`navigator.keyboard.lock()`), so system/browser
  shortcuts — Alt+Tab, Super/Win, Ctrl+W, Ctrl+T, Esc, F11, etc. — are delivered to
  the remote session instead of being eaten by the local browser/OS.
- Off by default (it grabs the whole keyboard, and enabling needs the fullscreen
  user gesture, so it is not auto-restored on load). Leaving fullscreen by any route
  (Esc/F11/WM) auto-releases the lock and the toggle reflects that. Requires a
  Chromium browser + secure context; where unsupported it falls back to fullscreen
  only. **Ctrl+Alt+Del is OS-reserved and can never be captured** (`guac-rdp.js`).
- Scoped to the pop-out/monitor windows: they are standalone windows where
  fullscreen + keyboard-lock work cleanly, unlike the Cockpit shell iframe.

## 1.2.12.20260917 - 2026-09-17

Fix: parentheses could not be typed in the mirror/RDP session.

- **`( ` and `)` silently produced nothing** while every other key worked. Root
  cause: Xvfb's us/pc105 keymap maps parenleft/parenright onto BOTH Shift+9/0
  (keycodes 18/19) AND phantom *unshifted* keycodes 187/188. x11vnc (in its
  auto-enabled `-xkb` mode) preferred the phantom 187/188, but xfreerdp3's
  scancode path has no RDP scancode for those extended keycodes, so the parens
  never reached grd.
- **Fix:** the bridge now runs x11vnc with `-skip_keycodes 187,188`, so it falls
  back to Shift+9 / Shift+0 (keycode 18/19), which xfreerdp3 maps to real RDP
  scancodes (`bridge/edy-rdp-bridge-start.sh`). Verified with `x11vnc
  -debug_keyboard`: parenleft now injects `Shift_L` + keycode `0x12 "9"`. Only
  187/188 are affected — the numpad and all other keys are untouched, and the
  option applies only in `-xkb` mode (already active). Takes effect on the next
  connection; no service restart.

## 1.2.11.20260917 - 2026-09-17

Pop-out layout fit + connect-bar settings persist across refresh.

- **Pop-out / virtual-monitor windows now fit the viewport with no scrollbars**:
  `#display` is `calc(100vw - 10px)` wide and `calc(100vh - 10px - seatbar)` tall,
  so the browser's scrollbar gutter (width:100vw) and an exact-100vh total no
  longer force a bottom/side scrollbar. The fixed seatbar keeps reserving the top
  strip via margin-top (`guac-rdp.css`).
- **The connect-bar toggles/selectors persist** (Session, Resolution, Scale,
  Clipboard, Sound). On change they are written to the URL hash — after any
  `#seat`/`#monitor` mode token, which is preserved — and mirrored to
  localStorage; on load they are restored (hash wins; localStorage is the
  refresh-safe fallback inside Cockpit's shell iframe). Pop-out and Add-Monitor
  windows inherit the current settings through their URL. Credentials
  (username/password/host) are never persisted (`guac-rdp.js`).

## 1.2.10.20260914 - 2026-09-14

Auto-close non-live mirror sessions (stop the "Active Sessions" pile-up).

- **Disconnected sessions in non-resumable scenarios (console/mirror, remote, vnc)
  are now reaped ~15s after the client leaves**, instead of being held for the
  15-minute `session_ttl` (`relay/session_registry.py`). They have no backend to
  resume — the xfreerdp3/Xvfb/x11vnc bridge is already torn down on disconnect —
  so a non-live entry was pure clutter. Reconnect-on-change (resolution/sound/
  resize each reconnect) had been leaving a stack of non-live mirror entries per
  user until the 15-minute TTL. Reconnectable scenarios (isolated/virtual) are
  unchanged — still kept for `session_ttl` so a reconnect resumes the same desktop.
- New `EPHEMERAL_SCENARIOS` / `EPHEMERAL_DISCONNECT_TTL` registry policy; the
  `ephemeral_ttl` is plumbed through the control `prune` op and the reaper
  (`--ephemeral-ttl`, default 15s; the reaper runs every 30s). Greeter
  (loginctl-reaped) and wayland-vnc (reaper treats it as resumable) are excluded.
- Tests extended (mirror reaped promptly; remote/vnc ephemeral; reconnectable
  untouched; TTL tunable; control pass-through). Full relay suite green (79 tests).
- **Live apply requires an `edy-rdp-relay` restart** (the prune runs in the relay
  daemon); the grd backend and guacd :4822 are untouched.

## 1.2.9.20260914 - 2026-09-14

Desktop audio actually works now (the Sound toggle).

- **Root cause of the silence: `PULSE_SOURCE=@DEFAULT_MONITOR@`.** That alias does
  not resolve on this host's pipewire-pulse — a record stream on it returns zero
  bytes even with the default sink active. An **explicit** sink-monitor name
  (`<sink>.monitor`) records fine (verified: ~196 KB in 3 s of tone). The install
  `.env` now sets `PULSE_SOURCE` to the explicit monitor of the desktop's sink.
- **The guacd unit template now carries the audio wiring** that had only ever been
  applied live (`systemd/edy-rdp-guacd.service.in`): an `ExecStartPre` that
  bind-mounts the seat's pulse **socket** to a stable host path, and the matching
  `-v /run/edy-rdp-pulse.sock:/run/pulse.sock`. The seat socket path is overridable
  with `EDY_RDP_PULSE_SEAT_SOCKET` (default uid 1000). A fresh deploy now ships a
  working audio path instead of needing hand-editing.
- **Docs/config corrected** (`.envdefault`, `docs/AUDIO.md`): the earlier TCP
  approach (`tcp:127.0.0.1:4713`) is removed — pipewire-pulse delivers no recording
  audio over `module-native-protocol-tcp`; only the local UNIX socket works. Both
  now describe the socket + explicit-monitor setup, with the `@DEFAULT_MONITOR@`
  and TCP dead ends documented so they are not re-attempted.
- **Note on mute:** the Sound toggle mutes **per-viewer at the browser**, by design.
  It does not mute the seat's OS sink, because muting the sink also silences the
  `.monitor` guacd records — which would kill the stream rather than quiet the view.

## 1.2.8.20260914 - 2026-09-14

Controls in the pop-out / virtual-monitor windows.

- **The chromeless pop-out (#seat) and virtual-monitor (#monitor) windows now show
  a slim top control strip** (`guac-rdp.js`, `guac-rdp.css`). Previously they hid
  the whole toolbar, so Sound/Resolution were unreachable there (which is why audio
  could never be enabled in a pop-out). The relevant controls are moved out of the
  hidden bar into the strip: the virtual-monitor window gets **Resolution + Sound**;
  the mirror pop-out gets its **monitor picker + Sound** (resolution N/A — the
  mirror is always native). The display sits below the strip.
- **The Sound toggle now (re)negotiates audio live**: because `enable-audio` is a
  connect-time parameter, toggling Sound reconnects the same scenario to add or
  drop the audio channel (mic was dropped — the VNC leg has no audio input).

## 1.2.7.20260914 - 2026-09-14

Fix the console mirror being clipped (right/bottom cut off).

- **The console mirror now always requests the NATIVE resolution** (`guac-rdp.js`).
  1.2.3 downscaled the mirror's requested size below native to save bandwidth, but
  grd's `mirror-primary` **ignores a smaller request and always streams the primary
  at native**, so xfreerdp rendered a native frame into a smaller Xvfb and the
  right/bottom were clipped. `chosenGeom` now returns native (exact) for `console`
  and lets the browser scale it; the Resolution selector still applies to the
  virtual monitor (grd honours it there) and remote hosts. Net: no server-side
  bandwidth saving for the mirror (grd streams native regardless), but the whole
  screen is visible again.

## 1.2.6.20260914 - 2026-09-14

Resolution selector.

- **NEW: a "Resolution" dropdown** in the toolbar (`index.html`, `guac-rdp.js`).
  It sets the resolution requested from the session (the guest framebuffer); the
  browser then scales it to the window with the existing machinery (fit-scaling +
  the 1.2.1 pointer alignment). Default **"Window size"** keeps today's behaviour
  (the mirror stays native-capped/​bandwidth-saving; other scenarios track the
  window). A fixed value (1280x720 ... 3840x2160) **pins** the guest resolution
  verbatim. Because resolution is fixed at connect, changing it live reconnects the
  same scenario at the new geometry; idle, it applies on the next connect. Distinct
  from **Scale**, which only zooms whatever is streaming.

## 1.2.5.20260913 - 2026-09-13

Desktop audio streaming for the mirror (opt-in).

- **The Sound toggle can now stream real desktop audio.** guacd (which runs on the
  host network) captures the seat's PulseAudio/PipeWire and streams it to the
  browser. The `edy-rdp-guacd` unit now passes `-e PULSE_SERVER -e PULSE_SOURCE`
  into the container; set them in `.env` (`PULSE_SERVER=tcp:127.0.0.1:4713`,
  `PULSE_SOURCE=@DEFAULT_MONITOR@`) after exposing pipewire-pulse over loopback TCP
  — see the new `docs/AUDIO.md`. `@DEFAULT_MONITOR@` records the default sink's
  monitor (what is PLAYING on the desktop), never a microphone. Unset = no audio
  channel (unchanged default). There is no mic/audio-input path (the browser leg
  is VNC). Verified on edt1: guacd reaches the seat's Pulse over TCP and records
  the HDMI sink monitor.

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
