# cockpit-guac-rdp

**Version 1.9.0.20260929** ([CHANGELOG](CHANGELOG.md)) · BSD-3-Clause · pinned prerequisites in [requires.txt](requires.txt)

Browser-based RDP into this host's GNOME desktop, from inside Cockpit, with guacd
**never exposed on a port** and **no session hijacking**.

## What it does
A Cockpit page ("Remote Desktop") that connects to gnome-remote-desktop (grd) and renders
it in the browser via guacamole-common-js. Four scenarios:

- **Isolated** — your own private, persistent headless GNOME desktop, started on demand.
- **Virtual monitor** — a second monitor attached to your own logged-in session.
- **Console** — a mirror of the physical screen (Cockpit-admin only).
- **Remote host** — RDP into another host on the network (fail-closed, admin allow-listed).

It also has a **Desktop UI** tab that can enable / disable / start / stop the host's
graphical desktop (the display manager + default systemd target) — for hosts you
administer remotely. It is off unless the host opts in, admin-gated, and Stop/Disable
require typing the host's name to confirm. See
[docs/DESKTOP-UI-CONTROL.md](docs/DESKTOP-UI-CONTROL.md).

Traffic rides Cockpit's own HTTPS; guacd is reached only through a local relay over an
AF_UNIX socket. See [docs/SCENARIOS.md](docs/SCENARIOS.md) for screenshots and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full data path.

## How it connects (FreeRDP3 bridge)
Each connection spins up a per-connection bridge: a vanilla **FreeRDP 3** client
(`xfreerdp3`) speaks NLA/RDSTLS to grd and draws into a headless **Xvfb**, which **x11vnc**
publishes on a loopback VNC port; guacd's VNC client bridges that to the browser. guacd's
own bundled FreeRDP2 cannot negotiate to grd, which is why the FreeRDP3 bridge exists
(see [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) I26).

## Security properties
- **guacd is never on a host port.** It binds `127.0.0.1:4822` in the host netns; an
  nftables owner-match admits only the relay uid. The sole ingress is the AF_UNIX socket
  `/run/edy-rdp/guacd.sock`, reached over Cockpit's TLS channel.
- **Per-user isolation.** The relay identifies the caller by `SO_PEERCRED`
  (kernel-supplied, unforgeable) and binds every guacd session UUID to that uid; joining
  another user's UUID is refused (Guacamole's default join-by-UUID screen-share is a
  hijack vector — verified — and is closed here).
- **Elevation-proven console gate.** The console/mirror scenario requires an admin, proven
  server-side by an elevation challenge (a root-only file read over a superuser Cockpit
  channel), not a client-side check.
- **uid-bound session token.** Every connection carries a 256-bit token bound to the
  caller's uid — end-to-end correlation id and anti-hijack (a leaked token is useless to
  another user).
- **Per-connection VNC password.** The bridge's loopback VNC leg is password-gated, so no
  other local user can attach to a live session.
- **RDP target allow-list + keepalive.** SSRF-class defense on what guacd may dial (see
  [docs/CVE.md](docs/CVE.md)); the relay sends guacd `nop`s so sessions don't hit the ~18 s
  idle abort.
- **Session lifecycle.** A registry tracks sessions; the connection is torn down on
  disconnect while a persistent desktop is kept for reconnect, then reaped once idle
  (greeters 60 s, isolated desktops 15 min).

## Install

Two processes, and they are not the same thing.

```bash
sudo ./deploy.sh --all            # THE DEPLOYMENT: OS prerequisites, users, copy ->
                                  # /opt/cockpit-guac-rdp, run the installed install.sh
                                  # (place/validate .env), guacd image, enable the units
sudo ./deploy.sh                  # the safe default: copy + configure + place units,
                                  # enable NOTHING
sudo ./deploy.sh --with-units     # ...and bring the units up
sudo ./deploy.sh --verify         # check a deployed host, write nothing
sudo ./deploy.sh --uninstall      # unlink; keep the payload, .env, users
sudo ./deploy.sh --remove         # also delete the deployed payloads

./install.sh                      # an in-place install BY SYMLINK, from wherever
                                  # this file is. Enables nothing, ever.
./install.sh --verify             # the completeness gate + this host's state
./install.sh --uninstall
DESTDIR=/tmp/stage ./deploy.sh    # rehearse the whole thing into a stage
```

`install.sh` does not copy the payload — it **links** it. Run it from this checkout
and Cockpit serves the checkout, so you edit `guac-rdp.js` and reload the browser.
Run the *same* script from `/opt/cockpit-guac-rdp/payload` and you get a production
install with no relationship to any share. It branches on which one it is only to
*record* the answer, never to decide what to link.

**`install.sh` no longer installs packages, creates users, pulls images or starts
anything.** All of that changes the running state of a host, and it belongs to
`deploy.sh` — the script that only ever runs on a host being deployed to. A dev
install that enabled `edy-rdp-relay.service` would put two relays on one machine
fighting over one socket and one nftables table. `install.sh` *verifies* those
prerequisites and refuses with the command that fixes them. Neither script ever
touches `cockpit.socket`.

**Configuration is placed, reconciled and validated by `install.sh`.** When
`[install path]/.env` is missing it is derived from `.envdefault` (the comments come
along — they are the operator's documentation). When it exists, every key the new
version ships and the file lacks is appended with the `.envdefault` value under a dated
`# added by install.sh <version>` comment, and **a value you set is never changed**.
The placed file is then validated per key — grammar, every required key present,
nothing secret-shaped, `EDY_RDP_GUACD` is host:port, paths absolute, the log level one
of four, the admin group exists, 0/1 flags — and a bad value refuses the install
naming the key and the reason, before a single link is made (fail closed).
`./install.sh --verify` validates and writes nothing. The grammar lives once, in
`lib/edy-rdp-env.sh`, so `install.sh`, `deploy.sh` and the start-time bootstrap agree.

**Prerequisites have one source: `requires.txt`.** It ships in the payload and
`lib/edy-rdp-requires.sh` reads it — name, `>=` minimum version, the pinned
`guacd-image` — and checks presence *and* version. `deploy.sh --with-deps` installs
from it, `install.sh` reports against it (check 8b, never fatal for a dev install),
and the relay's bootstrap refuses to start without it. There is no second list to
disagree with.

**The relay's interpreter.** `requirements.txt` is the relay's pip file and is empty
today (the relay is stdlib-only, on purpose). While it is empty the units run
`/usr/bin/python3`. The moment it names something, `edy-rdp-bootstrap` — the relay's
`ExecStartPre=+`, run as root at every start — builds `[install path]/venv` OFFLINE
from wheels `deploy.sh` vendored into `payload/wheels/` (`pip download` on the target,
or `./deploy.sh --wheels <dir>` for a host without index access), rebuilds it when the
file's sha256 changes, and writes `[install path]/venv.env` so the units exec the venv's
python. The bootstrap also validates `.env` and checks `requires.txt` first, and it
**never installs a package at service start** — that changes host state and belongs
to `deploy.sh --with-deps`; it logs the exact fix and refuses instead.

**Desktop audio bind.** guacd records the seat's pulse socket through a bind mount.
Since 1.4.0 that is a *directory* bind, `/run/edy-rdp-pulse`, made a shared mount by
`edy-rdp-pulse-bind` and mounted into the container `:ro,rslave` (host → container
only, and nothing guacd can write into); the seat socket is bound into it as `native`
by `edy-rdp-pulse-seat@<uid>.path` (an inotify watch on `/run/user/<uid>/pulse`) when
a seat login creates it, so it propagates into the running container without a
restart (the one-shot bind of 1.3.x left audio dead after every boot — KNOWN_ISSUES
I42). The script vets what root is about to mount — no symlinks, a socket owned by
the seat uid — and refuses otherwise. The uid comes from `EDY_RDP_PULSE_SEAT_UID` in
`.env`; see [docs/AUDIO.md](docs/AUDIO.md).

After deploying: add users to the `cockpit-guac-rdp` group (`usermod -aG cockpit-guac-rdp
<user>`). Cockpit picks up the plugin on the next page load (Ctrl-Shift-R clears the cached
manifest). **This is not just a socket permission** — for most scenarios it is the *whole*
access decision, with no Cockpit-administrator status required. See
[Who the group actually admits](#who-the-group-actually-admits) below, and
[docs/GROUP-ACCESS-MODEL.md](docs/GROUP-ACCESS-MODEL.md) for the full analysis.

### Which install is this host running?

```bash
readlink -f /usr/share/cockpit/guac-rdp/index.html   # /opt/... = deployed, /srv/... = dev
cat /etc/cockpit-guac-rdp/install.conf               # INSTALL_KIND, ENV_FILE, VERSION
```

Verify the core invariant:
```bash
ss -tlnp | grep 4822        # 127.0.0.1 only, reachable solely by the relay uid
nft list table inet edy_rdp_guacd
ls -l /run/edy-rdp/guacd.sock
```

## Configuration

Settings live in **`[install path]/.env`** — normally `/opt/cockpit-guac-rdp/.env`.
`install.sh` places it from the committed `.envdefault` when it is missing, appends
the keys a newer version adds when it exists (dated comment, your values untouched),
and validates it either way — a bad value refuses the install by key and reason. The
units read it directly (`EnvironmentFile`), so there is one copy of each setting on
the host and not two. It sets the guacd endpoint, the admin group, the local and
remote RDP allow-lists, the log level, the pinned `GUACD_IMAGE` + `GUACD_ENTRYPOINT`,
the 3390 door username, the seat uid whose pulse socket carries audio, and the
GitHub repo the **Update** tab checks for a newer Release (`EDY_RDP_UPDATE_REPO`,
see `docs/SELFUPDATE.md`).

> **Moved in this version.** These settings used to be `/etc/default/edy-rdp`, seeded
> from `etcdefaults/edy-rdp`. That file was `.envdefault` wearing the wrong hat: it is
> settings the software *reads to know how to behave*, of which there is exactly one,
> which is the definition of `.envdefault` — `etcdefaults/` is for data files the
> software *manages*, of which there can be zero or many. `deploy.sh` **migrates an
> existing `/etc/default/edy-rdp` into `.env`**, carrying your edits across, and
> leaves the old file in place with a warning. It is your file; delete it once you
> agree, because two config files where one is silently ignored is how a setting gets
> changed and never takes effect.

A `.env` carries **locations and settings, never a secret** — `install.sh` and the
relay's start-time bootstrap refuse a value that looks like a credential (same check,
same library). The 3390 door key in particular lives
in gnome-remote-desktop's own credential store, written by
`edy-rdp-rotate-rdplogin`; only the *username* appears here.

Apply changes with `systemctl restart edy-rdp-relay.service` (and
`edy-rdp-guacd.service` for the image).

**Enabling the Remote-host scenario.** It is off by default (fail-closed). Set the
hosts the relay may RDP into and restart:

```bash
# in /opt/cockpit-guac-rdp/.env
EDY_RDP_REMOTE_ALLOW=192.168.2.0/24        # IPv4/CIDR, optional :port (default 3389), :* any port
# EDY_RDP_REMOTE_ADMIN_ONLY=1              # optional: require Cockpit admin for remote
```
```bash
sudo systemctl restart edy-rdp-relay.service
```
Empty = deny all; `any` = allow any host (use with care). Only IPv4 targets are accepted.

**Shadow-group gate for the console scenario.** Being a Cockpit administrator decides
whether you may use the console mirror at all (I4); it does not by itself decide whether
you may point it at a *different* signed-in user's desktop rather than an empty seat or
your own. When a different user is currently signed in at the physical seat, the relay
additionally requires membership in a unix group:

```bash
# in /opt/cockpit-guac-rdp/.env
EDY_RDP_SHADOW_GROUP=cockpit-guac-rdp-shadow
```
`deploy.sh --with-users` now creates this group automatically, the same way it already does
for the main relay group. If you did not pass that flag, create it and add members yourself:
```bash
sudo groupadd cockpit-guac-rdp-shadow
sudo usermod -aG cockpit-guac-rdp-shadow <your account>
sudo systemctl restart edy-rdp-relay.service
```
A nonexistent or empty group means the gate refuses everyone (fail closed), which is the
safe default. Set `EDY_RDP_SHADOW_GROUP=` (empty) to turn this extra check off entirely and
revert to admin-only console gating. Does not apply when nobody is signed in at the seat, or
when the signed-in user is the one requesting the mirror.

**Self-update.** The relay checks `EDY_RDP_UPDATE_REPO` (a GitHub `owner/repo`,
default this project's own) for a newer tagged Release. Checking and applying are
available to any Cockpit administrator by default (no separate enable flag) — see
`docs/SELFUPDATE.md` for the control-op contract, the exit-code enums and the
trust model.

```bash
# in /opt/cockpit-guac-rdp/.env
EDY_RDP_UPDATE_REPO=x86Since8088/linux-cockpit-remote-desktop-guac
```

## Who the group actually admits

`usermod -aG cockpit-guac-rdp <user>` is stated above as *the* way to grant access, and for
most of what this plugin does, it is — not a step toward access, the whole decision.
Membership in the `cockpit-guac-rdp` group is **necessary** for every scenario (it is the
socket permission that lets the browser reach the relay at all) and, for **isolated, virtual
monitor, wayland-vnc and greeter**, it is also **sufficient**: none of those scenarios has an
`admin_required` path, so a non-admin group member uses them exactly as a Cockpit
administrator would, with no elevation of any kind. The same is true of **remote host / vnc**
under their default configuration (`EDY_RDP_REMOTE_ADMIN_ONLY=0`, the shipped default) — group
membership plus an operator-populated `EDY_RDP_REMOTE_ALLOW` is enough.

Two scenarios need more, and only two:
- **Console** always requires proven Cockpit-administrator status (I4), on top of group
  membership — never group membership alone. If a *different* user is currently signed in at
  the physical seat, console additionally requires membership in `EDY_RDP_SHADOW_GROUP` (I50,
  see above) — a separate gate layered on top of the admin one, not a replacement for it.
- **Remote host / vnc** always need an administrator to have populated
  `EDY_RDP_REMOTE_ALLOW` — an empty allow-list is a deny-all regardless of who connects — and
  can optionally be restricted further to Cockpit administrators with
  `EDY_RDP_REMOTE_ADMIN_ONLY=1`.

See [docs/GROUP-ACCESS-MODEL.md](docs/GROUP-ACCESS-MODEL.md) for what this means for an
operator deciding who to add to the group, including the greeter scenario's specific risk
(a group member can attempt to sign in as *any* account the host knows, not just their own)
and concrete hardening recommendations.

## Layout
| path | purpose |
|---|---|
| `manifest.json` `index.html` `guac-rdp.js` `guac-rdp.css` | the Cockpit page |
| `guac-proto.js` | Guacamole wire codec (shared with the relay's tests) |
| `guacamole-common-js/all.min.js` | vendored client (Apache-2.0) |
| `relay/edy_rdp_relay.py` | the AF_UNIX relay: SO_PEERCRED auth, UUID binding, gates, allow-list, keepalive |
| `relay/session_registry.py` | persistent per-user session state + prune policy |
| `relay/control.py` | management API: list / terminate / register / elevate |
| `relay/bridge.py` | orchestrates the per-connection FreeRDP3 bridge |
| `relay/selfupdate.py` | self-update: version compare, GitHub release check, cache, health check, payload/rollback bookkeeping |
| `relay/edy_rdp_reaper.py` | closes idle greeters + prunes the registry |
| `relay/test_*.py` | unit tests (isolation, gates, allow-list, reaper, reconnect, codec) |
| `bridge/edy-rdp-bridge-start.sh` | the bridge launcher (xfreerdp3 → Xvfb → x11vnc) |
| `headless/edy-rdp-headless-{start,stop}.sh` | per-user isolated headless-session lifecycle |
| `rotate/edy-rdp-rotate-rdplogin.sh` | rotates the 3390 door credential |
| `selfupdate/edy-rdp-selfupdate-{apply,rollback}.py` | privileged, parameterless self-update mechanics (fetch/extract/deploy.sh, or payload-symlink swap; both health-check and gate on it) |
| `lib/edy-rdp-env.sh` `lib/edy-rdp-requires.sh` | sourced libraries (linked into libexec): the ONE `.env` grammar + validators, the ONE reading of `requires.txt` |
| `bootstrap/edy-rdp-bootstrap.sh` | the relay's `ExecStartPre=+`: validates `.env`, checks prerequisites, builds/refreshes the venv offline, writes `venv.env` |
| `pulse/edy-rdp-pulse-bind.sh` | makes `/run/edy-rdp-pulse` a shared mount and binds the seat pulse socket into it (guacd `ExecStartPre` + the per-seat path unit) |
| `systemd/*.in` `systemd/*` | unit templates (`@LIBEXEC@`, `@ENV_FILE@`, `@INSTALL_PATH@`) and the units that need no rendering |
| `hardening/*` | nftables owner-match, D-Bus handover policy, polkit rule |
| `.envdefault` | the settings seed; `install.sh` places it as `[install path]/.env`, appends new keys on upgrade, validates |
| `requires.txt` `VERSION` | THE prerequisite list (OS packages with minimum versions + the pinned guacd image), shipped in the payload; release version |
| `requirements.txt` | pip requirements for the relay — empty (stdlib-only); a non-empty one makes the bootstrap build a venv from vendored wheels |
| `tests/` | installer / env / requires / bootstrap / pulse-bind tests run by `run_tests.sh` (not shipped) |
| `pod/` `systemd/DEPRECATED-pod.*` | the superseded pod deployment (kept for reference; the host-loopback path above is current) |
| `docs/*` | architecture, compatibility, scenarios, known issues, CVE, troubleshooting |
| `img/*` | working-scenario screenshots referenced by the docs |
| `install.sh` | the symlink installer + the completeness gate; declares the ONE manifest both scripts read |
| `deploy.sh` `deploy.ps1` `deploy.bat` | the deployment; the Windows pair explains why there is no Windows deployment |
| `run_tests.sh` | test runner: relay unit tests, the loopback invariant, the DEPLOY-CONTRACT standing greps, a staged `DESTDIR` install to completion + `--verify` |

## Docs
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) — prerequisites + per-distro matrix
- [docs/SCENARIOS.md](docs/SCENARIOS.md) — the four scenarios, with screenshots
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the data path and components
- [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) — platform quirks and the fixes/mitigations
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — health checks and symptom→fix
- [docs/AUDIO.md](docs/AUDIO.md) — desktop audio: the shared pulse bind and how to verify it
- [docs/CVE.md](docs/CVE.md) — the guacd/RDP exposure surface this design closes
- [docs/SPEC-3389-mux.md](docs/SPEC-3389-mux.md) — deferred design for native-client ingress

## Licence
BSD-3-Clause (plugin + relay). Vendored guacamole-common-js is Apache-2.0.
