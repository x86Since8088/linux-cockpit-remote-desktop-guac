# cockpit-guac-rdp: open work

The single list of open work for this repo. Verified 2026-10-15 against `origin/main` (5a04438, 1.10.8.20261003), the live
payload on edt1 and GitHub, then re-checked by an independent validator. Tick or delete an item in the SAME PR that closes it,
and add a line when new open work appears. `docs/KNOWN_ISSUES.md` holds the per-issue detail; this file holds what is still to
do. Memory only points here.

## Deploy state
- **edt1 runs 1.10.9.20261003 (deployed 2026-10-03 14:08 CDT); `origin/main` is 1.10.8.20261003.** The only difference from main
  is an interactive "How a connection reaches a desktop" SVG diagram in `index.html` + `guac-rdp.css` (+300/-11 lines, plus the
  footer version). It was never committed and no PR ever held it. Every other shipped file in the live payload is byte-identical
  to main (`diff -r`, 2026-10-15). A snapshot is on **`origin/rescue/arch-diagram-deployed-1.10.9`** (a verbatim copy of the
  three live files, `run_tests.sh` PASS, no PR). Until it is PR'd or dropped, the next deploy of main removes the diagram from
  the live page. The only other copy is the live payload directory (the older `payload-1.9.3.20260929` beside it does not have
  the diagram). See Owner decisions.
- Everything else shipped is on main and live: I59 (#34-#36), I60 Logs… viewer (#37), I61 (#38), I62 (#39).

## Owner decisions
- **Architecture diagram**: PR the rescue branch (it needs a version bump above 1.10.8, a CHANGELOG entry and a KNOWN_ISSUES
  entry) or drop it.
- **`feat/dependency-tracking`** (the branch the shared checkout sits on; 5 commits of 2026-09-29, tip f50d894, 35 commits behind
  main; **local only, it has no remote branch, so dropping it deletes the only copy**; no PR): "dependency tracking +
  native-rollback admin tab". Its issue id **I51 collides with main's I51** (group rename) and its VERSION 1.7.0.20260929 is
  the exact string main's I49 shipped as, so it needs a renumber and a version bump if revived. Review, then PR or drop. Test
  its rollback only in a container. With the checkout left on it, read current main with `git show origin/main:<file>`.

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
- **I5 register contradiction**: I29 addendum 5 (2026-09-01) reverted the patched `gnome-remote-desktop` to stock, which per I5
  re-introduces the one-time-credential D-Bus broadcast, yet I54's "grd patch integrity" self-test (2026-09-29) presumes the patch
  is installed. No re-application is recorded. Check which binary is live (root compare) and make the docs and the self-test agree.
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
