# cockpit-guac-rdp

**Version 1.1.1.20260903** ([CHANGELOG](CHANGELOG.md)) · BSD-3-Clause · pinned prerequisites in [requires.txt](requires.txt)

Browser-based RDP into this host's GNOME desktop, from inside Cockpit, with guacd
**never exposed on a port** and **no session hijacking**.

## What it does
A Cockpit page ("Remote Desktop") that connects to gnome-remote-desktop (grd) and renders
it in the browser via guacamole-common-js. Four scenarios:

- **Isolated** — your own private, persistent headless GNOME desktop, started on demand.
- **Virtual monitor** — a second monitor attached to your own logged-in session.
- **Console** — a mirror of the physical screen (Cockpit-admin only).
- **Remote host** — RDP into another host on the network (fail-closed, admin allow-listed).

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
The installer auto-installs the OS prerequisites on a vanilla system (see
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for the per-distro matrix).

```bash
sudo ./install.sh                 # prerequisites + plugin + relay + systemd units + edy-rdp group
sudo ./install.sh --deps-only     # only the OS prerequisites, then stop
sudo ./install.sh --skip-deps     # assume prerequisites present
sudo ./install.sh --uninstall     # remove everything this installed
./install.sh --user               # plugin only, into ~/.local/share/cockpit
./install.sh --plugin-only        # plugin only, system-wide
DESTDIR=/tmp/stage ./install.sh   # stage into a package build root (implies --skip-deps)
```

After install: add users to the `edy-rdp` group (`usermod -aG edy-rdp <user>`); optionally
load `hardening/edy-rdp-firewall.nft` to take 3389/3390 off the LAN. Cockpit picks up the
plugin on next page load (Ctrl-Shift-R clears the cached manifest).

Verify the core invariant:
```bash
ss -tlnp | grep 4822        # 127.0.0.1 only, reachable solely by the relay uid
ls -l /run/edy-rdp/guacd.sock
```

## Configuration
Relay tunables live in **`/etc/default/edy-rdp`** (installed from `etcdefaults/edy-rdp`;
an operator-edited copy is preserved on upgrade). It sets the guacd endpoint, the admin
group, the RDP target allow-list, the log level, and the pinned `GUACD_IMAGE`. The units
carry identical built-in defaults, so the file is optional. Apply changes with
`systemctl restart edy-rdp-relay.service` (and `edy-rdp-guacd.service` for the image).

**Enabling the Remote-host scenario.** It is off by default (fail-closed). Set the hosts
the relay may RDP into and restart:

```bash
# in /etc/default/edy-rdp
EDY_RDP_REMOTE_ALLOW=192.168.2.0/24        # IPv4/CIDR, optional :port (default 3389), :* any port
# EDY_RDP_REMOTE_ADMIN_ONLY=1              # optional: require Cockpit admin for remote
```
```bash
sudo systemctl restart edy-rdp-relay.service
```
Empty = deny all; `any` = allow any host (use with care). Only IPv4 targets are accepted.

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
| `relay/edy_rdp_reaper.py` | closes idle greeters + prunes the registry |
| `relay/test_*.py` | unit tests (isolation, gates, allow-list, reaper, reconnect, codec) |
| `bridge/edy-rdp-bridge-start.sh` | the bridge launcher (xfreerdp3 → Xvfb → x11vnc) |
| `headless/edy-rdp-headless-{start,stop}.sh` | per-user isolated headless-session lifecycle |
| `rotate/edy-rdp-rotate-rdplogin.sh` | rotates the 3390 door credential |
| `systemd/*` | guacd, relay/control sockets, reaper timer, headless template, firewall loader, tmpfiles |
| `hardening/*` | nftables owner-match, D-Bus handover policy, polkit rule |
| `etcdefaults/edy-rdp` | relay config, installed to `/etc/default/edy-rdp` (preserved on upgrade) |
| `requires.txt` `VERSION` | pinned prerequisite manifest; release version |
| `pod/` `systemd/DEPRECATED-pod.*` | the superseded pod deployment (kept for reference; the host-loopback path above is current) |
| `docs/*` | architecture, compatibility, scenarios, known issues, CVE, troubleshooting |
| `img/*` | working-scenario screenshots referenced by the docs |
| `install.sh` `run_tests.sh` | installer; test runner |

## Docs
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) — prerequisites + per-distro matrix
- [docs/SCENARIOS.md](docs/SCENARIOS.md) — the four scenarios, with screenshots
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the data path and components
- [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) — platform quirks and the fixes/mitigations
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — health checks and symptom→fix
- [docs/CVE.md](docs/CVE.md) — the guacd/RDP exposure surface this design closes
- [docs/SPEC-3389-mux.md](docs/SPEC-3389-mux.md) — deferred design for native-client ingress

## Licence
BSD-3-Clause (plugin + relay). Vendored guacamole-common-js is Apache-2.0.
