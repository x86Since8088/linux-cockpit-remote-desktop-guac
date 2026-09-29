## 1.9.0.20260929 - 2026-09-29

Renames the relay's unix group from `edy-rdp` to `cockpit-guac-rdp` (matching the
project's own name), with a real migration so an already-deployed host — edt1,
today, with real members in the old group — does not silently lose access; adds an
automated test that locks in an existing property (non-admin group members already
have full access to most scenarios); and writes that access model down in one place
for the first time, along with an honest hardening analysis.

- **Rename.** Every place the group name is a literal — `install.sh`'s manifest
  (`RELAY_GROUP`), `relay/selfupdate.py`'s hand-kept-in-sync duplicate,
  `relay/edy_rdp_relay.py`'s `--group` fallback default, the three systemd unit
  files' `Group=`/`SocketGroup=` lines, `systemd/edy-rdp-tmpfiles.conf`'s GID
  column, and the legacy `pod/edy-rdp-pod.yaml` — now says `cockpit-guac-rdp`.
  Unit names, `/run/edy-rdp` paths, `/usr/libexec/edy-rdp`, every `EDY_RDP_*`
  env-var name (including `EDY_RDP_ADMIN_GROUP`/`EDY_RDP_SHADOW_GROUP`, whose
  *names* contain `EDY_RDP` but whose *values* are unrelated unix groups), and
  the nftables table names are all project identifiers, not the group, and are
  untouched. Prose in README.md and docs/ updated to match.
- **The migration that makes this safe.** A naive check-and-create
  (`getent group cockpit-guac-rdp || groupadd`) would have left an existing
  host's real `edy-rdp` group — GID and members intact — sitting unused while a
  brand-new, EMPTY `cockpit-guac-rdp` group got created, and every existing
  member would have silently lost access the moment the relay/sockets picked up
  the new group name on their next restart. `deploy.sh`'s `create_users()`
  (still gated behind `--with-users`, like every other host-mutating action in
  this script) now tries `groupmod -n cockpit-guac-rdp edy-rdp` — same GID, same
  members, nothing dropped — before ever falling back to a fresh `groupadd`,
  which now only happens when *neither* name exists (a genuinely new host). A
  plain `deploy.sh` run (no `--with-users`) cannot perform that rename itself —
  matching how this script never mutates the host without the flag — so it now
  warns loudly instead, if the old group exists and the new one does not yet,
  naming the exact `groupmod` command an operator needs before the next relay
  restart or unit reload.
- **New test:** `relay/test_edy_rdp_relay.py`'s `NonAdminAccess` proves, for the
  first time as an explicit assertion, that isolated / virtual monitor /
  wayland-vnc / greeter never raise `Refuse` for a non-admin, non-elevated uid —
  `ADMIN_ONLY_SCENARIOS` is exactly `{"console"}`, so reaching the relay (i.e.
  group membership) has always been the whole gate for these four. Nothing in
  the relay's behavior changed; this closes the gap that nothing in the test
  suite asserted it.
- **New doc:** `docs/GROUP-ACCESS-MODEL.md` states plainly what the group gate
  is necessary AND sufficient for, what needs more (console: always admin, plus
  `EDY_RDP_SHADOW_GROUP` when mirroring a different seated user; remote/vnc:
  an admin-populated `EDY_RDP_REMOTE_ALLOW`), the greeter scenario's specific
  risk (a member can attempt to sign in as any account the host knows, not just
  their own), and concrete operator hardening recommendations. README.md gets a
  short "Who the group actually admits" section pointing at it; the
  `usermod -aG $RELAY_GROUP <user>` banner in `deploy.sh`/`install.sh` now
  points there too, since on its own it reads as a complete instruction when it
  never was one.
- **Verification:** `run_tests.sh` green throughout (203 relay unit tests, up
  from 199; `install.sh --verify`'s manifest-completeness gate and the staged
  installer/deploy roundtrip tests unaffected).

## 1.8.1.20260929 - 2026-09-29

Fixes two real bugs in 1.8.0's shadow-group gate, both found by a multi-agent adversarial
review (four dimensions in parallel — seat-identity detection correctness, whether the
fail-closed design is actually fail-closed everywhere, config/deploy safety, test/doc
accuracy — each candidate finding independently re-checked by a skeptic on a different
model) before this ever reached edt1 or was pushed. 3 of 7 candidate findings confirmed; the
other 4 — including a claim that uid 0 unconditionally bypasses the gate — refuted (root
already has every capability this gate could restrict, and cannot log into this project's
Cockpit at all under its own shipped `disallowed-users` default).

- **`seated_uids()`'s per-session failure handling was exactly backwards for an
  authorization function.** It treated a `loginctl show-session` call that raised or
  returned non-zero the same as "that session doesn't exist" (skip and continue), copying
  `_active_graphical_sessions()`'s existing precedent for a narrow session-ended-mid-query
  race — but that precedent's function is cosmetic (a miscounted desktop-in-use tally),
  while this one decides who may watch whom. Reproduced: `list-sessions` reporting two real
  seated uids while every `show-session` call failed made the function return an EMPTY set
  instead of `None`, silently skipping the shadow-group check for an admin who was never
  actually verified against it — in precisely the situation the fail-closed `None` path
  exists to catch. Fixed: any `show-session` failure now fails the WHOLE call closed
  (`None`), not just that one session.
- **Two integration tests used uid 0 (root) to prove the gate correctly does not apply**
  when nobody else is seated or the requester is the one seated — but `is_admin()` exempts
  uid 0 unconditionally regardless of group, so those tests could not tell "the exemption
  logic worked" apart from "the gate ran and trivially passed because the caller is root." A
  mutation test proved it: hard-coding the gate to apply unconditionally still left the whole
  suite green. Fixed by switching both to a non-root admin uid with `is_admin()` mocked
  explicitly.
- **Verification:** `run_tests.sh` green throughout. A new `SeatedUidsSubprocessHandling`
  test class drives the real `seated_uids()` against a fake `subprocess.run` (every prior
  test monkey-patched `seated_uids()` itself away entirely, so this exact regression had zero
  coverage) — clean success, a greeter correctly excluded, and every categorical-failure mode
  asserted to return `None`. `relay/test_edy_rdp_relay.py` now has 63 tests (up from 55).

## 1.8.0.20260929 - 2026-09-29

New capability: a shadow-group gate for the console (mirror) scenario, on top of the
existing admin gate (I4), which is completely unchanged. Being a Cockpit administrator
already decides whether you may use the console mirror at all; it says nothing about
whether you may point it at a **different signed-in user's** active desktop rather than
an empty seat or your own. That is a genuinely separate privacy question, and this
release gives it its own, separately-provisioned answer.

- **The gate.** When a console connect targets a seat where a DIFFERENT uid than the
  requester is currently signed in, the requester must also be a member of a
  configurable unix group (`EDY_RDP_SHADOW_GROUP`, default `rdp-shadow`) — checked with
  the exact same `is_admin(uid, group)` primitive the admin gate already uses (it was
  already a generic group-membership check despite its name), reused as-is against a
  different group. Nobody seated, or the same user seated as the requester, needs
  nothing beyond the admin gate, exactly as before. Evaluated fresh on every console
  connect attempt, never cached, since who is seated can change between connects.
- **`seated_uids()` (new, `relay/edy_rdp_relay.py`)** answers "who, if anyone, is
  physically at the seat right now" via `loginctl list-sessions` + `show-session -p
  User`, built on a new pure classifier `_is_seated_graphical_session()` (active,
  graphical, seated, non-greeter). It is FAIL-CLOSED by design — returns `None`, not an
  empty set, when it cannot determine this at all — the deliberate opposite of the
  existing `physical_session_locked()`, which fails OPEN because it only relabels an
  opaque bridge error and must never block a connection. A new pure
  `shadow_gate_required(seated, requester_uid)` turns that into the actual yes/no
  decision, treating `None` as "cannot rule out someone else."
- **Fail-closed by default, and deliberately not host-validated for existence.**
  `rdp-shadow` is a brand-new, project-specific group name that will not exist on any
  host until an operator creates it. Unlike `EDY_RDP_ADMIN_GROUP` (which `lib/edy-rdp-
  env.sh` requires to already exist — `sudo` does, on essentially every real Linux
  host), `EDY_RDP_SHADOW_GROUP` is validated only for shape (empty, or a syntactically
  valid group name), never existence, and is deliberately left out of `install.sh`'s
  `REQUIRED_ENV` — the same precedent `EDY_RDP_REMOTE_ALLOW` already set. Refusing every
  install and routine redeploy (this project's own edt1 included) until an operator
  pre-creates a custom group would be a needless, deploy-breaking foot-gun; `is_admin()`
  already turns a missing group into "nobody is a member" with no crash risk, which is
  exactly the safe, fail-closed default this feature ships with. `.envdefault` ships it
  non-empty (`rdp-shadow`) so the gate is live on every fresh install; an operator may
  explicitly blank it in their own `.env` to turn this extra check off entirely and
  revert to admin-only console gating. The group itself is **not** auto-created by any
  tooling here — `groupadd rdp-shadow` + `usermod -aG rdp-shadow <user>` (or pointing
  the variable at an existing group) is an operator's own, deliberate step.
- **Threaded exactly like `EDY_RDP_ADMIN_GROUP`:** `.envdefault` → `Environment=` +
  `--shadow-group` in `systemd/edy-rdp-relay.service.in` → `--shadow-group` (argparse,
  default `rdp-shadow`) in `edy_rdp_relay.py`'s `main()` → `handle()`'s args tuple →
  `Connection.__init__`'s `self.shadow_group`, consumed by `is_admin(self.uid,
  self.shadow_group)`.
- Documented in `README.md` (Configuration) and `docs/SCENARIOS.md` (extends the
  existing Console section); `docs/KNOWN_ISSUES.md` I50 records the design reasoning in
  full, including why `seated_uids()`'s fail-closed posture must not be "fixed" to match
  `physical_session_locked()`'s deliberately different fail-open one.
- **Verification.** `relay/test_edy_rdp_relay.py`: `SeatedSessionPredicate` and
  `ShadowGateDecision` exercise the two new pure functions directly with literal
  fixtures (no subprocess, same style as the existing `LockedScreenHint`);
  `ConsoleShadowGate` drives the real `_peek_scenario_from_connect` end to end with
  `seated_uids()` monkey-patched (same style already used for `R.bridge.start_bridge`),
  covering nobody-seated, same-user-seated, a-different-uid-seated with and without
  shadow-group membership, the `None` fail-closed path with and without membership, and
  `EDY_RDP_SHADOW_GROUP=` empty disabling the gate. `run_tests.sh` green throughout (187
  relay unit tests across all four suites, up from 175 (12 new); the existing admin gate
  and every other suite are unaffected — same wording, same code path, no regression).

## 1.7.1.20260929 - 2026-09-29

Fixes five real defects in 1.7.0's self-update feature, all found by a multi-agent
adversarial review of that feature (four dimensions in parallel — supply-chain/code-
execution safety, rollback/health-check correctness, admin-gate/API conformance,
deploy-manifest completeness + UX — each candidate finding then independently
re-checked by a skeptic on a different model) before any of it reached edt1 or was
pushed. 5 of 10 candidate findings were confirmed real; the other 5 — including a
"critical"-labelled tar-extraction symlink bypass — were checked against the actual
code, reproduced or disproved concretely, and refuted (the symlink-bypass claim was
real as a code-level flaw in the pre-3.12 fallback, but not reachable via a genuine
GitHub-generated tarball: a git tree cannot hold both a symlink entry and a file entry
nested under the same name; hardened anyway as defence in depth, see below).

- **No mutual exclusion between apply and rollback (high severity).** An admin
  clicking "Roll back" while "Update now" still looked slow enough to be stuck (a
  realistic scenario — apply can take up to 300s) started a SECOND privileged oneshot
  unit racing the first one's swap of the SAME `payload` symlink and its restart of the
  SAME relay unit. Reproduced: two processes racing the real `swap_payload_and_install
  ()` lost the payload symlink update on roughly half of 20,000 stress-test iterations.
  Fixed with `relay/selfupdate.exclusive_run()` — a non-blocking `flock()` on
  `<install-root>/.selfupdate.lock`, held for the ENTIRE apply/rollback run by both
  privileged scripts; the second script to try exits immediately with a new exit code
  6 ("already in progress") rather than queuing behind the first, since queuing would
  mean the recovery action silently waits minutes behind whatever it was trying to
  recover from. `swap_payload_and_install()` also now uses a per-process-unique temp
  symlink name (`payload.new.<pid>`, not one fixed name) as defence in depth on top of
  the lock, matching `deploy.sh`'s own versioned `$NEW.tmp` convention.
- **Self-contradictory diagnostic on the worst-case exit path (medium).** When the
  automatic rollback's OWN payload swap succeeded but the relay still failed its health
  check afterward (e.g. crash-looping for an unrelated reason), the recorded message
  called that successful swap "also failed", gluing the SUCCESS string returned by
  `swap_payload_and_install()` into a sentence claiming failure — and separately
  captured `restart_err` (if the rollback's own restart command failed) but never
  actually included it anywhere an operator could see it. This is exactly the "a human
  is needed right now" triage path, so the misleading text mattered most exactly when
  it was read. Fixed: `edy-rdp-selfupdate-apply.py` now distinguishes three genuinely
  different failure modes (swap itself failed / swap ok but restart failed / swap and
  restart ok but health check still failed) and reports each with its own accurate text.
- **Rollback's refusal message collapsed "none" and "ambiguous" (low).** A host with
  more than one older `payload-<version>` directory on disk (raised `KEEP`, or a host
  where `install.sh`/the image pull failed mid-deploy before `deploy.sh`'s own pruning
  ran) got told "no earlier version is available" — factually wrong, and it hid the
  actually actionable fix (remove the extra directory). Fixed: `SelfUpdate.rollback()`
  now returns a distinct, accurate message for `none` vs. `ambiguous` vs. a missing/
  broken `payload` symlink, instead of one generic string for all three.
- **"No releases published yet" rendered as a bold red error (medium).** This
  repository genuinely has no GitHub Releases yet (see `docs/SELFUPDATE.md`), so this
  is the exact state every install sees on day one — but it shared the same untyped
  `check_error` field as a real GitHub outage, and the frontend styled ANY `check_error`
  in bold `--err` red. An administrator opening the brand-new Update tab on this very
  repo saw a scary-looking error for a state that is completely expected. Fixed: a new,
  typed `no_releases` boolean (not a string match) lets the frontend render it as a
  calm informational line instead.
- **Zero test coverage for the actual extraction path (low, but the fix it enabled was
  not low).** `relay/test_selfupdate.py` had no test touching `_safe_extract()` or
  `fetch_and_extract_release()` at all — the single function that runs, as root,
  against internet-fetched content. Writing that coverage immediately surfaced a real
  bug this pass had not otherwise caught: on this host's actual Python (3.14, which
  DOES have `filter="data"`), a path-traversal tarball raises `tarfile
  .OutsideDestinationError` — a plain `tarfile.TarError`, not `SelfUpdateError` — which
  `_safe_extract()` only caught as `TypeError` (its signal for "no `filter=` support")
  and so let propagate uncaught, meaning the privileged script would have crashed with
  a raw traceback (exit 1, unclassified) instead of the intended, accurate "fetch/
  extract failed, nothing on this host was touched" (exit 3). Fixed by catching
  `tarfile.TarError` explicitly and wrapping it as `SelfUpdateError`. Also hardened the
  pre-3.12 manual fallback to reject any symlink/hardlink member outright (the
  refuted-but-real flaw noted above: its realpath containment check cannot see a
  not-yet-extracted symlink, so a symlink member followed by a file nested under it
  could pass the check and get written through the symlink on an unpatched
  interpreter) — unreachable via a real GitHub tarball per the refutation above, but
  cheap, correct, and removes the "looks exploitable until you check git's tree model"
  ambiguity for any future reader.
- **Verification:** `run_tests.sh` green (`node --check` clean; 160 relay unit tests,
  82 of them in `test_selfupdate.py` alone, now including `SafeExtract` — happy path,
  `../` traversal on both the real `filter="data"` path and a forced pre-3.12 fallback,
  and the symlink-through-fallback case as a reproduction of the refuted "critical"
  finding — `ExclusiveRunTest`, exit-code-6 mapping for both apply and rollback, the
  ambiguous-vs-none message distinction, and the `no_releases` flag's cache round trip).

## 1.7.0.20260929 - 2026-09-29

New capability (I49): the plugin can now check this project's own GitHub repository
for a newer tagged Release than what is installed, and apply it — with AUTOMATIC
rollback if the newly-installed version fails a post-restart health check. This entry
covers the **backend control-API half** only (relay + privileged units + polkit +
deploy manifest + docs + tests); the Update tab itself (the Cockpit-facing UI) is a
separate piece built against the contract documented below and in `docs/SELFUPDATE.md`.

- **Why GitHub, never local git:** a deployed host has no git repository at all —
  `deploy.sh`'s own `copy_declared_payload_into()` explicitly excludes `.git/`, `docs/`,
  `deploy.sh` itself, `CHANGELOG.md` and `README.md` from what ships into
  `/opt/cockpit-guac-rdp/payload-<version>/`. So "check for updates" goes through the
  GitHub API, and "apply" means fetching a fresh copy of the repo tree at a tag (which
  DOES include `deploy.sh` — that exclusion is `deploy.sh`'s own packaging step, not
  something present in a tagged tree) and re-running **that** `deploy.sh` against the
  existing install root, reusing its payload-swap/`.env`-reconcile/preflight logic by
  invoking it rather than reimplementing it. Python stdlib only for all of it
  (`urllib.request`, `json`, `tarfile`, `hashlib`, `socket`, `subprocess`) — this
  project's own stated philosophy ("relay/reaper are stdlib Python 3, no PyPI
  dependencies") and `requires.txt` pin no `curl`/`jq`/`git`, so none were added.
- **New module `relay/selfupdate.py`** (imported by `edy_rdp_relay.py` exactly like
  `session_registry.py`/`control.py`/`bridge.py` already are): version parse/compare for
  this project's `maj.min.patch.YYYYMMDD` scheme; the GitHub `releases/latest` call;
  atomic cache read/write to `/run/edy-rdp/update-status.json` (write-to-temp-then-
  `os.rename`, chowned back to `edy-relay:edy-rdp` since both the unprivileged relay and
  the ROOT-run apply/rollback scripts write it); tarball fetch+extract guarded against
  path traversal (`extractall(..., filter="data")` on Python 3.12+, a manual per-member
  containment check on the 3.9–3.11 this project's `requires.txt` also supports); the
  health check (`systemctl is-active` + a real `{"op":"ping"}` round-trip on the control
  socket, retried ~20s); and the `SelfUpdate` class (mirroring `DesktopUI`'s shape) that
  `relay/control.py` calls through injection.
- **Four new control-socket ops** — `update-status`, `update-check`, `update-apply`,
  `update-rollback` — wired into `handle_control()` via a new injected `selfupdate=`
  parameter, following the exact contract in `docs/SELFUPDATE.md`. Status/check are
  read-only for any authenticated caller (status never blocks on GitHub's latency; check
  forces a live call, server-side rate-limited to 60s). Apply is admin-gated PLUS a
  typed-hostname confirmation (same pattern as the Desktop UI tab's `stop`/`disable`);
  rollback is admin-gated with NO confirmation (this project's convention: the recovery
  action stays low-friction, the disruptive one carries the confirmation). Neither op
  ever trusts a caller-supplied version — apply re-validates against the relay's own
  cache, and the privileged script re-validates AGAIN against a fresh GitHub call before
  touching anything.
- **Two new privileged units, deliberately NOT templated:** `edy-rdp-selfupdate-apply
  .service` and `edy-rdp-selfupdate-rollback.service` take no `%i`, no instance argument
  at all — one step past this project's existing `%i`-templated pattern
  (`edy-rdp-deskui@`, `edy-rdp-unlock@`), because it means **zero** caller-influenced
  data crosses the `systemctl start` privilege boundary: "apply" always means "whatever
  the script's own fresh GitHub call says is latest", "rollback" always means "the one
  non-current `payload-<version>` directory on disk, refuse cleanly if that isn't
  exactly one". Both added to the SAME polkit rule (`hardening/edy-rdp-headless.rules`)
  that already whitelists `edy-relay`, matched by exact unit name (not a prefix, since
  they are not templated).
- **A real, easy-to-miss `deploy.sh` gotcha, handled explicitly:** `deploy.sh` run with
  no `--with-units` flag still has `install.sh` render unit files whenever the layout is
  a deployed one (unconditional there, not gated by `--with-units` — verified against
  `do_install()`'s actual skip condition), and `install.sh` itself already calls
  `systemctl daemon-reload` in that same branch. `edy-rdp-selfupdate-apply.py` calls
  `systemctl daemon-reload` again anyway, immediately after `deploy.sh` returns and
  before restarting the relay, as explicit defense in depth — documented in
  `docs/SELFUPDATE.md` as normally a harmless repeat rather than the only thing standing
  between a changed `edy-rdp-relay.service` unit and it taking effect.
- **`edy-rdp-guacd.service` is never restarted by this feature** — only
  `edy-rdp-relay.service` is. Restarting `guacd` drops every live RDP screencast, and a
  `guacd`/container restart has always been a deliberate, separate, explicitly-requested
  action in this project. A version bump that also needs a new `guacd` image is
  documented as out of scope for the automatic path, not silently mishandled.
- **New `.envdefault` key `EDY_RDP_UPDATE_REPO`** (default: this project's own GitHub
  `owner/repo`), validated by a new case in `lib/edy-rdp-env.sh`'s `env_check_values()`.
  Deliberately no enable/disable flag for this feature (by product decision, checking
  and applying are available to any Cockpit admin by default) — only the repo location
  is configurable.
- **install.sh's manifest** gained `relay/selfupdate.py`, the two new privileged scripts
  (`selfupdate/edy-rdp-selfupdate-{apply,rollback}.py`, installed as
  `edy-rdp-selfupdate-{apply,rollback}` in `/usr/libexec/edy-rdp`) and the two new unit
  names — a file left out of this manifest is a file that silently never ships, so this
  was checked against `install.sh --verify`'s own completeness gate, not just eyeballed.
- **Docs:** new `docs/SELFUPDATE.md` (architecture, the exact control-op contract, the
  exit-code enums, and an explicit TRUST MODEL section — this verifies TLS to
  `api.github.com`/`codeload.github.com` and nothing more; there is no code-signing or
  GPG verification of the fetched tarball in this pass, named as a known limitation in
  the same spirit as this file's other "OPEN (deferred)" entries, not hidden behind a
  fake verification step). `docs/KNOWN_ISSUES.md` I49 (a new-capability entry, following
  the precedent set by I47). `README.md` gained `EDY_RDP_UPDATE_REPO` in the settings
  section. Also noted plainly, in both new docs: **this repository has no GitHub
  Releases or tags yet** as of this writing (`gh release list` and `git tag --list` both
  empty, verified this session) — so `update-status` will show `update_available: false`
  / `latest_version: null` on every host until the maintainer cuts the first tagged
  Release. Expected, not a bug.
- **Tests:** new `relay/test_selfupdate.py` — version parse/compare across
  equal/older/newer/malformed input (malformed never crashes and never reports an update
  available), the cache read/write round trip and its TTL staleness decision, the
  rollback-candidate selection logic (none / exactly one / more-than-one-is-ambiguous-
  refuse), and `relay/control.py`'s exit-code-to-response mapping for all four ops
  including every refusal path (not admin, bad confirm, nothing to apply, rate-limited).
  Added to `run_tests.sh`'s existing relay-unit-test line. No test in this pass hits the
  real network — `urllib`/`subprocess`/socket are mocked throughout, matching this
  project's existing test philosophy.
- **Verification (backend/control-API half):** `run_tests.sh` green, including
  `install.sh --verify`'s pre-flight (both new units render with no leftover
  placeholder, and every `LIBEXECDIR` reference they carry resolves to something the
  manifest installs) and the staged `DESTDIR` install-to-completion roundtrip in
  `tests/installer_tests.sh`. Not live-tested against a real tagged Release on edt1 in
  this pass — none exists yet on this repository, per the note above — nor is there a
  Cockpit "Update" tab to click yet; that UI half lands as a follow-up to this same
  entry, against the contract documented in `docs/SELFUPDATE.md`.
- **Frontend follow-up (same entry): the "Update" tab.** A new tab, alongside Connect/
  Active Sessions/Desktop UI/Self Tests, reads exactly against the control-op contract
  above (`update-status` on tab-open, `update-check`/`update-apply`/`update-rollback` on
  their buttons — no new polling timer in the browser). Shows current/latest version,
  the release name and a release-notes link when present, when the host was last
  checked, and — read verbatim from `check_error` rather than paraphrased — the exact
  "no releases published yet for `<repo>`" wording `docs/SELFUPDATE.md` documents for
  this repository's own current bootstrap state (no Releases cut yet). "Update now" is
  admin-gated and disabled until `update_available` is true, then needs the operator to
  type this host's name to confirm — built as a direct sibling of the Desktop UI tab's
  existing Stop/Disable confirmation UX (`#deskui-confirm-wrap`/`deskuiSyncButtons()`),
  down to the copy style. "Roll back" is admin-gated but needs no typed confirmation, per
  the contract's own stated asymmetry (recovery stays low-friction; the disruptive verb
  carries the confirmation). One wire-contract wrinkle worth flagging: unlike
  `deskui-status`, `update-status`/`update-check` never carry this host's name (only
  `update-apply`'s `need_confirm` refusal does) — `renderUpdate()` borrows the read-only,
  non-admin-gated `deskui-status` op's `hostname` field as the confirmation label instead
  of guessing or adding a new op, since both controllers derive it identically
  (`socket.gethostname()`, same relay process); the relay re-derives and checks its own
  value regardless of what the label shows. `last_apply`'s outcome (e.g. "Update to
  1.7.0.20260929 failed its health check and was automatically rolled back to
  1.6.1.20260929") is surfaced as its own persistent status line, not the auto-dismissing
  `showToast()` introduced in I48 — that component is for one-off events the panel did on
  its own, and both an available update and a recorded apply/rollback outcome are ongoing
  host STATE that should stay visible until the operator deals with it, so the "Update"
  tab also carries a small persistent badge dot (`#update-badge`, styled in
  `guac-rdp.css` from this project's existing `--panel`/`--ink`/`--line`/`--err` tokens,
  no new colors), refreshed from the same `update-status` reads rather than a
  browser-side timer of its own. **Verification:** a scratch jsdom smoke test (same
  ad hoc, throwaway approach as I47/I48 — not a repo dependency) loads the real
  `index.html` + `guac-rdp.js` with `cockpit`'s channel/permission plumbing stubbed and
  exercises the actual DOM: current/latest version and the release-notes link render;
  the bootstrap "no releases published yet" wording renders verbatim; the badge tracks
  `update_available`; "Update now" stays disabled with no confirmation typed (even with
  an update available), enables only once the typed value matches the host name, and
  never fires `update-apply` before `update_available` is true; "Roll back" fires with
  no `confirm` field at all; a non-admin never sees either button become clickable; and
  `last_apply`'s outcome text is shown/hidden correctly. `node --check guac-rdp.js` and
  `./run_tests.sh` both green (the latter re-runs the untouched Python/relay half too).

## 1.6.1.20260929 - 2026-09-29

Fixes three accessibility bugs in 1.6.0's new toast, all found by a multi-agent adversarial
review of that commit before it ever reached edt1 (four independent dimension reviews --
control-flow, admin-gate security, toast UX/accessibility, test coverage -- each candidate
finding then independently re-checked by a skeptic on a different model). 3 of 11 candidate
findings were confirmed real; the other 8, including a claimed relay-side admin-gate gap on
the `greeter` scenario, were checked against the actual code and refuted (see the review
transcript referenced in this commit for the reasoning on each).

- **Toast was inert -- not just dimmed -- while the Session… card is open.** 1.6.0's own
  comment said a toast firing while that `<dialog>` is open would render "dimmed behind the
  `::backdrop`", same as `#status`. That undersold it: `showModal()` makes everything OUTSIDE
  the dialog *inert* per the HTML spec -- removed from the accessibility tree entirely, not
  merely dimmed -- and Connect lives inside that dialog, so the ordinary path (open Session…,
  pick Console, click Connect) left the fail-over toast silently unannounced to assistive
  tech, for the one message this whole feature exists to convey. Confirmed with a real
  headless-Chromium accessibility-tree dump (`Accessibility.getFullAXTree` with/without the
  dialog open). Fixed: `showToast()` now reparents `#toast` into whichever `<dialog>` is
  currently open (back to `<body>` once none is) -- `position:fixed` keeps it viewport-
  anchored regardless of DOM parent, so this also fixes the visual dimming as a side effect.
- **Auto-hide left stale text in the accessibility tree indefinitely.** The 5s timer only did
  `classList.remove("show")`, which drives `opacity:0` -- and an `opacity:0` element stays in
  the accessibility tree and gets re-encountered by anyone browsing the page linearly (screen
  reader browse mode, "read from here"), with nothing marking it as dismissed. Fixed: toggle
  `aria-hidden` on hide/show, which actually removes/restores the node from the tree.
- **The first toast of a page load never faded in.** `showToast()` created the element,
  appended it, and set the `.show` class in one synchronous run with no forced reflow in
  between -- the browser had no earlier committed style to transition FROM, so it collapsed
  both changes into one and the toast just appeared at full opacity. Every later reuse of the
  same (already-painted) element faded correctly; only the very first one in a session did
  not. Fixed with a single `el.offsetWidth` read right after the element's first creation.
- **Verification:** `run_tests.sh` green, `node --check` clean. A small ad hoc jsdom check
  (scratch project, not a repo dependency, deleted after use) that extracts the real
  `showToast()` block verbatim -- same technique `tests/js/keyboard_remap.test.js` already
  uses for its own TESTHOOK block -- confirmed: reparenting into an open `<dialog>` and back
  to `<body>` on close, `aria-hidden` clearing on show and being set on hide, and the forced-
  reflow line running without error. Not re-tested live on edt1 beyond what 1.6.0 already
  covers -- these are additive fixes to the same code path.

## 1.6.0.20260929 - 2026-09-29

Connecting to the Console (mirror) while nobody is signed in on the physical
seat now switches itself to the Login screen (greeter) instead of dialling a
mirror that has nothing to show, and says so with a small transient toast.
Locked-seat handling is unchanged.

- **The problem (I48):** the console scenario is a live `mirror-primary`
  screencast of the seat's per-user desktop. Before anyone has logged in
  locally there IS no desktop for grd to mirror -- the only thing that can
  render pre-login is the GDM greeter, in a session of its own (the existing
  comment in `enterSeatMode()` already spelled this out). So a console connect
  on a freshly booted host could only ever fail, and it failed opaquely (a
  bridge transport error, or nothing listening on :3389 at all). 1.5.0 gave
  the pop-out a "Session…" card precisely so a user could recover from this
  by hand -- pick `greeter`, sign in, switch back -- but the first hop was
  still a dead end the user had to diagnose themselves. This is a DIFFERENT
  case from the existing `LOCKED_SEAT_RE` path (I38/I39): there, a session
  exists and is worth resuming, which is exactly why that path deliberately
  does NOT redirect to the greeter (a greeter login starts a NEW session, it
  cannot attach to the locked one). With zero local logins there is no
  session to preserve, so switching loses nothing.
- **The fix (`guac-rdp.js`, `resolveConsoleFallback()`):** `connect()` now
  resolves the effective scenario BEFORE dialling out. For `console` only, it
  asks the relay's existing read-only `deskui-status` control op (the same one
  the Desktop UI tab uses; not admin-gated) for `active_graphical_sessions` --
  server-side that is "active, graphical, seated, non-greeter sessions right
  now", so `0` means nobody is locally logged in. On an explicit `0` it flips
  the Session selector to `greeter`, runs `refreshUi()` so the dropdown and
  hint visibly reflect it, shows the toast, and connects to the greeter --
  a seamless fail-over, not a message-and-stop. Anything else (a count > 0,
  a control error, a channel that will not open, a missing field, or no
  answer within 4s) proceeds with `console` exactly as before: the probe
  FAILS OPEN, mirroring the relay's own `physical_session_locked()`, and can
  never block a normal console connect. Because every caller funnels through
  `connect()` -- the Connect button, `enterSeatMode()`'s auto-connect and the
  seat pop-out's monitor-picker reconnect -- all three get it without being
  special-cased, and it is scoped strictly to `console` (`virtual` and every
  other scenario never probe). No re-entry is possible: the resolved
  `greeter` key goes to the split-out `connectAs()`, which never calls
  `connect()`; a later Sound/Resolution reconnect uses `activeKey`, which is
  now `greeter`. No relay/control code changed -- the op already existed.
- **The toast (`showToast()`, `#toast` in `guac-rdp.css`):** this codebase had
  no transient notification at all -- only the persistent `#status` line,
  which is the wrong vehicle for "I did something on your behalf" (it reads
  as the current connection state and is overwritten by the next status a
  moment later). `showToast(msg, kind)` lazily creates one `#toast` div
  (`role="status"`, `aria-live="polite"`, `pointer-events:none`), bottom-
  centre, styled with the same `--panel`/`--ink`/`--line` surface as the
  Session… card, faded in/out via an opacity+transform transition and
  self-dismissed after 5s (a second toast resets the clock rather than
  fighting the first). Deliberately just that one function -- no queue, no
  positions, no options. Known and accepted: like `#status`, it lives outside
  the Session… `<dialog>`, so if it fires while that modal is open it renders
  dimmed behind the `::backdrop` (the browser's top layer beats any z-index);
  consistent with how `#status` already behaves there, and not worth a second
  modal to fight.
- **Copy:** the "Connected…" status had no case for `greeter` and fell through
  to "Connected to your virtual monitor." -- now more likely to be seen, since
  the fail-over lands people there without them having picked it. It now
  reads "Connected to the sign-in screen." Also dropped a stale comment at the
  top of `connect()` describing a one-shot locked-seat re-arm that no longer
  exists in the code.
- **Verification:** `run_tests.sh` green (Python untouched; `node --check`
  clean). A DOM-level smoke test (ad hoc jsdom, same approach as 1.5.0 -- a
  scratch npm project, not a repo dependency; the real `index.html` +
  `guac-proto.js` + `guac-rdp.js` with `cockpit` and `Guacamole` stubbed just
  far enough to drive `connect()` through registration, the admin challenge,
  gate-key fetch and `start()`) asserted on the `scenario=` marker in the
  wire-level `connect` instruction the tunnel actually sends, not on an
  intermediate variable: 0 sessions -> selector `greeter`, hint refreshed,
  toast present with the expected text/role/aria-live and hidden again after
  ~5s, `scenario=greeter` on the wire, exactly one probe; 1 session ->
  `scenario=console`, no toast; control channel closing with a problem, OR
  `cockpit.channel()` throwing synchronously, OR never answering (timeout)
  -> all `scenario=console`; `virtual`/`greeter` never issue the probe; the
  `#seat` pop-out's auto-connect takes the same fail-over; and the greeter
  "Connected…" copy. Not live-tested against a real Cockpit/relay session in
  this pass -- deploy to edt1 and confirm on a freshly booted seat.

## 1.5.0.20260929 - 2026-09-29

The full connect controls (Session, Sign-in, Resolution, Scale, Clipboard,
Sound, Connect/Disconnect) now live in a single "Session…" modal, used
consistently on the main Connect panel AND both pop-out types (Pop-out / Add
Monitor) -- decluttering the always-visible bar and, for the pop-outs, making
each one able to pick its own session and reconnect entirely independent of
the tab it was opened from. Main-panel tabs also now reflect in the URL.

- **The pop-out problem:** a pop-out is a genuinely separate page load
  (`window.open` to the same URL with a different hash, not a shared JS
  context with the opener), so it was never actually TIED to the opener tab in
  the code -- but it had no UI to use that independence. `enterSeatMode()`/
  `enterMonitorMode()` only exposed a small fixed subset of controls (a
  monitor picker, Sound) and hardcoded the scenario (`console` / `virtual`) at
  open time, with no way to change it short of closing the window. Concretely,
  reported against a fresh boot with nobody logged into the physical seat:
  Pop-out (hardcoded to the `console` mirror, which needs an active per-user
  desktop session on :3389) can't connect until someone logs in via the GDM
  greeter -- and once logged in, if the connection carrying that greeter/login
  is later disconnected from the main tab, the pop-out's mirror session drops
  too. The exact mechanism wasn't nailed down live (worth confirming against
  this project's own documented grd/lock-screen interaction: a disconnected
  RDSTLS/greeter-handover connection plausibly locks the physical seat, and a
  locked seat is already known to make grd kill any active screencast -- see
  I39a), but the practical problem is the same either way: the pop-out had no
  way to recover or switch to a different scenario without the opener tab.
- **The fix** (`guac-rdp.js`, `buildSessionCard()` + `addSessionButton()`): a
  "Session…" button opens a modal (a native `<dialog>` -- this project has no
  modal component of its own, and `<dialog>`/`showModal()` IS the universal
  one, giving backdrop dimming, Escape-to-close and focus handling for free)
  holding the FULL connect controls -- Session target (+ host/port for
  Remote/VNC), Sign-in mode + credentials, Resolution, Scale, Clipboard,
  Sound, and Connect/Disconnect. Every field keeps its existing id and event
  listener (`target`/`authmode` change -> `refreshUi()`; Connect/Disconnect ->
  `connect()`/`teardown()`; the generic `URL_CONTROLS` hash/localStorage
  persistence) -- this only REPARENTS the existing DOM nodes into the modal,
  it does not duplicate or rewire any connect logic. A pop-out can now,
  entirely on its own: try `console`, fail because nobody's logged in yet,
  switch to `greeter` to reach the GDM login screen, and once logged in switch
  back to `console` -- all without the tab it was opened from. The SAME modal
  is now also used on the main Connect panel (`enterConnectMode()`), leaving
  its bar with just the "Session…" button plus quick-access action buttons
  (Num Lock, Add Monitor, Pop-out, Send/Receive clip).
- **Tabs reflect in the URL** (`selectTab()`): the active Connect-panel tab
  (Connect / Active Sessions / Desktop UI / Self Tests) is now written to the
  URL hash as `tab=<name>` via the same `replaceState` pattern `URL_CONTROLS`
  already uses (no navigation, no history spam), and restored on load --
  bookmarkable/shareable, and a refresh no longer snaps back to the Connect
  tab.
- **The tab/URL sync didn't actually move the visible address bar** in a real
  Cockpit session, caught by the user live: `history.replaceState()` changes
  this document's own `location.hash`, but it does NOT fire a `hashchange`
  event (only a real hash-navigation does). Decompiling the installed
  `/usr/share/cockpit/base1/cockpit.js` confirmed Cockpit's shell-sync --
  mirroring the embedded page's location into the browser's actual address
  bar over the iframe<->parent "cockpit1" transport -- runs entirely off a
  `window.addEventListener("hashchange", ...)` listener. Without firing that
  event ourselves, `replaceState` silently updates the iframe's own internal
  hash while the visible URL never moves. New shared `writeHash()` keeps
  `replaceState` (still no history-spam) and additionally dispatches a
  `hashchange` event by hand; both `selectTab()` and the pre-existing
  `saveControls()` (Session/Resolution/Scale/Clipboard/Sound persistence) now
  go through it -- the latter had the exact same silent gap since before this
  release, just never reported.
- **Verification:** `run_tests.sh` green (no Python/shell logic touched). A
  DOM-level smoke test (ad hoc, via jsdom against the real `index.html` +
  `guac-rdp.js` -- not part of the repo's own test suite, which uses
  Playwright against a live Cockpit instead; jsdom does not implement
  `HTMLDialogElement.showModal`/`close` at all, so those two were stubbed to
  just toggle the `open` attribute, enough to verify this code's own wiring,
  not the browser's native rendering) confirmed, for `#seat`, `#monitor` AND
  the plain page: the dialog and button are created and correctly parented,
  all ten fields plus Connect/Disconnect end up inside it, clicking the
  button/close-button/backdrop (a click landing on the `<dialog>` element
  itself rather than its content, the standard idiom) opens/closes it
  correctly, a click on a field inside does not close it, `refreshUi()`'s
  existing show/hide logic still works on the reparented elements, and the
  tab/URL sync round-trips (a `#tab=sessions` URL restores to that tab on
  load; clicking a different tab updates the hash AND fires a `hashchange`
  event, simulating the listener Cockpit's shell registers, confirming it
  would actually notice). Not live-tested against a real Cockpit/relay
  session in this pass -- deployed to edt1 for the user to verify live before
  merging; this specific gap (URL updates internally but the browser's visible
  address bar doesn't move) is exactly what a jsdom-only pass can't catch on
  its own, since jsdom has no Cockpit shell to fail to notify -- it took the
  user's live report to surface it.

## 1.4.2.20260928 - 2026-09-28

Fix (I45): typing "<" sent ">" to the guest. The fix generalizes to every
digit/punctuation key and is international-keyboard-safe -- an independent
adversarial review caught that a first pass at this fix (Shift-only, five
hardcoded keys) was itself not layout-safe, and a live check exposed a
follow-on state-desync bug in that pass's synthetic-Shift bookkeeping; this
entry describes the corrected version that shipped.

- **Root cause**, reproduced live against a throwaway Xvfb with
  `x11vnc -debug_keyboard`: the bridge runs `x11vnc -nomodtweak`, which never
  adds or removes an X11 modifier itself -- it resolves a keysym to a keycode
  the same way Xlib's `XKeysymToKeycode` does (lowest shift-level column, tied
  broken by lowest keycode) and presses that keycode as-is, trusting whatever
  modifier the browser already holds. The Xvfb "us" keymap defines an ISO-only
  compat key (keycode 94, no physical existence on a real US keyboard) as
  `[less, greater, bar, brokenbar]`; `less`'s lowest-column location is that
  key's UNSHIFTED level. A US client always holds real Shift to type "<", and
  Shift + that same keycode's level 1 is "greater" -- so "<" silently arrived
  at the guest as ">".
- **Why the first fix attempt wasn't enough (caught before merge):** an
  independent review agent pointed out that forcing Shift ON for
  parenleft/parenright/less/greater/bar (mirroring the existing
  parenleft/parenright fix) only handles clients that hold Shift for FEWER
  keys than the Xvfb "us" keymap expects. It doesn't handle the mirror image:
  a client that holds Shift for a key the Xvfb keymap needs UNSHIFTED --
  French AZERTY holds Shift for every digit, German holds Shift for ".". That
  is the exact same bug, reversed, and hits far more characters. The reviewer
  also found a real desync in the original bookkeeping (an overlapping real
  Shift press could be incorrectly released on a remapped key's keyup) and a
  separately-ambiguous numpad-decimal keycode (I46, deferred).
- **Fix** (`guac-rdp.js`, `KEYCODE_FIX` + `SHIFT_LEVEL` + `sendGuestKeyEvent`):
  two independent corrections, computed once from the Xvfb "us" keymap
  (verified against a live dump, not guessed):
  - `parenleft`/`parenright`/`less` are genuinely ambiguous keysyms (Xlib's
    rule picks a keycode xfreerdp3 can't scancode, or one that collides with a
    held Shift) and get substituted to their one other, unambiguous, always-
    scancode-able location: digit 9/0, comma.
  - Every digit and ASCII punctuation keysym (not letters -- unshifted-lower /
    shifted-upper is universal across every layout) gets its Shift state
    forced to match what the Xvfb keymap needs for THAT keysym, regardless of
    what modifier the client's layout used to produce it: added when missing,
    or SUPPRESSED when the client's real Shift doesn't belong there. Only
    digits/punctuation are managed, so Ctrl+Shift/Alt+Shift combos on letters,
    Tab, arrows, etc. -- the reason `-nomodtweak` was chosen in the first place
    -- are completely untouched.
  - The add/remove is undone on keyup checked against the CURRENT real Shift
    state, not the state recorded at keydown, so a real Shift press/release
    that happens to overlap a managed key's hold is never fought or clobbered
    (this is the desync the reviewer found and it is now closed). State is
    also reset on `teardown()` so a mid-press disconnect can't leak into the
    next session on the same page.
- **Verification:** live end-to-end against a real throwaway Xvfb +
  `x11vnc -nomodtweak -debug_keyboard` for both directions (Shift added for a
  no-Shift client input, and Shift suppressed+restored for a Shift-holding
  client input landing on an unshifted target) -- confirmed the actual
  `XTestFakeKeyEvent` ordering at the X11 level, not just the JS call
  sequence.
- **Tests:** `tests/js/keyboard_remap.test.js` (new, run via `run_tests.sh`)
  loads the actual shipped remap block (via the `TESTHOOK:KEYREMAP` sentinels
  in `guac-rdp.js`) into a sandbox and covers both Shift directions, the
  overlapping-real-Shift desync scenario, key-repeat, mid-press client loss
  and its `teardown()` reset, and the pre-existing Meta/Mac-Option remaps.

## 1.4.1.20260927 - 2026-09-27

Docs: the relay defence-layer design, and the CVE register corrected where the
review proved it wrong. No code change.

- `docs/DEFENSE-LAYER.md` (new): output filtering, sanitisation of RDP/guac
  secrets that never need to leave the host, and decoy identifiers that trigger
  security events - three layers on the relay's re-encode choke point, 22
  controls each stated after an adversarial critic's repair, a zero-false-
  positive decoy scheme, the event trust contract, an observe-first rollout with
  a runtime kill-switch, and 16 completeness gaps. Section 4 lists thirteen
  defects present today independent of guacd's version (connect-parameter
  passthrough, no `select` pin, `--allow-target` never invoked, `any:*` reaching
  the password-less qemu VNC consoles, gate/door credentials round-tripping
  through the browser, group-readable bridge/headless credential files).
- `docs/CVE.md`: guacd is a VNC client here, so CVE-2023-43826's class is in
  path (was "not applicable / RDP-only"); the reverse-RDP surface is `xfreerdp3`
  on the host, not guacd; the live image is Janua 1.0.1 = guacd 1.6.0 +
  FreeRDP 3.10.3, which closes all five named CVEs by version.

## 1.4.0.20260927 - 2026-09-27

Installer contract: .env is placed and validated by install.sh, prerequisites have one
source, the relay bootstraps its interpreter at start, and the audio bind survives boot.

- **The silent abort (I41).** Since 1.3.0 no install, deploy or `--verify` completed:
  pre-flight check 5 built `leftover="$(... | grep -o ...)"` under `set -Eeuo pipefail`,
  and a unit that renders CLEAN is the no-match case, so the assignment returned 1 and
  `set -e` exited after "ok 3b." with no message. A second, comment-blind placeholder
  grep would then have died on the `@DEFAULT_MONITOR@` note in the guacd unit. One
  helper (`leftover_placeholders`, comment lines skipped, `|| true` load-bearing) now
  serves check 5, unit placement and `--verify`; `run_tests.sh` runs a staged
  `DESTDIR=... ./install.sh` to completion and requires "ok 9." (`install.sh`,
  `run_tests.sh`, `tests/installer_tests.sh`).
- **`.env` is placed, reconciled and validated by `install.sh`** — no longer byte-copied
  by `deploy.sh`. Missing: derived from `.envdefault`. Present: every key a new version
  ships and the file lacks is appended with the `.envdefault` value under a dated
  `# added by install.sh <version>` comment; an existing value is never changed (this is
  what blocked the Sep-18 deploy: `EDY_RDP_DESKUI_ENABLE`/`EDY_RDP_DOOR_USER` missing).
  Then it is validated, fail closed, naming the key and reason: grammar, required keys,
  secret-shaped values, and per-key rules (`EDY_RDP_GUACD` host:port, log level enum,
  absolute paths, `EDY_RDP_ADMIN_GROUP` must exist, 0/1 flags, a stale 1.3.x
  `PULSE_SERVER`). `--verify` validates and writes nothing. The grammar and the
  secret check live once, in `lib/edy-rdp-env.sh`, shared by `install.sh`, `deploy.sh`
  and the bootstrap. The `/etc/default/edy-rdp` migration stays in `deploy.sh`.
- **`requires.txt` is the one prerequisite list.** It now ships in the payload and
  `lib/edy-rdp-requires.sh` parses it (name, `>=` minimum, the `guacd-image` line) and
  checks presence AND version; `deploy.sh --with-deps`, `install.sh` (check 8b) and the
  bootstrap all read it. `deploy.sh`'s hardcoded `PREREQS` list is gone; the distro
  package-name mapping moved into the lib so the bootstrap can print the exact fix.
- **Start-time bootstrap + venv.** `edy-rdp-bootstrap` runs as `ExecStartPre=+` of the
  relay (root, exempt from `NoNewPrivileges`/`ProtectSystem`): validates `.env`, verifies
  prerequisites (never installs at service start), and — only when `requirements.txt`
  names something — builds `[install path]/venv` OFFLINE from wheels `deploy.sh` vendors
  into `payload/wheels/` (`--wheels <dir>` for hosts without index access), rebuilds it
  when the file's sha256 changes, and writes `venv.env`. Units run
  `/usr/bin/env ${EDY_RDP_PYTHON} ...` (systemd will not take a variable as the program)
  with `/usr/bin/python3` as the documented fallback. `requirements.txt` is empty today:
  the relay is stdlib-only.
- **Audio bind that survives boot (I42).** guacd's one-shot `ExecStartPre=-` bind of the
  seat pulse socket left a 0-byte file when guacd started before login and never
  retried; the rprivate `-v` meant a later bind could not reach the container. Now
  `edy-rdp-pulse-bind` makes `/run/edy-rdp-pulse` a SHARED mount, binds the socket in as
  `native`, the container mounts it `:ro,rslave` (host → container only; guacd cannot
  write into the host directory), and `edy-rdp-pulse-seat@<uid>.path` — `PathChanged=`
  on `/run/user/<uid>/pulse`, because `PathExists=` on the socket busy-loops a oneshot
  into `StartLimitBurst` and fails the path unit itself — rebinds at every login;
  `deploy.sh --with-units` enables it from the new `EDY_RDP_PULSE_SEAT_UID` and starts
  the rebind once for a seat already logged in. Audio for the next session with no
  restart. The script vets what root mounts: `lstat` only, no symlink on any
  user-owned component or on the target, a socket owned by the seat uid, the mount
  re-read and undone if it is not the vetted socket. `PULSE_SERVER` becomes
  `unix:/run/pulse/native`. Live verification on edt1 pending.
- **`deploy.sh` refuses a stale `.env` BEFORE it changes the host.** Its pre-flight runs
  the same present-keys validation as `install.sh` check 7 on the live `.env` (or the
  legacy `/etc/default/edy-rdp` about to be migrated) and dies `DEPLOY FAILED
  (pre-flight)` with the key and the fix — instead of copying, swapping the alias and
  then dying from the installed `install.sh`, which is the half-deployed state I43.
  `tests/installer_tests.sh` now runs `deploy.sh` itself staged end to end (`DEPLOY OK`,
  then `DEPLOY VERIFY OK`) and proves the pre-swap refusal leaves no payload behind.
- **Janua is the default guacd.** `GUACD_IMAGE` pins
  `ghcr.io/skylark-software/janua@sha256:2279eac0…` with `GUACD_ENTRYPOINT=/usr/local/sbin/guacd`;
  the official image is FreeRDP 2 (no RDSTLS: 3390 greeter and remote RDP break).
- **`--verify` now also checks:** `.env` validity; running container image ==
  `GUACD_IMAGE`; `gnome-remote-desktop` apt hold and patched daemon (vs `.orig-edt1`);
  the pulse socket mountpoint; `venv.env` vs `requirements.txt`; every `requires.txt`
  prerequisite with its detected version (one line each, no root needed; "skipped
  (staged)" under DESTDIR); and reports "NOT a symlink (hand-copied?)" instead of
  claiming a dev checkout. `deploy.sh` ends with an
  unmistakable `DEPLOY OK <version>` / `DEPLOY FAILED (<step>)`.
- Docs: KNOWN_ISSUES I41–I44 (silent abort; audio bind; edt1 half-deployed reclaim;
  stale pipewire TCP listener), README, COMPATIBILITY, TROUBLESHOOTING, AUDIO.

## 1.3.2.20260918 - 2026-09-18

Fix: clipboard auto-sync threw an uncaught promise rejection when unfocused.

- `client.onclipboard` auto-synced the session's clipboard to the OS with
  `navigator.clipboard.writeText()`, which **rejects asynchronously when the
  document is not focused** -- and the surrounding `try/catch` cannot catch an async
  reject, so it surfaced as `Uncaught (in promise) NotAllowedError` in the console.
  Now it only auto-writes while `document.hasFocus()` and `.catch()`es the reject;
  when unfocused the text still sits in `lastRemoteClip` for the "Receive clip"
  button (`guac-rdp.js`).

## 1.3.1.20260918 - 2026-09-18

Pop-out gets Add Monitor and a standalone Fullscreen button.

- **Add Monitor in the pop-out.** The existing "Add Monitor" button (opens a fresh
  virtual monitor in its own window) is now in the pop-out/monitor control strip,
  not just the main window.
- **Fullscreen split into its own button.** A plain "Fullscreen" toggle fills the
  screen WITHOUT grabbing the keyboard, for when you just want the bigger picture
  and keep your local shortcuts. "Special keys" still goes fullscreen on its own,
  because capturing OS-reserved system keys (Alt+Tab, Super, Esc, F11) genuinely
  requires fullscreen -- a Keyboard Lock API rule, not our choice; without
  fullscreen those keys still go to the local OS. Both buttons track fullscreen
  state via `fullscreenchange` (`guac-rdp.js`).

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
