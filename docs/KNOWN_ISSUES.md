# Known issues register — cockpit-guac-rdp

Every issue discovered while investigating browser-based RDP into gnome-remote-desktop (grd) 50.2 on
edt1, each with severity, root cause, mitigation, and the phase/task that owns it. "Verified" means
observed directly this cycle, not inferred.

Legend — Sev: **C**ritical / **H**igh / **M**edium / **L**ow. Status: OPEN / MITIGATED / BY-DESIGN / WONTFIX.

## Security — the reason this project exists

### I1 · guacd has NO authentication on 4822 · Sev C · OPEN→(design closes)
Verified: guacd's entire access surface is `-l PORT -b ADDRESS -C cert -K key`. The protocol handshake
has no auth step (`select rdp` → `ready`); the RDP username/password in `connect` authenticate to grd,
not to guacd. TLS via `-C/-K` is server-side only (no `SSL_CTX_set_verify`), so it encrypts but
authenticates nobody. **Mitigation (shipped):** guacd binds 127.0.0.1:4822 only, and an nftables
owner-match drops every uid but the relay's; a relay in front authenticates the peer by SO_PEERCRED.
(A pod netns was evaluated but rejected — it breaks grd's 3390 RDSTLS handover, see I26.) Owner: Task 1–2.

### I2 · Session hijack by join-by-UUID · Sev C · VERIFIED · OPEN→(design closes)
Verified live: a second guacd client issuing `select $<existing-uuid>` joined the *same live session*
with NO credential of any kind ("JOIN SUCCEEDED"). This is Guacamole screen-sharing; guacd trusts any
caller. **Mitigation:** the relay owns UUIDs — records `ready $uuid` → SO_PEERCRED uid, and refuses any
`select $uuid` whose owner uid ≠ caller uid. Clients never get to pick a foreign UUID. Owner: Task 2.

### I3 · guacd protocol (with RDP creds) crossed host 127.0.0.1:4822 in cleartext · Sev H · OPEN→closed
The Guacamole protocol is plaintext; RDP credentials pass through it. Today it rides host loopback TCP,
readable by any local user who can connect. **Mitigation (shipped):** the nftables owner-match on
127.0.0.1:4822 admits only the relay uid, so no other local user can reach the guacd protocol; the
sole app ingress is the AF_UNIX socket reached over Cockpit's TLS session. Owner: Task 1–2.

### I4 · Console gate is cosmetic (client-side JS) · Sev H · VERIFIED · OPEN→(design closes)
The current `if (t.admin && !isAdmin)` check is browser-side and trivially bypassed by driving the
tunnel directly. **Mitigation:** relay enforces console/mirror scenarios require the caller to be an
admin (polkit/`cockpit.permission` proof relayed, or uid∈admin group checked server-side). Owner: Task 2,4.

### I5 · grd one-time credential broadcast on D-Bus to any local user · Sev H · VERIFIED · OPEN
`org.gnome.RemoteDesktop.conf` grants `context="default"` (any local user) send access to
`Rdp.Handover`/`Rdp.Dispatcher`, and an unprivileged user can `signal_subscribe` to `RedirectClient
(sss)` = (routing_token, username, password). **Mitigation:** tighten that D-Bus policy so only
`gnome-remote-desktop` and `gdm` may send/receive; ship the hardened policy drop-in. Owner: Task 5.

**UPDATE (2026-09-01, see I29 addendum 4):** the *broadcast* vector — the `TakeClientReady` signal grd
emits with no destination — is now closed at the source by the grd handover patch, which removes that
signal entirely (method call instead). The other credential-bearing signal, `RedirectClient`, is emitted
**directed** (unicast to the handover daemon's connection), so it is not deliverable to other local users'
subscriptions in the first place. Consequently the drop-in's *receive*-deny was both unnecessary and
harmful: it blocked the legitimate greeter daemon, which runs as the DynamicUser `gdm-greeter` (no stable
uid, so a `user=` allow can never match it). The shipped `handover.conf` now keeps only the send-side
denies. Residual note: this posture depends on the grd patch staying deployed (an apt upgrade to stock grd
re-introduces the `TakeClientReady` broadcast). Effective severity now Low with the patch in place.

### I6 · 3390/3389 gate key stored recoverable; TPM sealing broken · Sev M · VERIFIED · OPEN
`credentials.ini` holds the gate password as recoverable plaintext (grd recomputes the NT hash per
connection). TPM sealing fails (`tcti: IO failure`) because uid 980 (`gnome-remote-desktop`) is not in
group `tss` while `/dev/tpmrm0` is `crw-rw---- tss:tss`. **Mitigation:** add the daemon user to `tss`
and restart; document that file perms are the only protection until then. Owner: Task 5.

### I7 · 3389/3390 bind `*`, ufw inactive · Sev H · VERIFIED · OPEN
Both RDP daemons are LAN-reachable. NLA is mandatory so a key is needed, but the surface is wide.
**Mitigation:** firewall 3389/3390/3391 to loopback + the podman bridge only; the browser path does not
need them on the LAN. NOTE the firewall rule must allow the podman bridge address (guacd reaches the
host as src=dst=192.168.2.14 here) or it severs its own data path. Owner: Task 5.

## Correctness — fixed this cycle; encode as regression tests

### I8 · Missing tunnel keepalive → session aborts ~18s · Sev H · VERIFIED · FIXED
guacd drops a quiet client ("User is not responding" → error 776). A custom tunnel must send `nop`
periodically (Guacamole's own WebSocketTunnel does). **Test:** session survives >30s. Owner: Task 2,4.

### I9 · z-index:-1 layers hidden behind opaque panel bg → black screen · Sev H · VERIFIED · FIXED
Guacamole stacks layer canvases at `z-index:-1`; an opaque `#display` with no stacking context hides
them (only the cursor, on a separate layer, shows). **Fix:** `isolation:isolate` on `#display`.
**Test:** CSS invariant (opaque bg ⇒ stacking context), since canvas readback can't see compositing. Owner: Task 2,4.

### I10 · Cockpit stream `binary:"raw"` mangled the handshake · Sev H · VERIFIED · FIXED
The guac protocol is UTF-8 text; use text stream mode, not `binary:"raw"`. Owner: Task 2.

### I11 · base1/cockpit.css does not exist; inline <script> blocked by CSP · Sev M · VERIFIED · FIXED
Cockpit ships only `base1/cockpit.js`; a `<link>` to cockpit.css 404s and trips nosniff. Inline scripts
violate `default-src 'self'`. **Fix:** ship own CSS, external JS only. **Test:** no CSP refusals. Owner: Task 2,4.

### I12 · Stale plugin copy in a user's ~/.local shadows /usr/share · Sev M · VERIFIED · MITIGATED
A per-user cockpit package dir shadows the system one; a renamed dir still loads as a duplicate menu
entry. **Mitigation:** installer notes; uninstall guidance; don't leave superseded dirs in the package path. Owner: Task 6.

### I13 · Disconnect leaks GDM greeter sessions on 3390 · Sev M · VERIFIED · OPEN
Closing the channel does not reap the greeter behind a Remote-Login connection; 22 accumulated this
cycle. **Mitigation:** a reaper (systemd timer) that terminates idle `gdm-greeter` sessions with no
attached RDP client; or a session-idle policy. Owner: Task 5.

## Platform facts that constrain the design (not bugs)

### I14 · grd is RDP-only; no VNC backend · BY-DESIGN
`grdctl` has no `vnc` subcommands; the vnc gsettings schemas are vestigial. Console access must be RDP
`mirror-primary`, not VNC. Recorded so no one wastes time wiring noVNC to the host desktop.

### I15 · No credential hot-reload on the 3390 system daemon · BY-DESIGN
The file backend loads credentials.ini once at process start; applying a change needs a restart, which
drops every live session. So "mint temp cred in credentials.ini per connect" is not viable on 3390.
3389 (libsecret) IS looked up live per connection. Per-session credentials already exist as grd's
handover one-time credential — use that, don't reinvent it.

### I16 · grd credentials.ini is single-valued · BY-DESIGN
One `[RDP]` group, one key. Writing a second name overwrites the first. Concurrency comes from separate
daemons/handover, not multiple entries.

### I17 · Kerberos NLA blocked in the system daemon · BY-DESIGN
grd errors "Kerberos not supported in the system daemon"; Kerberos NLA is available on 3389/headless
only, and needs an AD/KDC join. Relevant if per-user network auth is pursued later.

### I18 · grd is gfx-only; needs RDPGFX + 32bpp · BY-DESIGN
No legacy bitmap fallback. guacd 1.6 negotiates RDPGFX fine; color-depth<32 is ignored. Recorded so a
"reduce color depth" tuning attempt isn't mistaken for a fix.

### I19 · MSTSC /admin (console) flag ignored by grd · VERIFIED · BY-DESIGN
grd has zero console-session handling; `+admin` still yields the virtual monitor. The proxy (Task) must
implement /admin routing itself (3389 mirror vs 3390/3391), post-NLA.

## Operational

### I20 · Rootless podman port-forward / netns dies silently · Sev M · VERIFIED · MITIGATED
`podman ps` showed a mapping while nothing listened (rootlessport gone); `podman system migrate`
repaired it but stopped other rootless containers. **Mitigation:** run guacd as a pod under a systemd
(quadlet) unit with restart; health-check the socket; document `system migrate` side effects. Owner: Task 1,5.

### I21 · grdctl elevates only with --system (pkexec) · VERIFIED · BY-DESIGN (footgun)
`grdctl --system` re-execs via pkexec (auth_admin_keep → first call pops a desktop dialog, rest cached).
Plain `grdctl` does not elevate. The re-exec strips `--system`, so audit logs are misleading (tell by
TTY). Read config via `gsettings`; do root writes via the privileged helper, never a shell `grdctl --system`. Owner: all.

### I22 · openssl MD4 needs the legacy provider · Sev L · VERIFIED
Any NT-hash tooling: `iconv -f utf-8 -t utf-16le | openssl dgst -provider legacy -provider default -md4`.

### I23 · WinPR SAM line needs ≥4 colons · Sev L · VERIFIED
`user:::<32-hex-NT>:::` — a 3-colon line fails `SamOpen` (or lands the hash in the LM slot).

## Found during install testing (2026-08-30)

### I24 · Relay must ECHO guacd's sync, not send nop · Sev H · VERIFIED · FIXED
guacd measures client liveness by the client echoing its `sync <timestamp>`; a bare `nop` does not
count, so sessions died at guacd's 30s timeout ("User is not responding"). The relay now captures the
last guacd `sync` and echoes it on the keepalive interval. Owner: relay. Test: `SyncKeepalive`.

### I25 · Relay non-blocking sockets + sendall dropped data · Sev C · VERIFIED · FIXED
The relay set both sockets non-blocking but used `sendall`, which silently drops on EAGAIN when a
frame burst overflows the send buffer — losing frames and sync echoes. Fixed: sockets stay BLOCKING;
`select` is used only for read-readiness, so `sendall` always completes (natural backpressure).

### I26 · Isolated (3390) handover does not render inside the pod netns · Sev H · VERIFIED · OPEN
Through the deployed pod, 3389 (virtual/mirror, no redirect) renders fully (12 MB / ~1900 frames in
42s), but 3390 (Remote Login) delivers 0 frames: guacd reaches grd 3390 (CLIPRDR/rdpdr/rdpsnd SVCs
connect) and the client goes `ready`, but grd's **RDP server-redirection handover** reconnect does
not complete from inside the pod network namespace, so no framebuffer arrives. On the host (old
non-pod guacd) the same 3390 greeter rendered. Not a relay bug (a raw socket client sees the same 0
frames). Likely the redirect's target address does not resolve to grd from inside the pod netns.
**Mitigations to try:** `hostAliases` mapping grd's redirect target to the host in the pod; or a
dedicated pod network that can route to the redirect target; NOT hostNetwork (would put guacd's 4822
on the host, violating I1). **Meanwhile:** the mirror (console) and virtual-monitor scenarios (both
3389) work end-to-end through the deployed stack; isolated/3390 works with a native client
(xfreerdp3/mstsc) directly. Owner: a follow-up task.


## Architecture change (2026-08-30): pod -> host-loopback guacd + nftables uid-gate

The pod was replaced. guacd now runs in the HOST network namespace bound to 127.0.0.1:4822
(`edy-rdp-guacd.service`, `podman run --network host`), and access is restricted by an nftables
**owner-match**: only the `edy-relay` uid (and root) may connect to 127.0.0.1:4822; every other local
uid is DROPPED (`hardening/edy-rdp-guacd.nft`). This closes I1/I2/I3 *without* network isolation —
verified: eddie (uid 1000) is blocked from :4822, the relay (edy-relay) reaches it, and 3389 renders
14.6 MB / 5800 frames through the full chain. The relay, its SO_PEERCRED auth, UUID binding, console
gate, allow-list, keepalive and blocking-socket fix are unchanged.

### I26 — RE-ATTRIBUTED: isolated (3390) is a guacd/FreeRDP-2 limitation, NOT a pod/netns issue
My earlier claim that the pod netns broke the 3390 handover was WRONG. Tested directly: host-netns
guacd ALSO returns 0 frames for 3390. Root cause confirmed: **guacd 1.6.0 links FreeRDP 2.11.7, which
has NO RDSTLS support** (zero rdstls symbols in libfreerdp2.so.2.11.7), and grd's 3390 Remote-Login
handover requires the client to reconnect via **RDSTLS** after the server-redirection PDU. So guacd
connects, gets the redirect, cannot do RDSTLS, and no framebuffer arrives — pod or host-netns alike.
FreeRDP 3.30 (xfreerdp3/mstsc) has RDSTLS, so native clients render 3390 fine.
**Fix options:** (a) a guacd built against FreeRDP 3 (the durable fix); (b) route isolated/3390 to
native RDP clients, not the browser; (c) offer only mirror/virtual (3389, no redirect) in the browser.
Mirror + virtual-monitor render fully through guacd today.

## Management API + Disconnect cleanup (2026-08-30)

Added a control API on a second socket-activated AF_UNIX socket
`/run/edy-rdp/control.sock` (0660 group edy-rdp, `edy-rdp-control.socket`):
- `control.py` — `handle_control()` (list/terminate/ping), `LiveConnections` (uuid->terminate).
- Auth by SO_PEERCRED: a user sees/terminates only their own sessions; an admin (or root) all.
- Relay registers each live connection so `terminate` actually closes it (verified: terminate ->
  terminated_live=true, data session closed, gone from list).
- Plugin "Active Sessions" tab lists sessions with a Terminate button; the Disconnect (#stop)
  button calls `terminate` (begin backend cleanup), then the graceful guac `disconnect`, then
  reloads the guac display element (#display cleared for a fresh connect).

### I27 · Browser-path sessions hit guacd "User is not responding" · Sev M · FIXED
Under the plugin (browser) path, guacd sometimes declares the client unresponsive and closes the
session (~30s, or faster under rapid connect/disconnect churn), even though the relay echoes guacd's
`sync`. Socket-level clients that echo `sync` every frame stay up 45s+ and render fully (5800 frames),
so the relay/guacd plumbing is sound; the gap is the browser (guacamole-common-js) sync-echo cadence,
especially in a backgrounded/headless tab. Console rendered fine interactively, so normal use works;
this mainly destabilises automated rapid-cycle tests. Follow-up: have the relay drive sync echoes more
aggressively (echo each guacd sync immediately rather than on a 4s keepalive), independent of the
browser tab state.

**FIXED:** the relay now echoes EACH guacd `sync` back to guacd the instant it
arrives (in addition to the 4s keepalive), so guacd's client stays responsive regardless of the
browser tab. Both browser-path Playwright tests (list+terminate, disconnect+cleanup) pass reliably.

### I28 · Session registry never persisted; reaper pruned a phantom file · Sev M · FIXED
The relay runs as `edy-relay` but the state dir `/run/edy-rdp` was created `0750 root:edy-rdp`
(group has only `r-x`), so the relay could not create its atomic temp file and every persist
silently failed (`_persist_locked` swallows `OSError`). Session state therefore lived only in the
relay's memory: it did NOT survive a relay restart, contradicting the lifecycle requirement that
registry state persist.

Compounding it, the reaper was a SECOND process with its OWN `SessionRegistry` loaded from that same
file. Even after fixing perms, a reaper that prunes the file is futile: the relay is the live
authority and re-persists its in-memory registry over any change, so pruned entries reappear (a lost
update). The two registries could never converge on one file.

**FIXED (2026-08-30):**
* The relay is now the SOLE writer/authority of the registry. State moved to a relay-owned subdir
  `/run/edy-rdp/state` (`0750 edy-relay:edy-rdp`, via tmpfiles) so `edy-relay` can write atomically;
  the socket dir stays `root:edy-rdp` non-group-writable so a group member cannot unlink the sockets.
* A `prune` op was added to the control API (admin-only; the reaper is root). The reaper now prunes
  THROUGH the relay's control socket instead of editing the file behind its back, and still performs
  the OS-level `gdm-greeter` reap via loginctl. `--state-file` was removed from the reaper.
* Verified on the deployed host: `edy-relay` writes+reloads the registry at the new path; the live
  relay answers `prune` (`{"ok":true,"reaped":[...]}`); the reaper runs the control path cleanly.
  46 unit tests pass (4 new `prune` tests).

Residual (Sev L): the relay↔file is single-writer, but if a future change re-introduces a second
writer, atomic-replace lost-update semantics return; keep the relay the only writer.

### I29 · Isolated session delivered via per-user HEADLESS grd (greeter handover unfixable) · RESOLVED
The GDM greeter path (3390 Remote Login) cannot be made to work on this host: with grd debug
logging, the system daemon receives the RDSTLS reconnect (`Incoming connection with routing token`)
and emits `TakeClientReady`, but the greeter's handover daemon never receives that signal
(`StartHandover` works, the signal back does not) → 30s `MAX_HANDOVER_WAIT_TIME_S` → `abort_handover`
(`grd-daemon-system.c`). It fails for native xfreerdp3 too, so it is not a guacd/client issue; the gsd
network-status bug (65b257b6) is already fixed in gsd 50.0; and no fixed grd/gsd is packaged for
26.04 (checked -updates and -proposed). guacd's own FreeRDP2 also lacks RDSTLS, and a from-source
FreeRDP3 guacd regressed 3389 rendering.

**RESOLVED by a different mechanism — a per-user HEADLESS GNOME session over plain RDP (no handover):**
* `edy-rdp-headless@<uid>.service` (root, oneshot, RemainAfterExit) brings up, idempotently:
  a headless `gnome-shell --wayland --headless --no-x11` in a REAL logind session
  (`systemd-run --property=PAMName=login`; a bare shell runs "outside a user session" and only the
  background composites) with the user in `render`+`video` (headless users get no /dev/dri ACL); then
  the **headless** grd scope (file-based creds, no keyring) on a deterministic LOOPBACK port
  `33000 + uid-1000`. **Do NOT pre-create a `--virtual-monitor`** — grd makes the monitor on connect,
  and a pre-made one gets captured empty. An ephemeral gate credential is written to
  `/run/edy-rdp/headless/<uid>.env` (root:edy-rdp 0640).
* The ports are reachable only via loopback (`hardening/edy-rdp-headless.nft`, verified with a netns
  test); guacd on the host dials 127.0.0.1:<port>.
* The relay routes the **isolated** scenario to the CALLER'S OWN session: it starts the unit
  (polkit grant `edy-relay -> edy-rdp-headless@*`), reads port+cred, and REWRITES the guacd connect
  from the SO_PEERCRED identity. The browser supplies and sees no credential; a caller can only reach
  their own desktop. Cold start ~20-30s (guacd tolerates the wait); warm reconnects are instant.
* The plugin's "Isolated" is one click (no sign-in UI). The reaper keeps a disconnected desktop while
  its registry entry survives (reconnectable) and stops it once pruned (idle > SESSION_DISCONNECT_TTL).
* Verified: native xfreerdp3 full desktop (8873 colours); guacd render (no errors); browser e2e
  (`isolated-headless.spec.js`) green. Recipe in memory `edt1-headless-isolated-session`.

The 3390 greeter remains OPEN upstream; the plugin no longer uses it.

### I29 addendum (2026-08-31, post-reboot) — greeter failure is NOT policy-fixable
A reboot did NOT fix the 3390 handover (rules out stale grd/dbus state). Root-caused deeper with
dbus-monitor + Gio subscribers: the system daemon (:owner of org.gnome.RemoteDesktop) broadcasts
`TakeClientReady` (dbus-monitor sees it, destination=null, same sender as the ObjectManager
`InterfacesAdded` signals), BUT the bus does NOT deliver it to any normal subscriber — a plain Gio
client (even sender=None, interface=Handover) receives grd's ObjectManager signals yet never the
Handover-interface signals, so the greeter's handover daemon never calls TakeClient → 30s abort.
This is interface-scoped and survives a maximally-permissive D-Bus policy drop-in
(`receive_sender`/`receive_interface`/`send_interface`/`send_type=signal` all allowed) — so it is
NOT a dbus policy gap. dbus is 1.16.2; default policy already allows send+receive of signals. The
defect is in grd/GDBus signal emission (or a dbus-daemon quirk with these object-manager child
signals); a fix would require patching gnome-remote-desktop, which is uncertain. The isolated
scenario stays on the working headless path.

### I30 · nftables rules were not persistent across reboot (guacd owner-match lost) · FIXED
The security-critical rules (guacd :4822 owner-match, headless :33000-33999 loopback-only) were only
loaded live by install.sh into /etc/nftables.d/, but this host uses **ufw** and `nftables.service` is
disabled, so nothing loaded /etc/nftables.d on boot -> after a reboot 4822 was world-reachable again
(session-hijack exposure re-opened) and the headless loopback rule was entirely missing (never copied
to /etc/nftables.d in the earlier build-out). FIXED: added `edy-rdp-firewall.service` (oneshot,
RemainAfterExit, Before=edy-rdp-guacd/relay, WantedBy=multi-user.target) that delete-then-loads both
rule files on every boot; install.sh installs+enables it, uninstall removes it. Verified active +
enabled + ordered before guacd, and both tables reload idempotently.

### I29 addendum 2 (2026-08-31) — grd source patch attempted (directed signal), did NOT fix it
Built patched grd 50.2 that emits TakeClientReady DIRECTED to the handover daemon (mirroring how grd
already emits RedirectClient) instead of broadcasting it. Confirmed effective on the bus (dbus-monitor:
`TakeClientReady ... destination=:1.NNNN`, and for the same session that :1.NNNN is EXACTLY the
connection that called StartHandover, i.e. the real --handover daemon). Yet the handover daemon's
GDBus still never logs receiving it (G_DBUS_DEBUG=signal shows NameAcquired but never TakeClientReady)
and never calls TakeClient -> still aborts. So the failure is deeper than broadcast-vs-directed: even a
correctly-addressed directed signal to the live handover-daemon connection is not delivered/dispatched,
while that same connection successfully CALLS methods (StartHandover) on the bus and RECEIVES
NameAcquired + grd's ObjectManager broadcasts. This is a grd/GDBus/dbus-daemon signal-delivery anomaly
specific to the Handover interface that a from-source directed-emit patch does not resolve. The patched
binary was REVERTED (system back to the stock, dpkg-verified daemon). A working fix would need deeper
grd surgery (e.g. replace the signal handshake with a method call the system daemon makes to the
handover daemon, requiring changes on both sides) — uncertain. The isolated scenario stays on the
working headless path. Patch preserved at source/patches/grd-handover-takeclientready-directed.patch.

### I29 addendum 3 (2026-09-01) — ✅ GREETER FIXED with a both-sides method-call patch
The literal 3390 Remote-Login greeter now works end-to-end. The fix follows exactly the "method call on
both sides" direction addendum 2 flagged as the likely path. It ELIMINATES the undeliverable
`TakeClientReady` signal from the handshake and drives the client-FD hand-off with method calls only
(method calls ARE delivered on this bus; only Handover-interface *signals* are not):

* **Handover daemon** (`grd-daemon-handover.c`): after `StartHandover` returns cert/key, it calls
  `TakeClient` **proactively** — before the redirected client reconnects — guarded by a new
  `take_client_requested` flag (also guards the now-dead `on_take_client_ready` signal path).
* **System daemon** (`grd-daemon-system.c`): `on_handle_take_client` no longer requires
  `socket_connection`. If the client has not reconnected it stores the invocation in a new
  `pending_take_client_invocation` field and returns HANDLED; `on_incoming_redirected_connection` then
  completes the pending call with the client FD (via a new `complete_take_client` helper) instead of
  emitting `TakeClientReady`. Either ordering (TakeClient-first or reconnect-first) resolves through
  `socket_connection`. `abort_handover` and `grd_remote_client_free` return an error on any still-pending
  invocation so the handover daemon can never hang.

**Proof (native xfreerdp3 → 127.0.0.1:3390):** GDM greeter renders; mouse click selects a user; the
password field accepts typed input; a correct password lands the user's GNOME desktop. Server journal:
`received StartHandover call` → `Sending server redirection` → `received TakeClient call` (this arrives
**before** `Incoming connection with routing token` — proof the proactive method call ran) → **no**
`Aborting handover` (no 30 s timeout). Two non-grd gotchas surfaced while testing and are recorded so
they are not re-diagnosed as grd bugs:
  1. **Door credential required.** grd Remote Login needs an RDP "door" credential in the system SAM
     (`grdctl --system rdp set-credentials rdplogin <key>`); with an empty credentials.ini the client
     dies at NLA with `ntlm_fetch_ntlm_v2_hash: Could not find user in SAM` / `SEC_E_NO_CREDENTIALS`,
     well before the handover. The real user login still happens at the GDM greeter (see I15/I16).
  2. **FreeRDP3 client defaults to Kerberos.** This host is AD-joined (realm AD.EDT1.LAB), so winpr
     tries Kerberos first; for a local door user it fails to get a TGT then falls back to NTLM, which
     succeeds against the door SAM. (`/auth-pkg-list` did not suppress the Kerberos attempt but the NTLM
     fallback works, so it is harmless noise.)

Patch: `source/patches/grd-handover-method-call.patch` (README updated). Deployed over
`/usr/libexec/gnome-remote-desktop-daemon` (stock backed up to `.orig-edt1`); one binary serves both
`--system` and `--handover`. NOTE: an apt upgrade of gnome-remote-desktop overwrites the daemon —
re-apply after upgrades. **guacd (FreeRDP2) still cannot drive 3390** (no RDSTLS), so the browser plugin
keeps the headless per-user isolated path; the greeter fix serves native RDSTLS clients (xfreerdp3,
mstsc) directly. I13 (greeter session leak) reaping still applies to any 3390 sessions that are created.

### I29 addendum 4 (2026-09-01) — ✅ FULL login→DESKTOP; the SECOND handover + the real I5/gdm-greeter fix
Addendum 3 fixed the *greeter render*. Driving an actual login revealed a SECOND handover — the greeter
session hands the client over to the **user's** session after authentication — and a second, distinct
failure that had to be fixed for login to reach a desktop. The full chain now works end-to-end:
door NLA → greeter → GDM login → **greeter→user-session handover → full user desktop** (verified with a
screenshot of rdptest's Ubuntu 26.04 desktop over native xfreerdp3 → 127.0.0.1:3390).

**Root cause of the second-handover failure — and of the ORIGINAL "signal never delivered" symptom:**
the project's own I5 hardening drop-in `org.gnome.RemoteDesktop.handover.conf` denied `context="default"`
from *receiving* Handover-interface signals, allow-listing only users `gnome-remote-desktop` and `gdm`.
But the remote-login greeter runs as the **systemd DynamicUser `gdm-greeter`**, whose uid is allocated
per greeter session (observed 60595, 60597, 60598, …) and has **no stable passwd entry**, so a
`<policy user="gdm-greeter">` rule can never resolve to a uid and never matches. The system daemon's
`RedirectClient` signal (which carries the routing token to move the client into the user session) was
therefore rejected — `dbus-daemon: Rejected receive message … member="RedirectClient" … destination=(uid
60598, comm=…--handover)` — so the greeter never redirected the client, the user-session grd's TakeClient
timed out, and login dead-ended at a dark screen. This same receive-deny was almost certainly the true
cause of the original "TakeClientReady never delivered" symptom (mis-attributed to a deep GDBus anomaly).

**Fix (policy v2):** removed the receive-deny from `handover.conf`, keeping only the send-side denies as
defense-in-depth. This is safe because: (a) the grd patch (addendum 3) ELIMINATED the only *broadcast*
Handover signal, `TakeClientReady` — the real I5 exposure; and (b) the remaining Handover signal,
`RedirectClient`, is emitted **directed** (`destination=:1.NNNN`), which the bus delivers only to that one
connection — other local users cannot subscribe to it, and the base policy grants eavesdropping only to
root. So I5's practical exposure stays closed while the legitimate dynamic-uid greeter daemon can receive
its directed signal. Confirmed clean: `received StartHandover` → `Sending server redirection` →
`received TakeClient` → `Incoming connection with routing token` with **no** `Rejected receive` and **no**
`Aborting handover`. Updated `source/hardening/org.gnome.RemoteDesktop.handover.conf` (see its header for
the full rationale and the patch-dependency note). See also I5 below — its broadcast vector is now closed
by the grd patch rather than by a receive-deny.

**Net state of the 3390 greeter path:** fully working for native RDSTLS clients (xfreerdp3, mstsc). Two
pieces are required together — the grd method-call patch AND handover.conf policy v2 — plus a configured
door credential (`grdctl --system rdp set-credentials rdplogin <key>`). guacd (FreeRDP2) still cannot do
RDSTLS, so the browser plugin's Isolated scenario keeps the per-user headless path; the greeter is the
native-client route.

### I31 · Greeter gnome-shell/mutter crashes on RDP DISCONNECT (upstream GNOME 50) · Sev M · VERIFIED · UPSTREAM
Now that the 3390 greeter actually works (I29), disconnecting an RDP client from a Remote-Login greeter
session can crash that greeter's gnome-shell — a **race, ~6/24 teardowns (~25%)**, in mutter's
remote-desktop/screencast teardown: segfault in `libmutter-18.so` (offset ~15c7b1, after
`meta_remote_desktop_session_request_transfer`) or GPF in `g_type_check_instance+0x11` (use-after-free);
a second signature is `gnome-shell … segfault … in libxkbcommon.so.0.13.1`. To the RDP client it surfaces
as `ERRINFO_LOGOFF_BY_USER` mid-handover and the greeter resets to an empty/list state. Confirmed on host
edt1: greeter dynamic uids (gdm-greeter, 605xx) leave 14–28 MB apport dumps in /var/crash on each crash;
eddie's console session never crashes — only RDP greeter teardowns. This is an **upstream GNOME 50 mutter
bug**, NOT caused by the grd handover patch (the patch is in grd's daemon, not mutter); the greeter fix
merely made the "connected greeter → disconnect" path reachable. Impact is limited because the crashing
session is a disposable greeter. Mitigations: minimize connect/disconnect churn; keep the edy-rdp-reaper
(I13) reaping idle greeters; file upstream with the /var/crash dumps. Root cause + the related "slow
reboot" (libvirt-guests 120 s + rootful container teardown) were independently RCA'd — see the session
memory `edt1-gui-crash-shutdown-rca`.

### I32 · Isolated teardown + reaper KILLED the seat0 desktop / physical greeter · Sev C · VERIFIED · FIXED (external cleanup)
The Isolated (headless) path repeatedly destabilized the REAL seat0 Ubuntu session (user report 2026-09-01;
diagnosed + fixed in an external Grok session — full RCA in ~/Documents/RDP-guacamole-desktop-stability-2026-09-01.md).
Two independent defects, both introduced by this project:
1. **`edy-rdp-headless-stop` ran `pkill -u <uid> -x gnome-shell`** — matches EVERY gnome-shell for the uid,
   including the seat0 `--mode=ubuntu` compositor → every Isolated teardown killed the physical desktop
   (journal: headless stop at 03:31:41 → "gnome-shell: Shutting down GNOME Shell" on seat0 → gsd-xsettings
   SIGSEGV loop). Worse, `edy-rdp-headless-start`'s `pgrep -x gnome-shell` treated the EXISTING seat0
   compositor as "already up" and HIJACKED it (Isolated and the local desktop share /run/user/<uid>:
   wayland-0 + session bus), so hijack + pkill-on-disconnect = dead physical desktop.
2. **The reaper terminated the PHYSICAL GDM greeter**: `reap_greeters()` reaped any `gdm-greeter*` logind
   session older than 60s — including the seat0/tty1 login screen (Class=greeter WITH a Seat) and the
   greeter uid's manager/manager-early session; stopping `user@<uid>.service` for it blanked the display.
**Fixes (in source AND installed, verified identical):** stop script kills only
`pkill -f '/usr/bin/gnome-shell --wayland --headless'`; start script REFUSES (exit 3) when the uid already
has a non-headless (seat) gnome-shell; reaper skips any session with a Seat and any session whose
Class != greeter (live-proven: terminated 0 with the physical greeter up). Operational state after cleanup:
user 3389 grd (live-share/extend) DISABLED and not listening → the console/virtual scenarios are OFF until
`systemctl --user enable --now gnome-remote-desktop.service` is run deliberately; Isolated REFUSES for a
user with a seat desktop. **Residual design gap:** a true Isolated desktop for a user who is ALSO logged in
locally needs its own XDG_RUNTIME_DIR/bus (separate compositor namespace) — not built; refusal is the
current safe behavior. LESSON: never signal by process NAME for a shared-uid resource; never reap logind
sessions without checking Seat + Class.

### I29 addendum 5 (2026-09-01) — patched daemon REVERTED to stock (user request)
The locally-built grd daemon (method-call handover patch + audit hardening, sha `5c08514e…`) was removed
and the STOCK package binary restored (sha `c117146f…`, dpkg-verified clean); the
`org.gnome.RemoteDesktop.handover.conf` drop-in was removed (bus policy reloaded) and the apt hold on
gnome-remote-desktop released. The `.orig-edt1` backup was deleted after verification — the patch remains
reproducible from `source/patches/grd-handover-method-call.patch` (README has the build/deploy recipe).
Consequence: 3390 Remote Login is back on stock handover code. Note: addendum 4 established that the
ORIGINAL "TakeClientReady never delivered" symptom was almost certainly caused by the old receive-deny
drop-in (now gone), so stock grd with NO drop-in may in fact hand over correctly — UNTESTED; verify with a
single careful native-client connect if the greeter is wanted (mind I31 disconnect-crash churn). The
rdplogin door credential + rotation timer remain in place and are harmless either way.

## Security gates hardening (2026-09-01, FreeRDP3-bridge architecture)

### I4 · Console admin gate was cosmetic → CLOSED (server-proven elevation)
The old console gate was a client-side `if (isAdmin)` (bypassable) plus a server check of mere
sudo-GROUP membership. Now the plugin registers into the relay's **SessionTokens** table (`register` op)
and proves *live* administrator mode SERVER-SIDE: the relay writes a one-time challenge to a **root-only
file** (`/run/edy-rdp/reg/<rand>`, 0600 owned by the relay uid); the plugin can read it ONLY over a
`cockpit.file(..., {superuser:"require"})` channel (which only an elevated Cockpit session can open) and
echoes it back (`elevate` op) to flip the token `admin=True`. The console connect requires a token whose
`admin` is proven; a sudo-group user presenting a NON-elevated token is **refused** (token presence
disables the sudo fallback). Fallback to sudo-group is kept ONLY for a tokenless native/legacy client.
Verified: eddie (in sudo) with a non-elevated token → "needs administrative access"; after elevation →
gate passes. Trace logs `session token OK admin=True|False` + `admin gate PASSED/REFUSE` (no token value).

### I2 (extended) · Desktop-session token is uid-bound → anti-hijack, and end-to-end correlation
Every connection may carry a strong random `sessiontoken=` marker (256-bit, `secrets.token_urlsafe`).
`SessionTokens.check` requires the presenting connection's SO_PEERCRED uid == the token's registering uid,
so a leaked/stolen token is useless to any other user (verified: cptest presenting eddie's token →
"invalid or expired session token"). The token is the end-to-end correlation id linking
browser→relay→bridge in the trace so a user's multiple connections are never confused. Tokens are
in-memory + TTL'd (never survive a relay restart).

### I1/I3 (extended) · guacd's loopback VNC leg now authenticated → CLOSED "-nopw" local peek
The FreeRDP3 bridge's x11vnc previously served the loopback VNC port with `-nopw`, so ANY local user could
attach to a live bridge and watch the session. Now the bridge mints a per-connection strong VNC password
(`x11vnc -passwdfile`, 0600, never argv), publishes it in the 0640 `.env`, and the relay injects it into
guacd's VNC `password` param (trace-redacted). Verified: correct password → renders; empty/wrong → 0
frames. Defense-in-depth atop the loopback-only bind.

## Remote-host RDP scenario (2026-09-02)

The "Remote host" scenario lets the browser RDP into another host — the one path where the
target is not loopback. It is designed fail-closed and adversarially reviewed:

### I33 · SSRF via browser-chosen target · Sev C · CLOSED (fail-closed allow-list)
The relay/bridge dials whatever host it is told, so an unconstrained remote scenario would
be a classic SSRF pivot (internal admin UIs, metadata endpoints, port scans) and would send
the user's RDP credential to an attacker-chosen host. **Mitigation (shipped):** remote is
gated by `EDY_RDP_REMOTE_ALLOW` (`/etc/default/edy-rdp`), an admin-configured allow-list of
IPv4/CIDR[:port]. Empty = deny-all (default; the unit ships an empty `Environment=` fallback
so an upgraded host without the line still fails closed). The check runs in `_grd_target`
**before** `DESKTOP_SLOTS.claim`/`bridge.start_bridge`, so a denied target never dials out
(unit-tested). Enforcement is on a validated **IPv4 literal** — hostnames are rejected, so a
name cannot pass the CIDR check and re-resolve to an internal IP (no DNS rebinding).

### I34 · Bridge `.req` injection / credential handling · Sev H · CLOSED
`remotehost` is written into the 0600 bridge request file as a `KEY=VALUE` line, so a newline
could forge `PASSWORD`/`SECURITY` keys. **Mitigation:** `_parse_remote_target` rejects any
character outside `[0-9.:]` and anything that is not a strict `IPv4:port`, and the marker is
carried through Guacamole `enc()` (length-prefixed) — never string-concatenated. Remote uses
**client-supplied credentials only** (`relay_cred=None`); no relay-managed/headless credential
is ever handed to a foreign host. Markers (`remotehost=`/`rdpcred=`) are stripped server-side
before the connect reaches guacd, and the password is trace-redacted, same as the gate key.

### I35 · MITM / weak security of the remote session · Sev M · MITIGATED
Two protections. **(a) Security negotiation:** the local grd uses an explicit protocol
(`nla`/`rdstls`); a remote host **negotiates with plain RDP-standard security disabled**
(`/sec:rdp:off`), so the client offers only NLA+TLS — Windows selects NLA, other servers
(e.g. xrdp) select TLS, and the credential is never sent under weak RDP encryption. **(b)
Certificate trust:** the remote leg uses **`/cert:tofu`** with a persistent per-boot store
(`/run/edy-rdp/freerdp`): the first connect pins the cert and a later changed cert (MITM) is
refused. First-use trust is the TOFU tradeoff — for higher assurance, pin a CA / known cert.
Only reachable for allow-listed hosts. (Verified end-to-end: a container relay RDP'd into an
xrdp host over the negotiated TLS path and rendered an interactive desktop.)

### Residual notes
- `EDY_RDP_REMOTE_ALLOW=any` (esp. `any:*`) restores broad reach by operator choice — document
  it as an explicit decision, prefer specific CIDRs.
- Remote sessions are **not** reconnectable (not in `RECONNECTABLE_SCENARIOS`); a disconnected
  remote row is reaped normally rather than resurrected against a possibly-changed target.
- IPv4 only in this version (the `:` port separator makes IPv6 parsing ambiguous); IPv6 targets
  are rejected.

### I36 · Newline injection in a client RDP credential forged bridge `.req` keys · Sev H · CLOSED
Found by the adversarial security review of the remote scenario. The client-supplied RDP
username/password (the `rdpcred=` marker) were written **verbatim** into the newline-delimited
bridge `.req` file. Because Guacamole element values are length-prefixed (a newline is a legal
value byte a hand-built client can send), a password like `p\nHOST=8.8.8.8\nPORT=22` forged a
second `HOST=`/`PORT=` line that the launcher's last-value-wins parse used — coercing the bridge
into dialing an arbitrary host (SSRF). Critically this affected the **loopback-only
virtual/console** paths too (they also take a client credential, with no allow-list), so it was
a pre-existing hole the remote work surfaced, not remote-specific. **Fix (three layers):** the
relay rejects `\n`/`\r`/`\x00` in the client username/password right after the `\x1f` split
(covers all scenarios); `bridge.start_bridge` re-rejects control chars in every `.req` field
(defense-in-depth, also covers the relay-managed path); and the launcher refuses a `.req` with
more than its 6 expected lines and takes the **first** value of each key. Regression-tested
(`CredentialInjection`, `BridgeInjectionDefense`) and re-verified: the exact exploit is refused
with no bridge dialed, while clean credentials still connect.

### I37 · No per-uid cap on concurrent bridges → display-slot exhaustion · Sev L · CLOSED
Each bridge consumes one of ~100 Xvfb/VNC display slots; an authenticated user could open many
connections and exhaust the pool. **Fix:** a per-uid concurrent-bridge cap (`MAX_BRIDGES_PER_UID`,
default 6) checked before `bridge.start_bridge` and released on teardown (`BridgeCap` test).

### I38 · Console/virtual mirror fails on a LOCKED screen with an opaque error · Sev L · MITIGATED
grd 50.2 refuses to create a screencast session of a locked desktop (`Session creation
inhibited`); it accepts the TCP connection then drops it, so xfreerdp3 reports only a
`Broken pipe` / `ERRCONNECT_CONNECT_TRANSPORT_FAILED` transport error — which the relay used
to surface verbatim (very confusing). **Mitigation:** on a bridge failure for a local-seat
scenario (console/virtual), the relay checks `loginctl` for an active graphical seat session
with `LockedHint=yes` and, if found, returns "the physical screen is locked — unlock it …"
instead of the raw error. The check FAILS OPEN (never blocks a connection; only relabels a
failure). Fix the underlying condition by unlocking the session (`loginctl unlock-session`)
or disabling auto-lock. BY-DESIGN in grd — the mirror cannot display a locked screen.
