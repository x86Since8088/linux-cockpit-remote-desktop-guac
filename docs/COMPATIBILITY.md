# Compatibility & prerequisites

The OS prerequisites have **one source**, [../requires.txt](../requires.txt): a name, a
`>=` minimum version and the pinned guacd image, one per line. `deploy.sh --with-deps`
installs from it using the host's package manager (`apt`/`dnf`/`pacman`/`zypper`),
`install.sh` reports against it (check 8b on a live install — a warning, never fatal, so
a dev install on a box lacking x11vnc still links; and under `--verify`, one `ok`/`FAIL`
line per tool with the detected version, a `FAIL` when anything is missing or below its
minimum), and the relay's start-time bootstrap (`edy-rdp-bootstrap`) refuses to start
the relay without them — it never installs a package at service start, it prints the
exact fix and exits. All three read the file through `lib/edy-rdp-requires.sh`, which
also holds the per-distro package-name mapping below. This page documents what that
list is, the package names, and which distros are known-good.

```bash
sudo ./deploy.sh --with-deps   # install the prerequisites from requires.txt, then deploy
sudo ./deploy.sh               # deploy assuming they are present (reports what is missing)
./install.sh --verify          # the per-host report: one line per prerequisite with its
                               # detected version (no root needed; "skipped (staged)" under DESTDIR)
```

Detection is by **presence AND minimum version** from `requires.txt`: each tool is
probed by its own version flag (`cockpit-bridge --version`, `podman --version`,
`xfreerdp3 /version`, `x11vnc -version`, `nft --version`, ...). Xvfb has no version flag
at all, so its version comes from the package manager (`dpkg-query`/`rpm`/`pacman`);
a version that cannot be detected counts as present, not as a failure. Re-running is
idempotent (nothing already installed is touched). If no supported package manager is
found, the fix command names the packages to install by hand and stops.

## Prerequisites

| Prereq | Proves-present binary | Why it's needed |
|---|---|---|
| Cockpit | `cockpit-bridge` + shell | hosts the plugin page, the TLS/websocket channel, and the navigation shell (needs `cockpit-system`, not just bridge+ws) |
| podman | `podman` | runs the guacd container (host-loopback, nftables-gated) |
| Python 3 | `python3` | the privileged relay + reaper (stdlib only; `requirements.txt` is empty — a non-empty one makes the bootstrap build a venv, which then needs `python3-venv`) |
| FreeRDP 3 client | `xfreerdp3` / `xfreerdp` | the per-connection bridge that speaks NLA/RDSTLS to gnome-remote-desktop |
| Xvfb | `Xvfb` | headless X server the bridge draws into |
| x11vnc | `x11vnc` | exposes the bridge's Xvfb as a loopback VNC endpoint for guacd |
| nftables | `nft` | owner-match gate so only the relay uid can reach guacd on 127.0.0.1:4822 |
| gnome-remote-desktop | `grdctl` | the RDP backend (console mirror, virtual monitor, per-user headless desktop) |
| D-Bus tools | `dbus-send` | reload the handover policy drop-in; talk to the session bus |

**guacd itself needs no native package** — it runs from a container image pinned **by
digest**: `ghcr.io/skylark-software/janua@sha256:2279eac0…` (Janua = guacd built against
FreeRDP 3), with `GUACD_ENTRYPOINT=/usr/local/sbin/guacd`. The official
`docker.io/guacamole/guacd:1.6.0` is FreeRDP 2, which lacks RDSTLS — the 3390 greeter
handover and the Remote-host scenario break on it ([KNOWN_ISSUES](KNOWN_ISSUES.md) I26) —
so it is kept only as a documented alternative. `deploy.sh --with-image` pre-pulls the
pinned image and `install.sh --verify` checks the RUNNING container is that image.

The minimum versions and the guacd image ref + digest are recorded in
[../requires.txt](../requires.txt); the tested versions are in the matrix below.

## Per-distro package names

| Prereq | apt (Debian/Ubuntu) | dnf (Fedora/RHEL) | pacman (Arch) | zypper (openSUSE) |
|---|---|---|---|---|
| Cockpit | `cockpit cockpit-system` | `cockpit cockpit-system` | `cockpit` | `cockpit cockpit-bridge` |
| podman | `podman` | `podman` | `podman` | `podman` |
| Python 3 | `python3` | `python3` | `python` | `python3` |
| FreeRDP 3 client | `freerdp3-x11` | `freerdp` | `freerdp` | `freerdp` |
| Xvfb | `xvfb` | `xorg-x11-server-Xvfb` | `xorg-server-xvfb` | `xorg-x11-server-Xvfb` |
| x11vnc | `x11vnc` | `x11vnc` | `x11vnc` | `x11vnc` |
| nftables | `nftables` | `nftables` | `nftables` | `nftables` |
| gnome-remote-desktop | `gnome-remote-desktop` | `gnome-remote-desktop` | `gnome-remote-desktop` | `gnome-remote-desktop` |
| D-Bus tools | `dbus-bin` | `dbus-tools` | `dbus` | `dbus-1-tools` |

### The FreeRDP-3 gotcha (the one that actually breaks portability)
The bridge **requires FreeRDP major version ≥ 3** — FreeRDP 2 cannot negotiate NLA to
grd's screen-share port nor RDSTLS to the Remote-Login greeter (this is the whole reason
the project moved off guacd's bundled FreeRDP2; see [KNOWN_ISSUES](KNOWN_ISSUES.md) I26).

- The client binary is **`xfreerdp3`** on Debian/Ubuntu but **`xfreerdp`** (when it is v3)
  on Fedora/Arch/openSUSE. The bridge launcher calls `xfreerdp3` by name, so on those
  distros `deploy.sh --with-deps` symlinks `/usr/local/bin/xfreerdp3 → xfreerdp`.
- `requires.txt` says `freerdp >=3.0`; the lib's probe takes `xfreerdp3`, else `xfreerdp`
  only when `xfreerdp /version` reports `version 3.`, so a FreeRDP-2-only host is reported
  as **missing** and `deploy.sh --with-deps` **refuses to proceed** rather than deploying a
  stack that cannot connect.

## Distro compatibility matrix

| Distro | Status | FreeRDP in repos | Notes |
|---|---|---|---|
| **Ubuntu 26.04 LTS** | ✅ tested (edt1) | 3.31 (`freerdp3-x11`) | reference platform; gnome-remote-desktop 50.2 |
| Ubuntu 24.04 LTS | ✅ expected | 3.x | |
| Debian 13 (trixie) | ✅ expected | 3.x | |
| Debian 12 (bookworm) | ⚠️ FreeRDP2 only | 2.x | needs FreeRDP3 from backports before install |
| Fedora 40+ | ✅ expected | 3.x (`xfreerdp`) | `xfreerdp3` alias auto-created |
| RHEL / Alma / Rocky 10 | ✅ expected | 3.x | |
| RHEL / Alma / Rocky 9 | ⚠️ FreeRDP2 only | 2.x | needs FreeRDP3 (EPEL/COPR) first |
| Arch Linux | ✅ expected | 3.x (`xfreerdp`) | `xfreerdp3` alias auto-created |
| openSUSE Tumbleweed | ✅ expected | 3.x | |
| openSUSE Leap 15.x | ⚠️ FreeRDP2 only | 2.x | needs FreeRDP3 first |

Legend: ✅ tested / expected to work · ⚠️ works only after providing FreeRDP ≥ 3.

Other hard requirements independent of distro:
- **gnome-remote-desktop ≥ 46** (headless RDP + the system daemon); tested with 50.2.
- **systemd** (units, socket activation, per-user `edy-rdp-headless@.service`).
- A host that boots with **nftables available** (the installer ships an `/etc/nftables.d`
  drop-in and a loader service; it does not require `nftables.service` to be the active
  firewall — it coexists with ufw/firewalld).

## After installation
Add each Cockpit user who may use the plugin to the `cockpit-guac-rdp` group:

```bash
sudo usermod -aG cockpit-guac-rdp <user>
```

Group membership is more than a socket permission for most scenarios — see
[GROUP-ACCESS-MODEL.md](GROUP-ACCESS-MODEL.md) for exactly what it grants.

Then verify the core invariant (guacd must not be on a host port):

```bash
ss -tlnp | grep 4822        # 127.0.0.1 only, reachable solely by the relay uid
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if a scenario does not come up, and
[KNOWN_ISSUES.md](KNOWN_ISSUES.md) for the platform quirks this project works around.
