# Architecture — cockpit-guac-rdp

## Goal
Browser-based RDP into this host's gnome-remote-desktop, from inside Cockpit, with **no exposed guacd
port**, **all traffic over TLS**, and **no session hijacking** — two users at once get isolated,
protected sessions.

## Data path
```
 browser ──wss (Cockpit HTTPS, its own cert)──▶ cockpit-ws ──▶ cockpit-bridge  [runs AS the session user]
    │  Guacamole protocol frames over a stream channel:  { payload:"stream", unix:"/run/edy-rdp/guacd.sock" }
    ▼
 edy-rdp-relay  (runs as the edy-relay uid; AF_UNIX /run/edy-rdp/guacd.sock, 0660 root:edy-rdp)
    │  • SO_PEERCRED  → connecting uid (kernel-supplied, unforgeable)   [closes I2/I4]
    │  • guards `select`: `select $uuid` only if uuid∈caller            [closes I2]
    │  • echoes guacd's `sync` as keepalive; blocking sockets (no drop) [I8/I24/I25]
    │  • console scenario requires caller ∈ admin; RDP-target allow-list
    ▼  connects to 127.0.0.1:4822 as the edy-relay uid
 nftables owner-match: ONLY edy-relay uid (+root) may reach 127.0.0.1:4822; all other uids DROPPED  [closes I1/I3]
    ▼
 guacd  (edy-rdp-guacd.service, `podman run --network host`, binds 127.0.0.1:4822, NO -p mapping)
    ▼  guacd's VNC client → loopback VNC (per-connection, password-gated)
 FreeRDP3 bridge  (per connection): x11vnc ── Xvfb ◀── xfreerdp3 ──RDP+NLA/RDSTLS──▶ grd
    ▼
 gnome-remote-desktop   3389 (screen share / virtual monitor / console-mirror) · 3390 (Remote Login)
                        33xxx (per-user headless isolated desktop, loopback-only)
```

### Rendering path: the FreeRDP3 bridge
guacd's *bundled FreeRDP2* cannot negotiate NLA to grd's 3389 nor RDSTLS to the 3390 greeter
(KNOWN_ISSUES I26), so the relay does **not** use guacd's RDP client. Instead, per connection it
starts a bridge — a vanilla **FreeRDP 3** client (`xfreerdp3`) that speaks to grd and draws into a
headless **Xvfb**, published by **x11vnc** on a loopback VNC port — and rewrites guacd's connect to
use guacd's reliable **VNC** client against that port. The VNC leg is password-gated per connection
and the relay injects the password, so no other local user can attach. The bridge is torn down when
the connection closes; the backing grd desktop persists for reconnect.

## Why not just "bind guacd to loopback"
`-b 127.0.0.1` removes NETWORK reach but not LOCAL reach — every local uid can open host loopback.
The nftables `meta skuid` owner-match adds the missing per-uid gate so only the relay's uid reaches
guacd; the relay then authenticates the human via SO_PEERCRED. (A private netns/pod also isolates the
port, but breaks grd's 3390 RDSTLS handover — see KNOWN_ISSUES I26 — so host-netns + nft is preferred.)

## Why a relay at all
guacd has no auth (I1) and no AF_UNIX support (only `-l/-b`). Binding it to host 127.0.0.1 still lets
every local user connect and hijack by UUID (I2). So guacd binds host loopback with no host port and an
nftables owner-match drops every uid but the relay's, and a small stdlib-Python relay becomes the sole
ingress: it terminates the AF_UNIX socket, authenticates the peer by SO_PEERCRED, enforces per-user UUID
ownership and the console-admin gate, adds keepalives, and only then relays to guacd on host loopback.

## Trust boundaries
- **Browser↔Cockpit:** TLS, Cockpit's existing PAM session. Who you are = your Cockpit login.
- **Cockpit-bridge↔relay:** AF_UNIX; bridge connects as the user, so SO_PEERCRED = that user. Group
  `edy-rdp` membership is the coarse gate; SO_PEERCRED is the identity.
- **Relay↔guacd:** host loopback, nftables owner-gated to the relay uid; not reachable by other local uids.
- **guacd↔grd:** RDP/NLA over TLS; the gate key authenticates the transport, GDM/PAM authenticates the
  real user (isolated scenario).

## Scenarios (map to the four the user defined)
1. **Isolated / virtual monitor** → relay→guacd→3390 (isolated, greeter+PAM) or 3389 `extend`.
   Gate key fetched server-side, never shown.
2. **Console (mirror)** → 3389 `mirror-primary`; relay enforces admin.
3. **MSTSC /admin (native client, mirror)** → future freerdp-proxy on 3389→routes /admin to mirror.
4. **MSTSC without /admin (native client)** → proxy routes to isolated/virtual + shims.
(3–4 are the native-client extension; the Cockpit path covers 1–2 first.)

## What is deliberately NOT built
- No noVNC-to-host-desktop (I14: grd has no VNC).
- No per-connection credential minted into credentials.ini (I15/I16: no hot reload, single-valued).
- No client-side-only gate anywhere (I4).

## Session lifecycle & state authority
The **relay is the single writer/authority** of the session registry, persisted to
`/run/edy-rdp/state/sessions.json` (tmpfs; relay-owned `edy-relay:edy-rdp`, so it does not survive a
reboot — correct, since live guacd/greeter sessions do not either). The **reaper** (`edy-rdp-reaper`,
root, timer-driven) never edits that file; it prunes THROUGH the relay's control-socket `prune` op
(admin-only) and additionally terminates stale `gdm-greeter` logind sessions via `loginctl`
(the "greeters closed 60s after disconnect unless a logon occurred" policy). This avoids the
two-registries-one-file lost-update trap (see KNOWN_ISSUES I28).

## Isolated scenario: per-user headless sessions (I29)
"Isolated" no longer means the 3390 GDM greeter (its RDSTLS handover is broken upstream). Instead the
relay routes it to the caller's OWN headless GNOME session:

  browser (Cockpit, authenticated as the user)
    -> relay (SO_PEERCRED uid) : scenario=isolated
       -> systemctl start edy-rdp-headless@<uid>   (polkit-granted; oneshot, idempotent)
          -> headless gnome-shell (PAMName=login logind session) + headless grd on 127.0.0.1:33000+uid-1000
       -> read /run/edy-rdp/headless/<uid>.env (port, ephemeral cred)
       -> REWRITE the guacd connect to that target+cred (browser never handles a credential)
    -> guacd (127.0.0.1:4822, nft uid-gated) -> RDP+RDPGFX -> the user's own desktop

Isolation is by construction: the relay injects the target from the kernel-supplied uid, so a caller
can only reach their own session. The headless RDP ports are loopback-only (nft). The reaper stops an
idle desktop once its registry entry is pruned (reconnectable until then).

## Remote-host scenario (RDP into another machine)
The three local scenarios all resolve to a loopback grd target. The **remote** scenario is
the one case where the target is off-box and browser-chosen: the plugin sends a
`remotehost=<ipv4>:<port>` marker (through Guacamole `enc()`, stripped server-side like the
other markers) plus the user's `rdpcred`. The relay resolves it in `_grd_target` and — before
any `DESKTOP_SLOTS.claim` or `bridge.start_bridge` side effect — validates it to a strict
IPv4 literal and checks it against the admin-configured `EDY_RDP_REMOTE_ALLOW` (fail-closed:
empty = deny all). Only then does the FreeRDP 3 bridge dial the remote host (with `/cert:tofu`
instead of `/cert:ignore`), still re-serving over the loopback VNC leg so guacd never dials
the remote host itself. The user's credential is used only for that connection and is never a
relay-managed credential. This keeps the guacd-only-dials-loopback and single-target-decision
invariants intact while adding an off-box capability that is gated, not open. See
KNOWN_ISSUES I33–I35 for the SSRF/injection/MITM analysis.
