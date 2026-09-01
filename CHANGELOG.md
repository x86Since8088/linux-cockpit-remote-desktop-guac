# Changelog

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
