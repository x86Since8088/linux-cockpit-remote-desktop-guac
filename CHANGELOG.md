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
