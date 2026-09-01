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
| Relay socket present | `ls -l /run/edy-rdp/guacd.sock` | mode `0660`, group `edy-rdp` |
| Reaper timer | `systemctl status edy-rdp-reaper.timer` | `active (waiting)` |
| Credential rotation | `systemctl list-timers edy-rdp-rotate-rdplogin.timer` | next run shown |

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

**Plugin menu entry missing / stale.** Cockpit caches the package manifest. Hard-reload
(`Ctrl-Shift-R`). A stale copy under `~/.local/share/cockpit/guac-rdp` shadows the system
one — remove it (see [KNOWN_ISSUES](KNOWN_ISSUES.md) I12).

**"invalid or expired session token; reload the page".** The relay was restarted (any
redeploy) after the page loaded — session tokens are in-memory and do not survive a
restart. **Reload the Cockpit tab**; a fresh page registers a fresh token.

**Console refused: "needs administrative access".** Expected for a non-admin. Turn on
**Administrative access** in Cockpit's header (top-right) and reconnect. The gate is
enforced server-side by an elevation-proven token, not a client check (I4).

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
