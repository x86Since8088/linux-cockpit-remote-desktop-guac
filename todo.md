# cockpit-guac-rdp: open work

The single list of open work for this repo. Verified 2026-10-15 against `origin/main` (5a04438, 1.10.8.20261003), the live
payload on edt1 and GitHub. Tick or delete an item in the SAME PR that closes it, and add a line when new open work appears.
`docs/KNOWN_ISSUES.md` holds the per-issue detail; this file holds what is still to do. Memory only points here.

## Deploy state
- **edt1 runs 1.10.9.20261003 (deployed 2026-10-03 14:08 CDT); `origin/main` is 1.10.8.20261003.** The only difference from main
  is an interactive "How a connection reaches a desktop" SVG diagram in `index.html` + `guac-rdp.css` (+300/-11 lines). It was
  never committed and no PR ever held it. Every other shipped file in the live payload is byte-identical to main
  (`diff -r`, 2026-10-15). A snapshot is on **`origin/rescue/arch-diagram-deployed-1.10.9`** (verbatim copy of the live files,
  `run_tests.sh` PASS, no PR). Until it is PR'd or dropped, the next deploy of main removes the diagram from the live page, and
  the live payload directory was the only other copy. See Owner decisions.
- Everything else shipped is on main and live: I59 (#34-#36), I60 Logs… viewer (#37), I61 (#38), I62 (#39).

## Owner decisions
- **Architecture diagram**: PR the rescue branch (it needs a version bump above 1.10.8, a CHANGELOG entry and a KNOWN_ISSUES
  entry) or drop it.
- **`feat/dependency-tracking`** (the branch the shared checkout sits on; 5 commits of 2026-09-29, tip f50d894, 35 commits behind
  main, no PR): "dependency tracking + native-rollback admin tab". Its issue id **I51 collides with main's I51** (group rename),
  so renumber it if revived. Review, then PR or drop. Test its rollback only in a container. With the checkout left on it, read
  current main with `git show origin/main:<file>`.

## Live verification still owed
- **I60 "Logs…" viewer (#37)**: unit-tested and deployed, but never click-tested in a live Cockpit session (main window or
  pop-out).
- **Desktop audio (I42/I59)**: server-side capture verified 2026-09-30 (guacd "PulseAudio now ready", a byte-count `parec` test).
  An audible end-to-end check is still pending, and see the pop-out autoplay item below.

## Open code follow-ups
- **Sound may stay silent in a pop-out (inferred from code, not reproduced).** `applySoundGate()` is the only place that resumes
  the shared AudioContext. It runs at connect (after the async connect flow, and a pop-out auto-connects with no click in its
  own document) and from the Sound toggle's change handler. Nothing resumes it on the first user gesture in a pop-out opened
  with Sound already on. Reproduce in a browser first. The likely fix is to resume on the first pointer/key event.
- **Relay fails open when `loginctl` errors.** `_active_graphical_sessions()` (`relay/edy_rdp_relay.py`) returns 0 ("nobody is
  signed in") when `loginctl list-sessions` fails or prints nothing, and skips a session whose `show-session` fails. The I48
  greeter failover reads 0 as "offer the greeter". Return unknown on error instead of 0.
- **I44**: `~/.config/pipewire/pipewire-pulse.conf.d/20-edy-tcp.conf` (dated Sep 13) is still present and `127.0.0.1:4713` is
  listening. Confirm nothing relies on the TCP listener (audio capture binds the sink-monitor over the unix socket, see
  I42/I59), then remove the file and restart pipewire-pulse.
- **I6**: edt1's RDP :3390 gate credential is stored recoverably. `gnome-remote-desktop` (uid 980) is in no group but its own, `tss`
  is gid 987, and TPM init fails. Untried fix: add it to `tss`. (Group membership re-checked 2026-10-15. The credentials file is
  root-only and was not re-read.)
- **Docs: KNOWN_ISSUES statuses.** I43 still reads OPEN (reclaim procedure) but the live state is clean (2026-10-15: payload ->
  payload-1.10.9.20261003, every page and libexec link resolves into it, no regular files under
  `/usr/share/cockpit/guac-rdp`); flip it to RESOLVED with the date. Still genuinely open and deferred: **I46** (numpad
  `KP_Decimal` resolves to the Brazilian/JIS comma keycode) and **I57** (a rapid control change during a graceful disconnect can
  null a new session's client).
- **Hygiene**: `fix/headless-rdp-nft-ephemeral-replies` (local and origin) is the head of merged PR #38 (different patch ids, so
  `git cherry` still shows `+`); delete it. The worktree record `/tmp/cockpit-guac-wt-input` (head of merged #39) is prunable
  (`git worktree prune`). The shared checkout's local `main` is at 1.10.5.20260930, behind origin/main.
- **Tests**: the Playwright harness lives outside git (`~/Documents/ClaudeSystem/cockpit-e2e`, not a repo; its
  `guac-rdp.spec.js`, `isolated-headless.spec.js`, `sessions-tab.spec.js` and others exist nowhere else), and `run_tests.sh`
  skips it unless `E2E_DIR` has `node_modules`.

## Unbuilt directives and upstream bugs
- **Defence layer**: designed (`docs/DEFENSE-LAYER.md`), not built. KNOWN_ISSUES I1-I7, I13 and I26 stay OPEN until it is.
- **Client-to-server clipboard drops are an upstream guacd/x11vnc bug** (root-caused 2026-09-28; not this repo's code). The shipped
  workaround is "Type Clipboard" (I58). A large copy from the remote can also end the session with guac status 515 "Aborted"
  (guacd logs `Error handling message from VNC server.`); the evidence that it is the same VNC clipboard path is circumstantial
  (2026-09-30). Proof needs the I60 trace plus a raised guacd log level on a repro.
