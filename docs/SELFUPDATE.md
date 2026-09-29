# Self-update

The **Update** tab lets a Cockpit administrator check this project's own GitHub
repository for a newer tagged Release than what is installed, and apply it with
one click — with AUTOMATIC rollback if the newly-installed version fails a
post-restart health check.

This document covers the backend half: the four control-socket ops, the two
privileged systemd units behind them, the exit-code enums, and the trust model.
The frontend (the Update tab itself) is a separate piece built against the exact
contract below.

> **As of this writing, this repository has no GitHub Releases or tags yet**
> (`gh release list` and `git tag --list` are both empty). Until the maintainer
> cuts the first tagged Release, `update-status`/`update-check` will report
> `update_available: false` and `latest_version: null` on every host. That is
> the CORRECT, expected result of asking GitHub "what's the latest Release?"
> when there are none — not a bug in this feature.

## Why GitHub, never local git

A **deployed** host has no git repository at all: `deploy.sh`'s own
`copy_declared_payload_into()` explicitly excludes `.git/`, `docs/`, `deploy.sh`
itself, `CHANGELOG.md` and `README.md` from what ships into
`/opt/cockpit-guac-rdp/payload-<version>/`. So "check for updates" goes through
the GitHub API, never local git, and "apply an update" means fetching a fresh
copy of the repo tree at a tag (which DOES include `deploy.sh` — that exclusion
is `deploy.sh`'s own packaging step, not something present in the tagged tree)
and re-running **that** `deploy.sh` against the existing install root. The
payload-swap / `.env`-reconcile / preflight logic already in `deploy.sh` is
reused by invoking it, never reimplemented here.

## Architecture

```
Cockpit (Update tab)
   |  control.sock: update-status / update-check / update-apply / update-rollback
   v
relay (edy-relay, unprivileged)  --  relay/selfupdate.py: SelfUpdate
   |  reads/writes /run/edy-rdp/update-status.json (cache)
   |  systemctl start <unit>  (polkit: edy-relay may start ONLY these two exact
   |                           unit names -- see hardening/edy-rdp-headless.rules)
   v
edy-rdp-selfupdate-apply.service        edy-rdp-selfupdate-rollback.service
   (Type=oneshot, root, PARAMETERLESS)     (Type=oneshot, root, PARAMETERLESS)
   |                                        |
   v                                        v
selfupdate/edy-rdp-selfupdate-apply.py  selfupdate/edy-rdp-selfupdate-rollback.py
   re-fetches GitHub itself                 re-derives the rollback target itself
   (never trusts the relay's cache)         (never trusts any caller argument)
```

Both privileged scripts `sys.path.insert()` their own directory and
`import selfupdate` to reuse `relay/selfupdate.py`'s version parsing, GitHub
call, cache format and payload/rollback bookkeeping — one copy of all of it,
shared by the unprivileged relay and the two root-run helpers, installed
side by side in `/usr/libexec/edy-rdp/` by `install.sh`'s manifest.

### The privilege boundary: parameterless units, one step past the existing pattern

Every other privileged verb in this project (`edy-rdp-deskui@<action>`,
`edy-rdp-unlock@<uid>`, `edy-rdp-headless@<uid>`, `edy-rdp-waylandvnc@<uid>`) is a
**templated** unit: the relay picks an instance name (`%i`) from a fixed enum or
a validated uid, and the helper behind it re-validates `%i` before acting. That
is already narrow — but it does carry ONE piece of caller-influenced data (`%i`)
across the `systemctl start` call.

`edy-rdp-selfupdate-apply.service` and `edy-rdp-selfupdate-rollback.service` are
**not templated at all** — no `%i`, no instance argument, nothing. "apply"
always means "whatever THIS SCRIPT's own fresh GitHub call says is latest right
now"; "rollback" always means "whichever `payload-<version>` directory under
this install root is NOT the current `payload` symlink's target, and refuse
cleanly if that isn't exactly one directory". Both scripts re-derive and
re-validate every fact themselves — they never trust a version string, an
environment variable the caller set, or a file the unprivileged relay wrote.
**Zero caller-influenced data crosses the privilege boundary through the
`systemctl start` call itself** — a strictly stronger property than the `%i`
pattern, because there is nothing left for a compromised relay to smuggle
through it.

The relay's own pre-checks (is there a cached update? is there a rollback
candidate?) are a fast, convenient rejection path — never the security boundary.
The actual authority is the privileged script's own independent GitHub call (for
apply) or its own read of `/opt/cockpit-guac-rdp/payload-*` (for rollback).

## `deploy.sh` mechanics this feature depends on (verified against the source)

- `./deploy.sh --install-to <root>` with **no** `--with-units`/`--with-deps`/
  `--with-image`/`--all` is exactly the "safe, just swap the payload" mode: it
  copies the new payload, swaps the `payload` symlink, runs the
  newly-linked `install.sh` (which places/reconciles `.env`), and prunes old
  `payload-*` dirs down to `KEEP=1` extra — so after the first successful
  self-update there is normally exactly one older `payload-<version>`
  directory retained for rollback.
- `install.sh` renders unit **files** to `/etc/systemd/system/` any time it
  runs against a **deployed** layout (i.e. from inside a `payload-*` directory
  that the `payload` symlink already points at) — this is unconditional there,
  not gated by `deploy.sh`'s own `--with-units` flag. It also calls
  `systemctl daemon-reload` itself in that same branch (`do_install()`'s
  units-else-branch, `[[ -z "$D" ]] && systemctl daemon-reload`), because the
  skip condition (`KIND == dev && !WITH_UNITS`) is never true for a deployed
  layout. **`edy-rdp-selfupdate-apply.py` calls `systemctl daemon-reload` again
  anyway, immediately after `deploy.sh` returns and before restarting the
  relay**, as explicit defense in depth — so a changed `edy-rdp-relay.service`
  unit reliably takes effect even if that invariant in `install.sh` ever
  changes. In the common case this is a harmless repeat, not the only thing
  standing between a changed unit file and it taking effect.
- Rollback never re-invents the swap: it is exactly the recipe `deploy.sh`
  itself prints under `rollback:` in `do_deploy()`'s closing banner —
  `ln -sfn payload-<older> payload.new && mv -T payload.new payload && payload/install.sh`
  — done by `swap_payload_and_install()` in `relay/selfupdate.py`.
- **`edy-rdp-guacd.service` is never restarted by this feature.** Only
  `edy-rdp-relay.service` is restarted. Restarting `guacd` drops every live RDP
  screencast on the host; that has always been a deliberate, separate,
  explicitly-requested action in this project, never bundled into an automatic
  flow. A version bump that also needs a new `guacd` image is **out of scope**
  for the automatic path — apply it by hand
  (`.env`'s `GUACD_IMAGE` + `systemctl restart edy-rdp-guacd.service`).

## The health check

Gates AUTOMATIC rollback, so it must work with no browser open at all: from the
privileged script (root), it requires `systemctl is-active edy-rdp-relay.service`
to report `active`, THEN opens `/run/edy-rdp/control.sock` as a plain client and
sends `{"op":"ping"}\n` (the exact newline-delimited JSON framing
`controlRequest()` in `guac-rdp.js` and the relay's own socket server already
use), requiring `{"ok": true, ...}` within a few seconds — retried for up to
~20 seconds total (the relay needs a moment to restart) before declaring the new
version unhealthy and triggering rollback.

## The control-op contract

Newline-delimited JSON over `/run/edy-rdp/control.sock` — the same wire format
and dispatch style every other op in `relay/control.py` already uses.

### `update-status` (read-only, any authenticated caller)

```json
{"op": "update-status"}
```

```json
{"ok": true,
 "current_version": "1.7.0.20260929",
 "latest_version": "1.7.0.20260929" ,
 "update_available": false,
 "release_name": "...",
 "release_notes_url": "https://github.com/.../releases/tag/...",
 "published_at": "2026-09-29T12:00:00Z",
 "checked_at": 1790700000,
 "check_error": null,
 "no_releases": false,
 "rollback_available": true,
 "rollback_version": "1.6.1.20260929",
 "last_apply": {"from": "...", "to": "...", "result": "ok", "detail": "...", "at": 1790700100}}
```

Every field above except `ok`/`current_version`/`no_releases`/
`rollback_available`/`rollback_version` may be `null` (a host that has never
checked yet, or a GitHub call that failed). **Never blocks on the network**: it
serves whatever is cached immediately, and if the cache is missing or older than
`SelfUpdate.CACHE_TTL` (24h, a named constant in `relay/selfupdate.py`) it kicks
a background thread to refresh it for next time.

`no_releases` is a TYPED flag, not a string match against `check_error` — found
by review: this repository genuinely has no Releases yet (see "Known
limitations" below), and that expected, calm, day-one state was originally
indistinguishable from a real GitHub outage, both landing in the same untyped
`check_error` field. The frontend renders `no_releases: true` as a plain
informational line, never the bold/warn styling a real `check_error` gets.

### `update-check` (forces a live GitHub call, rate-limited)

```json
{"op": "update-check"}
```

Same shape as `update-status`, plus `"rate_limited": true|false`. Rate-limited
to once per 60 seconds of wall-clock **regardless of caller** — a call inside
that window returns the cached result at once with `rate_limited: true` rather
than erroring or re-hitting GitHub.

### `update-apply` (admin-gated + typed-hostname confirmation)

```json
{"op": "update-apply", "confirm": "<hostname operator typed>"}
```

| Case | Response |
|---|---|
| not admin | `{"ok": false, "error": "applying an update needs administrative access"}` |
| bad/missing confirm | `{"ok": false, "need_confirm": true, "hostname": "<actual hostname>"}` |
| nothing to apply | `{"ok": false, "error": "no update available"}` |
| success | `{"ok": true, "detail": "updated to 1.7.0.20260929 and healthy"}` |
| auto-rolled-back | `{"ok": false, "detail": "update to 1.7.0.20260929 failed its health check and was automatically rolled back to 1.6.1.20260929", "rolled_back": true}` |
| catastrophic | `{"ok": false, "detail": "...", "rolled_back": false}` (rollback ALSO failed — a human is needed on the host right now) |

The admin gate and the typed-hostname confirmation both live in
`relay/control.py`'s `handle_control()` — the same split as the Desktop UI
tab's `stop`/`disable` verbs — so a forged or stale `confirm` never reaches the
privileged unit. "which version" is never asked of the caller: the relay
re-validates against its own cache before even starting the unit, and the
privileged script re-validates AGAIN against a fresh GitHub call before
touching anything.

### `update-rollback` (admin-gated, NO typed confirmation)

```json
{"op": "update-rollback"}
```

Responses mirror `update-apply`'s shape, via the rollback unit instead, plus a
refusal message that distinguishes WHY there is nothing to roll back to (found
by review: these used to collapse into one generic string, which on a host
with two or more older `payload-<version>` directories claimed none existed at
all):

```json
{"ok": false, "error": "no earlier version is available to roll back to on this host"}
{"ok": false, "error": "more than one earlier version exists on this host; an operator must remove the extra payload-<version> directory before an automatic rollback can pick one"}
```

Deliberately **no** typed confirmation — this project's convention is that the
RECOVERY action stays low-friction while the DISRUPTIVE one carries the
confirmation (the same asymmetry as the Desktop UI tab's plain `start`, which
needs none, versus `stop`/`disable`, which do).

## Exit-code enums

`edy-rdp-selfupdate-apply` (mirrors `DesktopUI.control()`'s `ExecMainStatus`
mapping on the relay side):

| Code | Meaning |
|---|---|
| 0 | applied, restarted, health check passed |
| 2 | refused: nothing cached to apply / already on the latest version |
| 3 | fetch/extract/`deploy.sh` invocation failed BEFORE anything on the host was touched (the old payload is still live and was never touched — including a best-effort symlink restore if `deploy.sh` failed after swapping it but before finishing) |
| 4 | new version installed + relay restarted, health check FAILED, automatic rollback SUCCEEDED (host is back on the old version and healthy) |
| 5 | new version installed + relay restarted, health check FAILED, and the rollback attempt ALSO failed — worst case, a human is needed on the host now |
| 6 | refused: an apply or rollback is ALREADY in progress on this host (see "Mutual exclusion" below) |

`edy-rdp-selfupdate-rollback`:

| Code | Meaning |
|---|---|
| 0 | rolled back, health check passed |
| 2 | refused: no second `payload-<version>` directory exists on disk to roll back to |
| 3 | rollback swap/`install.sh`/restart failed — the relay may be in a bad state, needs a human |
| 6 | refused: an apply or rollback is ALREADY in progress on this host |

## Mutual exclusion between apply and rollback

Found by review, and worth stating plainly: an admin clicking "Roll back"
while "Update now" is still in flight (a realistic scenario — apply can take
up to `APPLY_TIMEOUT`, 300s, and an admin who thinks it looks stuck is exactly
who reaches for the recovery button) used to start a SECOND privileged oneshot
unit racing the first one's swap of the SAME `payload` symlink and its restart
of the SAME relay unit. Both `edy-rdp-selfupdate-apply` and
`edy-rdp-selfupdate-rollback` now wrap their entire run in
`relay/selfupdate.exclusive_run()`: a non-blocking `flock()` on
`<install-root>/.selfupdate.lock`, held for the full fetch/swap/restart/
health-check sequence. The second script to try exits immediately with code 6
rather than queuing behind the first (queuing would mean the recovery action
silently waits minutes behind whatever it was trying to recover from).
`swap_payload_and_install()` also uses a per-process-unique temp symlink name
(`payload.new.<pid>`, not a single fixed name) as defense-in-depth on top of
the lock, matching `deploy.sh`'s own versioned `$NEW.tmp` convention.

## Trust model — read this before relying on it

This feature verifies **TLS to `api.github.com` and `codeload.github.com`, and
nothing more**. There is **no code-signing or GPG verification** of the fetched
release tarball in this pass. Concretely:

- A compromise of the `x86Since8088` GitHub account (or of GitHub itself) that
  publishes a malicious tagged Release is a compromise of every host that
  applies that update. Nothing in this feature would detect it.
- `EDY_RDP_UPDATE_REPO` is trusted at face value; pointing it at a different
  repository means trusting that repository's owner exactly as much.
- The tarball extraction IS guarded against path traversal (Python 3.12+'s
  `filter="data"`, or a manual per-member containment check on older 3.9–3.11),
  which protects the HOST filesystem from a malicious archive layout — it says
  nothing about whether the CONTENT of that archive is code you want to run as
  root.

This is named here in the same spirit as `docs/KNOWN_ISSUES.md`'s "OPEN
(deferred)" entries: a real, current limitation, not something worth
overstating with a checksum step that would not actually verify anything
meaningful. A future pass could add release-asset signature verification
(e.g. `cosign`, or a detached GPG signature checked against a pinned key) —
deliberately not attempted here (see `docs/KNOWN_ISSUES.md` I49).

## Known limitations

- No `guacd` image upgrade path (by design — see "deploy.sh mechanics" above).
- No code-signing / checksum verification of the fetched release (see "Trust
  model" above).
- The health check restarts and re-checks `edy-rdp-relay.service` only; it does
  not (and cannot, from a stdlib-only, no-new-prerequisites design) verify that
  every scenario (console/virtual/isolated/remote/vnc/wayland-vnc) still works
  end-to-end — only that the relay process comes back up and answers `ping`.
- This repository has no GitHub Releases or tags yet as of this writing (see the
  note at the top) — the feature is fully wired and tested, but has nothing to
  report until the first tag is cut.
