# Troubleshooting

Diagnostics for the deployed stack. The relay, guacd, reaper and per-user headless
sessions all run in the **system** systemd scope (not `--user`). Nothing listens on a
public port by design — the only ingress is the AF_UNIX socket reached over Cockpit's
HTTPS channel.

## Health checks

| What | Command | Expected |
|---|---|---|
| Relay service | `systemctl status edy-rdp-relay` | `active (running)`, user `edy-relay` |
| Relay + control sockets | `systemctl status edy-rdp-relay.socket edy-rdp-control.socket` | `active (listening)` |
| guacd container | `podman ps --filter name=edy-rdp-guacd` | one running container |
| guacd is loopback-only | `ss -tlnp \| grep 4822` | `127.0.0.1:4822` only — **never** `0.0.0.0` |
| nftables owner-gate | `nft list table inet edy_rdp_guacd` | admits only the `edy-relay` uid |
| Relay socket present | `ls -l /run/edy-rdp/guacd.sock` | mode `0660`, group `cockpit-guac-rdp` |
| Reaper timer | `systemctl status edy-rdp-reaper.timer` | `active (waiting)` |
| Credential rotation | `systemctl list-timers edy-rdp-rotate-rdplogin.timer` | next run shown |
| Start-time bootstrap | `journalctl -u edy-rdp-relay -g bootstrap` | `[bootstrap] env OK`, `prereqs OK`, `venv.env: unchanged` (or `wrote`) at the last start; never a `FAIL` line |
| Interpreter in use | `cat /opt/cockpit-guac-rdp/venv.env` | `EDY_RDP_PYTHON=/usr/bin/python3` while `requirements.txt` is empty; the venv's python3 once it is not |
| Pulse bind (audio) | `mountpoint /run/edy-rdp-pulse/native` + `findmnt -o TARGET,PROPAGATION /run/edy-rdp-pulse` | `is a mountpoint` after a seat login; propagation `shared` |
| Pulse rebind trigger | `systemctl status edy-rdp-pulse-seat@1000.path` | `active (waiting)` (uid from `EDY_RDP_PULSE_SEAT_UID`) |
| Whole-host gate | `sudo ./deploy.sh --verify` | ends `DEPLOY VERIFY OK`; the `install.sh --verify` block inside ends `verify: PASS` |

## Live logs (never contain secrets — the trace redacts them)

```bash
journalctl -u edy-rdp-relay -f          # relay + the edy-rdp-trace logger
podman logs -f edy-rdp-guacd            # guacd backend
journalctl -u 'edy-rdp-headless@*' -e   # a user's isolated desktop lifecycle
```

The relay logs one `accept uid=<n> (<name>)` per connection (the SO_PEERCRED peer
identity) and an `edy-rdp-trace` line per protocol event. Passwords, VNC passwords and
session tokens are always `<redacted:LEN>` — the token is only ever logged as
`session token OK admin=True|False`.

## Symptom → cause → fix

**Relay does not start; the journal shows `[bootstrap] FAIL env: KEY: reason`.** The
relay's `ExecStartPre` (`edy-rdp-bootstrap`) validated `[install path]/.env` and refused
— on purpose: a relay started on built-in defaults it was never configured with is worse
than one that did not start. Fix the named key in `.env` (the reason says what shape it
must have — `host:port`, an absolute path, one of `DEBUG INFO WARNING ERROR`, `0`/`1`, a
group that exists, no `$`, nothing that looks like a secret) and
`systemctl restart edy-rdp-relay.service`. `./install.sh --verify` reports the same
problems without starting anything. A `FAIL prereq <name> ...` line instead means an OS
prerequisite from `requires.txt` is missing or too old: the next line is the exact install
command (`deploy.sh --with-deps` runs it for you; the bootstrap never installs at service
start). A `FAIL venv: ...` line names a venv that could not be built offline — the wheels
for every `requirements.txt` line must be in the payload's `wheels/` (`deploy.sh --wheels`).

**Sound toggle produces nothing; `podman logs edy-rdp-guacd` says `PulseAudio connection
failed`.** The seat's pulse socket is not bound into `/run/edy-rdp-pulse/native`. Check
`journalctl -t edy-rdp-pulse-bind` for the last outcome (`bound ...`, `seat socket absent`
or a real mount error), that `edy-rdp-pulse-seat@<uid>.path` is active for the seat uid in
`.env`, and run `/usr/libexec/edy-rdp/edy-rdp-pulse-bind --check` for the plan. A 1.3.x
`.env` still saying `PULSE_SERVER=unix:/run/pulse.sock` is refused as stale — it is
`unix:/run/pulse/native` now. Details and the live-verification steps: [AUDIO.md](AUDIO.md),
[KNOWN_ISSUES](KNOWN_ISSUES.md) I42.

**`deploy.sh` printed `DEPLOY FAILED (<step>)`.** The step name says which phase died; the
lines above it are the reason (`install.sh` prints `FATAL ...` with the fix).
`(pre-flight)` means nothing on the host was touched — most often the live `.env` carries
a value the new version refuses (the key and reason are named; a 1.3.x `PULSE_SERVER` is
the usual one): fix it and re-run. A deploy that
ends any other way than `DEPLOY OK <version>` did not complete — before 1.4.0 the installer
could stop silently after `ok 3b.` and leave a half-linked host (I41, I43).

**Plugin menu entry missing / stale.** Cockpit caches the package manifest. Hard-reload
(`Ctrl-Shift-R`). A stale copy under `~/.local/share/cockpit/guac-rdp` shadows the system
one — remove it (see [KNOWN_ISSUES](KNOWN_ISSUES.md) I12).

**"invalid or expired session token; reload the page".** The relay was restarted (any
redeploy) after the page loaded — session tokens are in-memory and do not survive a
restart. **Reload the Cockpit tab**; a fresh page registers a fresh token.

**Console refused: "needs administrative access".** Expected for a non-admin. Turn on
**Administrative access** in Cockpit's header (top-right) and reconnect. The gate is
enforced server-side by an elevation-proven token, not a client check (I4).

**Console/virtual fails: "the physical screen is locked" (or a raw `Broken pipe` /
`ERRCONNECT_CONNECT_TRANSPORT_FAILED`).** grd refuses to create a screencast session of a
LOCKED screen (`Session creation inhibited`), so the mirror/virtual scenario cannot start.
**Unlock the physical session** (`loginctl unlock-session <id>`, or at the machine) and
reconnect; consider disabling auto-lock (`gsettings set org.gnome.desktop.screensaver
lock-enabled false`) if it recurs. The relay detects the lock on failure and returns the
clear message; the isolated scenario is unaffected (it is a separate headless session).

**Isolated fails: "could not start isolated session".** The caller already has a
non-headless GNOME desktop on a seat (the guard refuses to hijack a seat session). The
reason is written to `/run/edy-rdp/headless/<uid>.err`. A true isolated-while-locally-
logged-in desktop needs its own runtime dir and is not built yet (see the bridge memory).

**Black frame / connects but no pixels.** Check `podman logs edy-rdp-guacd` for `VNC …
ready` and the relay trace for `bridge READY … vnc=127.0.0.1:<port>`. A black Xvfb almost
always means the bridge's `xfreerdp3` died — see its per-connection log under
`/run/edy-rdp/bridge/`. Confirm the FreeRDP client is v3 (`xfreerdp3 /version`).

**x11vnc exits immediately.** It refuses an Xvfb when `WAYLAND_DISPLAY` /
`XDG_SESSION_TYPE=wayland` are in the environment; the launcher unsets them. If you edited
the launcher, keep the `unset WAYLAND_DISPLAY; export XDG_SESSION_TYPE=x11` lines.

**Session drops at ~18s.** The relay's guacd keepalive (`nop`) is not flowing. Confirm the
relay is the build that answers guacd `sync` directly (it must — this is mandatory).

**guacd reachable from the LAN / another local user.** A regression. guacd must bind
`127.0.0.1:4822` and the `inet edy_rdp_guacd` nftables table must admit only the relay
uid. Re-run `systemctl restart edy-rdp-firewall.service`.

## Session / desktop state

```bash
# live sessions the middleware is tracking (uid, scenario, desktop_id, created):
python3 - <<'PY'
import socket, json
s=socket.socket(socket.AF_UNIX); s.connect("/run/edy-rdp/control.sock")
s.sendall(json.dumps({"op":"list"}).encode()+b"\n")
print(s.recv(65536).decode())
PY
# a user's persistent virtual-desktop identity (primary key + creation time):
sudo cat /run/edy-rdp/headless/<uid>.desktop     # DESKTOP_ID=… CREATED=…
```

A disconnected isolated desktop is **kept for 15 min** so a reconnect resumes the same
desktop (same `DESKTOP_ID`), then the reaper stops it once genuinely idle.

## No exposed API by design
There are no TCP endpoints. The only ingress is the AF_UNIX socket
`/run/edy-rdp/guacd.sock` (guacd data path) and `/run/edy-rdp/control.sock` (the
management API: `list` / `terminate` / `register` / `elevate`), both reached only through
a Cockpit `payload:"stream"` `unix:` channel over the browser's existing HTTPS session.

## Browser observation suite
The Playwright suite lives in the working-tree harness `cockpit-e2e/` (not part of the
installed package). `tests/obs-bridge.spec.js` observes all six scenarios end-to-end as
the non-admin `cptest`; `tests/doc-shots.spec.js` captures the reference screenshots under
[../img](../img). Run with `npx playwright test` from `cockpit-e2e/`.
