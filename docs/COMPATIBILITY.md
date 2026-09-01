# Compatibility & prerequisites

`install.sh` auto-installs the OS prerequisites on a vanilla system using the host's
package manager (`apt`/`dnf`/`pacman`/`zypper`). This page documents what it installs,
the per-distro package names, and which distros are known-good.

```bash
sudo ./install.sh              # installs prerequisites, then the plugin + relay + units
sudo ./install.sh --deps-only  # only the prerequisites, then stop
sudo ./install.sh --skip-deps  # assume prerequisites are already present
```

Detection is by **binary presence**, so re-running is idempotent (nothing already
installed is touched). If no supported package manager is found, the installer prints
the exact package list and stops.

## Prerequisites

| Prereq | Proves-present binary | Why it's needed |
|---|---|---|
| Cockpit | `cockpit-bridge` + shell | hosts the plugin page, the TLS/websocket channel, and the navigation shell (needs `cockpit-system`, not just bridge+ws) |
| podman | `podman` | runs the `guacamole/guacd` container (host-loopback, nftables-gated) |
| Python 3 | `python3` | the privileged relay + reaper (stdlib only, no pip) |
| FreeRDP 3 client | `xfreerdp3` / `xfreerdp` | the per-connection bridge that speaks NLA/RDSTLS to gnome-remote-desktop |
| Xvfb | `Xvfb` | headless X server the bridge draws into |
| x11vnc | `x11vnc` | exposes the bridge's Xvfb as a loopback VNC endpoint for guacd |
| nftables | `nft` | owner-match gate so only the relay uid can reach guacd on 127.0.0.1:4822 |
| gnome-remote-desktop | `grdctl` | the RDP backend (console mirror, virtual monitor, per-user headless desktop) |
| D-Bus tools | `dbus-send` | reload the handover policy drop-in; talk to the session bus |

**guacd itself needs no native package** — it runs from the pinned
`docker.io/guacamole/guacd:1.6.0` container image, which the installer pre-pulls via podman.

The exact pinned versions (and the guacd image digest) are recorded in
[../requires.txt](../requires.txt).

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
  distros the installer symlinks `/usr/local/bin/xfreerdp3 → xfreerdp`.
- The installer verifies `xfreerdp /version` reports `3.x` and **refuses to proceed** on a
  FreeRDP-2-only host rather than installing a stack that cannot connect.

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
Add each Cockpit user who may use the plugin to the `edy-rdp` group:

```bash
sudo usermod -aG edy-rdp <user>
```

Then verify the core invariant (guacd must not be on a host port):

```bash
ss -tlnp | grep 4822        # 127.0.0.1 only, reachable solely by the relay uid
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if a scenario does not come up, and
[KNOWN_ISSUES.md](KNOWN_ISSUES.md) for the platform quirks this project works around.
