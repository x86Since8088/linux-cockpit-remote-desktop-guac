# SPEC — single-port 3389 token-routing multiplexer (design only, NOT built)

Status: **design**. Deferred until native/off-Cockpit ingress is actually needed. The browser path is
fully served by the relay + FreeRDP3 bridge; this spec is for native RDP clients (mstsc/xfreerdp3) and the
NAT case where only **TCP 3389** is open to the host.

## Goal
Let a native RDP client reach any backend desktop (console 3389 / greeter 3390 / a per-user headless
33xxx) through the **single** externally-open port 3389, with NLA/RDSTLS authenticating **end to end**
(client ↔ target grd) — the mux never terminates TLS and never holds a credential — while a session table
gates who may reach what, mirroring the relay's Cockpit-path gates.

## Why it can work: the token lives BEFORE TLS
The RDP connection sequence puts routing data ahead of the TLS handshake:
1. (optional) **RDP_PRECONNECTION_PDU_V2** — arbitrary preconnection blob (PCB). mstsc supports `pcb:s:`;
   this host's xfreerdp3 build exposes no `/pcb` flag (mstsc-first).
2. **X.224 Connection Request** carrying either
   - `Cookie: msts=<routingToken>` — the load-balancer/Session-Broker field. xfreerdp3 `/load-balance-info:`;
     this is the SAME field grd's own Remote-Login redirect uses (`routing token: NNN`).
   - `Cookie: mstshash=<id>` — legacy username hint (short).
3. THEN the RDP Negotiation Request and TLS/CredSSP.

Because (1)+(2) are cleartext and pre-TLS, a byte-level proxy can peek the token and **splice the raw TCP
stream** to the chosen backend without decrypting anything. NLA/RDSTLS then completes directly between the
client and the target grd daemon — the mux is a dumb pipe after routing.

## Components
- **edy-rdp-mux** (new daemon, root or a dedicated uid): listens on `*:3389` (the only firewall-open port).
  For each connection: read up to the X.224 CR (bounded, with a small timeout), extract the routing token,
  look it up in the **shared session table**, and either (a) `splice(2)` the socket to the target
  `127.0.0.1:<port>` for the token's session, recording the live conn under that session; or (b) if there
  is NO token, fall through to the **local console grd** on 3389 (which itself enforces NLA) so plain
  `mstsc host` still reaches the seat, exactly as today.
- **Session table**: REUSE the relay's `SessionTokens` + `SessionRegistry`. A token minted for a desktop
  becomes a **routing token** too. Add a `route` field (target host:port) and mark tokens single-use +
  short-TTL for the native path (a routing token is a bearer value on the wire — same threat model as MS's
  own, mitigated by TTL + single-use + source-binding).
- **grd backends**: 3390/33xxx become `nft` default-deny except from the mux/relay uid (they are today
  reachable on `*` — see I7). The mux is then the sole ingress; 3389-console stays as the tokenless
  fallback.

## Two ways a session/token is established (mirrors the Cockpit path)
1. **Cockpit method** (already built): elevated register/elevate → admin token → the relay records the
   route (e.g. greeter → 3390). The plugin hands the token to a native client out-of-band (copy a
   connect string) OR the browser path is used directly (no mux needed).
2. **3389 security-gate method**: a client connects tokenless to the console grd on 3389, completes NLA
   (grd authenticates it), and grd — via its Server Redirection PDU — issues a **routing token** for the
   next hop. This is exactly the greeter handover flow we already instrumented; the mux consumes that
   token on the client's reconnect and splices to 3390/33xxx.

## Custom-token opportunities in pure RDP (answer to "aside from `token@host:port`")
- `token@host:port` is the *URL* form some clients accept; it maps to the **cookie/username** field, i.e.
  the same X.224 slots below.
- **routingToken** (`Cookie: msts=`) — the real, roomy slot (`/load-balance-info:`). PRIMARY.
- **Preconnection Blob** — arbitrary unicode, mstsc-only here. Good "pick the target" channel for mstsc.
- **mstshash cookie** — short, legacy, universally sent.
- **NLA username multiplexing** — encode `token:user` in the CredSSP username; works everywhere NLA does
  but mixes auth with routing (least clean).

## Security invariants (must hold)
- The mux NEVER terminates TLS and NEVER sees a credential; auth stays end-to-end (client↔grd NLA/RDSTLS).
- A routing token ROUTES and GATES only; it is single-use + TTL'd + bound to the session's owner; a leaked
  token cannot be replayed after use or TTL. Real authentication remains the downstream NLA/RDSTLS.
- Backends (3390/33xxx) are nft default-deny except the mux; the tokenless 3389 console fallback still
  enforces its own NLA.
- Same anti-hijack property as the browser path: token↔session↔owner binding; the mux records the live
  conn under the session so the single-slot rule applies to native clients too.

## Why deferred
The browser path already covers the product; native/NAT ingress is a separate use case. Building the mux
means a new privileged byte-proxy on the one open port — high blast radius — so it should be built only
when that use case is real, with the invariants above as acceptance tests.
