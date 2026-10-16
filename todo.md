# cockpit-guac-rdp: open work

The single list of open work for this repo. Verified 2026-10-15 against `origin/main` (1.10.10.20261015, the architecture-diagram change
included), the live payload on edt1 and GitHub, then re-checked by an independent validator. Tick or delete an item in the SAME PR that closes it,
and add a line when new open work appears. `docs/KNOWN_ISSUES.md` holds the per-issue detail; this file holds what is still to
do. Memory only points here.

## Deploy state
- **edt1 runs 1.11.1.20261016**, deployed 2026-10-16 from `origin/main` 65bc67c (#44). Check with
  `cat /opt/cockpit-guac-rdp/payload/VERSION` against `git show origin/main:VERSION`. The kept rollback payload is
  `payload-1.11.0.20261016` (one step back: `ln -sfn payload-1.11.0.20261016 /opt/cockpit-guac-rdp/payload.new` and the rest
  of the printed rollback). The 1.11.0 deploy had pruned `payload-1.10.10.20261015` because retention sorted names lexically;
  #43 fixed that (`sort -rV`) and the 1.11.1 deploy proved it live, keeping 1.11.0 and pruning 1.9.3. A rollback to 1.10.10
  itself means redeploying `dedc49b`.
- Everything shipped is on main and live: I59 (#34-#36), I60 Logs… viewer (#37), I61 (#38), I62 (#39), I63 the Architecture tab
  diagram, I64 dependency tracking + native-rollback-where-available (#42; rollback exercised in containers on dnf, apt, pacman
  and zypper).

## Owner decisions

## Live verification still owed
- **I60 "Logs…" viewer (#37)**: unit-tested and deployed, but never click-tested in a live Cockpit session (main window or
  pop-out). KNOWN_ISSUES I60 and the CHANGELOG record only the unit tests.
- **Desktop audio (I42/I59)**: I59 records `PULSE_SOURCE=auto` resolving to the real USB speaker, and I42 is still marked
  "live verification pending". An audible end-to-end check by the owner has never been recorded. See the pop-out autoplay item.

## Open code follow-ups
- **Sound may stay silent in a pop-out (hypothesis from code, not reproduced).** In this plugin's code, `applySoundGate()` is the
  only place that resumes the shared AudioContext. It runs at connect (after the async connect flow; a pop-out auto-connects
  from `location.hash` with no click in its own document) and from the Sound toggle's change handler. The hypothesis may not
  hold in a real browser: Chromium passes user activation to a window opened by `window.open()` from a click, and may start a
  context on the next audio source once activation exists. Reproduce in a pop-out first; the likely fix is to resume on the
  first pointer/key event in the document.
- **Relay fails open when `loginctl` errors.** `_active_graphical_sessions()` (`relay/edy_rdp_relay.py`) returns 0 ("nobody is
  signed in") when `loginctl list-sessions` fails or prints nothing, `_run()` turns an exception or timeout into `(1, "")`, and a
  failed `show-session` is skipped. The I48 greeter failover (`resolveConsoleFallback` in `guac-rdp.js`, fed by the control
  op `deskui-status`) switches to the greeter exactly when the count is 0. Return unknown on error instead of 0. The
  `seated_uids()` docstring still calls this failure mode "cosmetic", which is stale now that it drives routing.
- **I48 false greeter redirect after a door sign-in (inferred from code, not reproduced).** The same function counts only
  sessions with a non-empty `Seat=`, but CHANGELOG 1.10.5 records that a session handed off through this project's RDP door
  never carries a `Seat=`. With a user signed in that way the count is 0, and a console connect is sent to the greeter.
- **I44 (+ D-10)**: `~/.config/pipewire/pipewire-pulse.conf.d/20-edy-tcp.conf` (dated Sep 13) is still present and
  `127.0.0.1:4713` (anonymous) is listening, so the I54 self-test "No anonymous PulseAudio TCP (4713)" fails on edt1 today.
  Confirm nothing relies on the TCP listener (audio capture binds the sink-monitor over the unix socket, see I42/I59), then
  remove the file and restart pipewire-pulse.
- **I6**: edt1's RDP :3390 gate credential is stored recoverably. `gnome-remote-desktop` (uid 980) is in no group but its own, `tss`
  is gid 987, and `/dev/tpmrm0` is `tss`-only. Untried fix: add it to `tss`. (Group membership re-checked 2026-10-15; the
  credentials file is root-only and was not re-read.)
- **Remote VNC is probably refused for everyone while `EDY_RDP_REMOTE_ADMIN_ONLY=1` (inferred from code, not tested).** The page's
  `needAdmin = !!t.admin || (key === "remote" && isAdmin)` never asks for administrator proof for `vnc`, but the relay requires
  it for `remote` and `vnc` when `REMOTE_ADMIN_ONLY` is set. edt1's `.env` sets it to 1, and the relay journal has no
  `scenario=vnc` line since 2026-09-01, so the path has never run here. Fix: include `vnc` in the page condition, with a test.
- **wayvnc has no password and no firewall rule on its port.** `waylandvnc/edy-rdp-waylandvnc-start.sh` writes `enable_auth=false`
  on `127.0.0.1:34000+(uid-1000)`, and the live ruleset has no rule for 34000-34999 (only guacd's 4822 and 33000-33999), so any
  local user can attach to another user's Wayland desktop. Code-derived; no Wayland session was running to observe the listener.
  Idea: extend the loopback/owner rule to 34000-34999 and/or enable wayvnc auth.
- **The guacd owner gate is fail-open at the unit level.** `edy-rdp-firewall.service` is ordered before guacd, but
  `edy-rdp-guacd.service` does not `Require=` it, and the firewall unit's ExecStop deletes both tables, so guacd can run
  with no owner-match if the firewall unit is stopped or fails.
- **Why the FreeRDP 3 (Janua) guacd is pinned.** `requires.txt` justifies it by the 3390 RDSTLS greeter, yet on every path the
  Architecture tab draws the relay rewrites guacd's connect to VNC against x11vnc and never uses guacd's RDP client. Either the
  pin is unnecessary for those paths or another reason is unrecorded.
- **I5 status.** Its heading still reads OPEN, but I29 addendum 4 says the patch also carries the I5 fix and addendum 6 records
  that the patched daemon is live (verified 2026-10-15). Re-verify I5 live and update its status.
- **Root leftover**: `/usr/libexec/gnome-remote-desktop-daemon.bak-20260909-152628` is byte-identical to `.orig-edt1` (both the
  stock package file): redundant, a root/owner decision.
- **The diagram's amber label is static text** that names edt1 (the patch is hand-built and not shipped). If another host gets the
  patch, derive the label from the I54 "grd patch integrity" self-test instead.
- **Docs: KNOWN_ISSUES statuses.** I43 still reads OPEN (reclaim procedure) but the live state is clean (2026-10-15: payload ->
  payload-1.10.9.20261003, every page and libexec link resolves into it, no regular file directly under
  `/usr/share/cockpit/guac-rdp`); flip it to RESOLVED with the date. Still genuinely open and deferred: **I46** (numpad
  `KP_Decimal` resolves to the Brazilian/JIS comma keycode) and **I57** (a rapid control change during a graceful disconnect can
  null a new session's client).
- **Hygiene**: `fix/headless-rdp-nft-ephemeral-replies` (local and origin) is the head of merged PR #38 (squash-merged as 34faf1a, so
  `git cherry` still shows `+`); delete it. The worktree record `/tmp/cockpit-guac-wt-input` (head of merged #39) is prunable
  (`git worktree prune`). In the shared checkout the local `main` is at 1.10.5.20260930 (5 behind), and the local
  `feat/self-update` (6 behind) and `feat/trace-diagnostics` (24 behind) lag their origin branches: fast-forward or delete.
- **Tests**: the Playwright harness lives outside git (`~/Documents/ClaudeSystem/cockpit-e2e`, not a repo; its `guac-rdp.spec.js`,
  `isolated-headless.spec.js`, `sessions-tab.spec.js` and 13 other specs are in no git history), and `run_tests.sh` skips it
  unless `E2E_DIR` has `node_modules`.

## Unbuilt directives and upstream bugs
- **Defence layer**: designed (`docs/DEFENSE-LAYER.md`, "DESIGN, not deployed", written against v1.3.2), not built. KNOWN_ISSUES
  I1/I2 read `OPEN→(design closes)`; I5, I6, I7 and I13 are plain OPEN (I3 and I4 are closed in their addenda; I26 was
  re-attributed and I29 resolved the isolated path). Its section 4 lists 13 defects D-1..D-13 present at v1.3.2, and only D-10
  (I44) is tracked in KNOWN_ISSUES: triage the rest.
- **Client-to-server clipboard drops are an upstream guacd/x11vnc bug** (root-caused 2026-09-28; I58 records it as upstream in
  guacd/x11vnc's VNC clipboard handling). The shipped workaround is "Type Clipboard" (I58). A 2026-09-30 session drop after a
  large copy from the remote logged `guacd[612]: ERROR: Error handling message from VNC server.`; that the large copy caused it
  is an untested hypothesis, and guac status 515 "Aborted" is also the routine client-teardown status (DEFENSE-LAYER.md), so it
  proves nothing alone. Proof needs the I60 trace plus a raised guacd log level on a repro.
