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
 edy-rdp-relay  (runs as the edy-relay uid; AF_UNIX /run/edy-rdp/guacd.sock, 0660 root:cockpit-guac-rdp)
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
  `cockpit-guac-rdp` membership is the coarse gate; SO_PEERCRED is the identity. See
  [GROUP-ACCESS-MODEL.md](GROUP-ACCESS-MODEL.md) for what that gate does and does not grant.
- **Relay↔guacd:** host loopback, nftables owner-gated to the relay uid; not reachable by other local uids.
- **guacd↔desktop:** RDP with NLA over TLS for the gnome-remote-desktop doors, or VNC for the
  Wayland and remote-VNC scenarios. The door key authenticates the RDP transport. On the login
  screen, GDM authenticates the person. On an isolated session, the headless unit's PAM login does.
  A remote host uses the credential typed for that host.

## Scenarios
The Cockpit page's Architecture tab is the operator-facing copy of this list. The relay
resolves each RDP scenario in `_grd_target`. The two VNC scenarios never start a FreeRDP bridge.

1. **Login screen (greeter)** → `127.0.0.1:3390` NLA, server-held door key. GDM authenticates
   the person. gnome-remote-desktop redirects the client onto a headless greeter, then after
   the password onto that user's headless session (`gnome-remote-desktop-daemon --handover`).
   The desktop has no seat. A later connection to the same door is handed to that existing
   session. An unexpected drop of this connection is followed once by a fresh `connect("greeter")`
   (I62). Disconnect, an explained error, and a second drop inside 15 seconds are not.
2. **Console (mirror)** → `127.0.0.1:3389` NLA, `mirror-primary`. Administrative access, plus
   the shadow group when the seated user is someone else. With no seated graphical session,
   the page opens the login screen instead. A headless login-screen desktop has no seat, so
   it does not count.
3. **Virtual monitor** → `127.0.0.1:3389` NLA, `extend`, inside the caller's own session.
4. **Isolated** → the caller's headless GNOME on `127.0.0.1:33000+(uid−1000)`. The relay
   injects the credential from `SO_PEERCRED`. See the section below.
5. **Wayland desktop (VNC)** → per-user sway and wayvnc on `127.0.0.1:34000+(uid−1000)`.
   guacd speaks VNC directly.
6. **Remote host (RDP)** → browser-supplied IPv4, allow-list, FreeRDP bridge, `/cert:tofu`.
7. **Remote host (VNC)** → the same allow-list. guacd's VNC client dials the target directly.

## What is deliberately NOT built
- No noVNC-to-host-desktop (I14: grd has no VNC).
- No per-connection credential minted into credentials.ini (I15/I16: no hot reload, single-valued).
- No client-side-only gate anywhere (I4).

## Session lifecycle & state authority
The **relay is the single writer/authority** of the session registry, persisted to
`/run/edy-rdp/state/sessions.json` (tmpfs; relay-owned `edy-relay:cockpit-guac-rdp`, so it does not survive a
reboot — correct, since live guacd/greeter sessions do not either). The **reaper** (`edy-rdp-reaper`,
root, timer-driven) never edits that file; it prunes THROUGH the relay's control-socket `prune` op
(admin-only) and additionally terminates stale `gdm-greeter` logind sessions via `loginctl`
(the "greeters closed 60s after disconnect unless a logon occurred" policy). This avoids the
two-registries-one-file lost-update trap (see KNOWN_ISSUES I28).

## Isolated scenario: per-user headless sessions (I29)
Isolated is the caller's own headless GNOME session, not the 3390 login screen (that is the
greeter scenario above). The relay routes it as follows:

  browser (Cockpit, authenticated as the user)
    -> relay (SO_PEERCRED uid) : scenario=isolated
       -> systemctl start edy-rdp-headless@<uid>   (polkit-granted; oneshot, idempotent)
          -> headless gnome-shell (PAMName=login logind session) + headless grd on 127.0.0.1:33000+uid-1000
       -> read /run/edy-rdp/headless/<uid>.env (port, ephemeral cred)
       -> REWRITE the guacd connect to that target+cred (browser never handles a credential)
    -> guacd VNC (127.0.0.1:4822, nft uid-gated) -> FreeRDP3 bridge -> RDP+NLA -> the user's own desktop

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
