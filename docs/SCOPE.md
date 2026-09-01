# Scope & guardrails

## What this is
- **Languages:** JavaScript (Cockpit plugin) + Python 3 (privileged relay/reaper) + Bash
  (installer, bridge, headless lifecycle) + systemd/podman (deploy).
- **Package:** `source/` is the git root and the whole deliverable — a Cockpit package
  (`manifest.json`, `index.html`, `guac-rdp.{js,css}`, vendored `guacamole-common-js/`),
  plus `relay/`, `bridge/`, `headless/`, `rotate/`, `systemd/`, `hardening/`, `docs/`,
  `img/`, and `install.sh`. No build step for the plugin; the relay is stdlib Python 3.
- **Runtime:** Cockpit on Ubuntu 26.04 (reference host); gnome-remote-desktop 50.2 (RDP,
  NLA mandatory, gfx-only). guacd runs from a container on host loopback, nftables-gated.
  See [COMPATIBILITY.md](COMPATIBILITY.md) for other distros.
- **Tests:** the Playwright browser suite lives in the working-tree harness `cockpit-e2e/`
  (outside this repo); the relay's Python unit tests are `relay/test_*.py`, run by
  `run_tests.sh`.

## Hard constraints (guardrails — do not violate)

1. **guacd port 4822 MUST NOT be reachable from the host or the network.** It binds
   `127.0.0.1:4822` and an nftables owner-match admits only the relay uid; the only ingress
   is the AF_UNIX socket over Cockpit's HTTPS channel. Publishing 4822 (`-p …:4822`) is a
   regression.
2. **Every byte from the browser travels over TLS** (Cockpit's own HTTPS/wss). The guacd
   protocol — which carries RDP credentials in cleartext — must never cross a host-reachable
   TCP interface.
3. **A user may only reach their OWN session.** The relay authenticates the peer via
   `SO_PEERCRED` (kernel-supplied uid, unforgeable) and binds every session UUID and session
   token to that uid. `select $<uuid>` for a foreign UUID, or a token from a foreign uid,
   MUST be refused (join-by-UUID screen-share is a hijack vector).
4. **The relay must send guacd keepalives** (`nop`/`sync` echo) or guacd aborts the session
   (~18 s: "User is not responding" → error 776). Mandatory.
5. **Console (mirror) requires Cockpit administrative access**, enforced server-side by an
   elevation-proven token (not merely hidden in the UI — a client check is cosmetic).
6. **No credential is written to disk by the plugin.** Gate keys are fetched server-side and
   never rendered; grd's own per-session one-time credential is the real per-user secret.
7. **`grdctl` elevates only with `--system`** (re-execs via pkexec). Never call
   `grdctl --system` from a path that would pop a desktop polkit dialog; read config via
   `gsettings`, do root work via the documented privileged helper.
8. **Never signal by process NAME for a shared-uid resource, and never reap logind sessions
   without checking Seat + Class.** (The isolated path shares `/run/user/<uid>` with the
   user's real seat session — see [KNOWN_ISSUES.md](KNOWN_ISSUES.md) I32.)

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for the full register of issues, each with a
mitigation, and [PATTERNS.md](PATTERNS.md) for the reusable design patterns this project
contributes.
