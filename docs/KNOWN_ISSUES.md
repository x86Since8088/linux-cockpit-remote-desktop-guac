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
`/run/edy-rdp/control.sock` (0660 group cockpit-guac-rdp, `edy-rdp-control.socket`):
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
The relay runs as `edy-relay` but the state dir `/run/edy-rdp` was created `0750 root:cockpit-guac-rdp`
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
  `/run/edy-rdp/state` (`0750 edy-relay:cockpit-guac-rdp`, via tmpfiles) so `edy-relay` can write atomically;
  the socket dir stays `root:cockpit-guac-rdp` non-group-writable so a group member cannot unlink the sockets.
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
  `/run/edy-rdp/headless/<uid>.env` (root:cockpit-guac-rdp 0640).
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
gated by `EDY_RDP_REMOTE_ALLOW` (`[install path]/.env`, normally
`/opt/cockpit-guac-rdp/.env`; formerly `/etc/default/edy-rdp`), an admin-configured allow-list of
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

**RESOLUTION available (opt-in, 2026-09-09):** the third-party GNOME extension **"Allow Locked Remote
Desktop"** no-ops grd's teardown-on-lock, so the console/virtual mirror STAYS connected through a lock and
the lock screen can be unlocked remotely. Bundled at `extensions/allowlockedremotedesktop@kamens.us/`,
enabled with `extensions/enable-locked-remote-desktop.sh` or `deploy.sh --with-locked-remote-desktop`.
**Off by default** — it also lets a remote unlock open the physical console. Verified on Ubuntu 26.04 /
GNOME 50. Full writeup + the security tradeoff: [docs/LOCKED-REMOTE-DESKTOP.md](LOCKED-REMOTE-DESKTOP.md).

### I39 · Cannot type a password at the mirrored lock screen — grd tears the mirror down on lock · Sev M · BY-DESIGN (upstream)
Reported as "the mirrored GNOME lock screen shows my user + a password box but the typed password never
logs in." Investigation (live relay logs + upstream sources) shows the mirror mode **cannot present an
interactive lock screen at all**, so this is not a plugin bug and not fixable in the plugin. When the
seat0 session locks, gnome-shell enters `unlock-dialog` session mode (`allowScreencast=false`); `js/ui/
main.js _sessionUpdated()` then calls `MetaRemoteAccessController.inhibit_remote_access()`, whose
documented contract is to **terminate any active remote-access session and refuse new ones**. So grd
drops the console/virtual mirror the instant the seat locks, and refuses a fresh connect while locked —
surfacing as the `Broken pipe` / `ERRCONNECT_CONNECT_TRANSPORT_FAILED` that the relay relabels "the
physical screen is locked" (see I38). A viewer holding the last frame may briefly show a frozen pre-lock
image, which *reads* as "the lock screen is shown," but no input is delivered. Stock GNOME behavior
(gnome-shell MR !1210, unchanged 46→50); there is **no supported grd/mutter/gsettings knob** to allow
streaming+input at the shield. **Live evidence (2026-09-08):** conn#17 connected while locked → bridge
FAILED (broken pipe) → relay REFUSED "screen is locked"; the user then hit the panel Unlock button and
conn#18 reconnected to the now-unlocked desktop. Confirmed with the user: they see the "screen is locked"
failure, never a typable shield.

**Recovery paths that DO work:** (a) the panel **Unlock** button — the admin-gated `control.py` `unlock`
op → `edy-rdp-unlock@<uid>` → `loginctl unlock-session` of the caller's OWN locked seat. Verified secure:
the helper unlocks only a session that is owned by the caller's uid AND on a seat AND Active AND
LockedHint=yes AND graphical; a **different user cannot unlock the logged-on user's console** (the unit
is instanced on the caller's SO_PEERCRED uid, and a non-admin is refused before that). (b) Prevent
auto-lock on the shared seat (`org.gnome.desktop.screensaver lock-enabled=false`, `org.gnome.desktop.
session idle-delay=0`). (c) For a *fresh* session (not the physical seat), use greeter/Remote-Login
(native RDSTLS clients only on stock grd — see I29) or the Isolated / Wayland-VNC scenarios. The
third-party "Allow Locked Remote Desktop" extension no-ops `inhibit_remote_access` (streams the shield
and accepts a remote unlock). It is now **adopted as an OPT-IN, off by default** — bundled under
`extensions/` and verified on GNOME 50.1 (see I38's RESOLUTION note and
[docs/LOCKED-REMOTE-DESKTOP.md](LOCKED-REMOTE-DESKTOP.md)). The caveat stands — it also unlocks the
physical console — which is exactly why it is never enabled by default.

### I39a · Bridge keyboard mode — scancode kept; `/kbd:unicode:on` was tried and REVERTED · resolved
The bridge launches xfreerdp3 in its **default SCANCODE mode** (no `/kbd:` option). A build in this cycle
set **`/kbd:unicode:on`** on the theory that sending literal codepoints would carry password characters
more faithfully through the browser-keysym → x11vnc XTEST → Xvfb → xfreerdp3 path. A controlled test on
an Ubuntu 26.04 / GNOME 50 VM (memory `allow-locked-remote-desktop-vm`) **disproved that**: with unicode
mode xfreerdp3 logged `int_MultiByteToWideChar: insufficient buffer supplied, got 1, required 2` for the
injected keys and the **wrong password landed** — the field filled with the right *number* of dots, but
authentication was rejected. Plain scancode transmitted the exact password and unlocked. **Resolution:
reverted to scancode** in `bridge/edy-rdp-bridge-start.sh` (and on the live
`/usr/libexec/edy-rdp/edy-rdp-bridge-start`). Lesson: for this X11-injection topology scancode is the
faithful path — unicode input is meant for a client reading a real keyboard, not synthetic XTEST events.
NOTE the original "typed password does nothing" report was **not** this: it was the *physical* seat's own
gnome-shell unlock dialog (a local issue, not the browser path — see the memory), and the browser-path
keyboard was already working.

### I40 · Door-credential NLA hangs ~2 min when the AD DC is down (FreeRDP3 Kerberos-first) · Sev M · FIXED (krb preflight)
FreeRDP3 attempts **Kerberos before NTLM**. The local-seat scenarios authenticate to grd with a LOCAL grd
"door"/"gate" credential (`rdplogin` on 3390, `rdplocal`/gate key on 3389) whose principal is **not in the
AD KDB**, so Kerberos can only ever fail for them — but when a domain controller is *unreachable*
(e.g. the samba-AD-lab DCs are down after a reboot), xfreerdp3 **hangs ~2 minutes** on the dead KDC before
NLA fails and it would fall back to NTLM. Observed live: `client authentication failure` logged ~2¼ min
after connect; the greeter never reached its handover (looked like the I29 handover failure but was NLA).
The realm's KDCs (`dc1..dc5.ad.edt1.lab`) come from `/etc/krb5.conf.d/`; `172.15.4.10:88` was closed.
**Fix:** `bridge/edy-rdp-krb-preflight.sh` (wired into the bridge for loopback targets) reads the realm +
its KDC list and probes **every KDC's port 88 in parallel with a 500 ms timeout**, then writes a
per-request `KRB5_CONFIG` listing only the KDCs that answered (`dns_lookup_kdc=false`) — or, if none answer,
one with **no KDC** so Kerberos fails instantly and NLA uses NTLM. Total added latency ~0.5–0.7 s. Every
probe result + the decision are logged to `<key>.krblog`. Scoped to loopback so a remote host's own realm
is untouched. This unblocked the greeter (I29) on a host whose AD DCs were down.

## Installer, .env, venv and audio bind (2026-09-27)

Found by a verified audit of edt1 on 2026-09-27 (fixed in 1.4.0.20260927 unless marked OPEN).

### I41 · install.sh aborted SILENTLY after check 3b — no install, deploy or --verify completed since 1.3.0 · Sev C · FIXED
Every `./install.sh`, every `deploy.sh` (which runs the installed `install.sh`) and every `--verify`
since 1.3.0 stopped after `ok 3b.` with exit 1 and **no message at all**. **Root cause:** pre-flight
check 5 rendered each unit and collected leftover placeholders with
`leftover="$(grep -v ... <<<"$out" | grep -o '@[A-Z_]\+@' | sort -u | tr '\n' ' ')"` under
`set -Eeuo pipefail`. A unit that renders CLEAN — the success case — is `grep -o`'s no-match case, so
the pipeline returned 1, the assignment failed, and `set -e` ended the script without a word (`die`
never ran; nothing was there to print). Proven twice: an isolated repro of that one line (rc=1, no
output; `|| true` → rc=0), and the deployed 1.3.0 payload's own `--verify` on edt1 (rc=1, last line
`ok 3b.`). Checks 3 and 3b already carried `|| true`; check 5 did not. With that line fixed the SAME
tree died a **second** time: `do_install` (and `do_verify`) scanned the rendered unit for `@[A-Z_]\+@`
without skipping comment lines, and `edy-rdp-guacd.service.in` carries `@DEFAULT_MONITOR@` inside a
`#` comment about pulse — `FATAL unrendered placeholder in edy-rdp-guacd.service`. (1.3.0's
CHANGELOG claims the comment-skip; it landed in `run_tests.sh` and check 5 only.) **Consequence on
edt1:** the Sep-18 deploy copied `payload-1.3.0`, swapped the `payload` alias, ran `install.sh` —
which died silently — and never linked anything: `/usr/libexec/edy-rdp/*` still resolved into
`payload-1.1.2` while `install.conf` said otherwise (see I43). The job wrapper masked deploy.sh's
non-zero exit, so nobody saw it. **Fix:** ONE helper, `leftover_placeholders()` (directive lines
only — a `@WORD@` in a `#` comment is documentation — and `|| true` on the pipeline, which is
load-bearing and commented as such), used by check 5, unit and sysfile placement in `do_install`,
and `do_verify`. Check 5 also understands the new `ExecStart=/usr/bin/env ${EDY_RDP_PYTHON} <path>`
shape and the `+` prefix, both guarded the same way. `deploy.sh` now ends with an unmistakable
`DEPLOY OK <version>` or `DEPLOY FAILED (<step>)` (EXIT trap), so a wrapper cannot hide it again.
**Regression test:** `tests/installer_tests.sh` → `installer_staged_install_completes` runs
`DESTDIR=<tmp> ./install.sh --with-units` from a temp copy of the tree and requires exit 0, `ok 5.`
through `ok 9.`, every PAGE/LIBEXEC/LIBS link, every rendered unit with no directive-line placeholder,
then `installer_staged_verify_passes` requires `--verify` to end `verify: PASS`. `run_tests.sh`'s
existing gate now demands `ok   9.` in the `--verify` output and names this issue when it is absent.

### I42 · Desktop audio dead after boot: one-shot pulse socket bind at guacd start · Sev M · FIXED (design) · live verification pending
Since the Sep-22 boot of edt1 the Sound toggle produced nothing: `podman logs edy-rdp-guacd` said
`PulseAudio connection failed` and `/run/edy-rdp-pulse.sock` on the host was a **0-byte regular
file**, not a mountpoint — even though the seat socket `/run/user/1000/pulse/native` existed before
guacd started. **Why:** `edy-rdp-guacd.service` did
`ExecStartPre=-/bin/sh -c '... mount --bind <seat socket> /run/edy-rdp-pulse.sock'` once, at service
start. The `-` prefix swallowed the mount error, nothing ever retried, the uid was effectively fixed at
1000, and because the container is rootful `--network host` with `-v /run/edy-rdp-pulse.sock:/run/pulse.sock`
(default **rprivate** propagation) a bind done later on the host could never reach the running
container anyway — only a guacd restart after login "fixed" it, until the next boot. **Fix (D3
design, 1.4.0):** bind a DIRECTORY, not a file. `pulse/edy-rdp-pulse-bind.sh` (installed
`edy-rdp-pulse-bind`, the guacd unit's `ExecStartPre` WITHOUT `-`) makes `/run/edy-rdp-pulse` a
self-bind with `mount --make-rshared`, and — when the seat socket exists — bind-mounts that socket FILE
onto `/run/edy-rdp-pulse/native` (touching the target first; idempotent by inode; a previous login's
stale bind is released). The container mounts `-v /run/edy-rdp-pulse:/run/pulse:ro,rslave` and speaks
to `PULSE_SERVER=unix:/run/pulse/native`. A per-seat path unit, `edy-rdp-pulse-seat@<uid>.path`
(`PathChanged=/run/user/%i/pulse` → `edy-rdp-pulse-rebind@%i.service` →
`edy-rdp-pulse-bind --seat-uid %i`), fires at every login; `deploy.sh --with-units` enables the
instance named by the new `.env` key `EDY_RDP_PULSE_SEAT_UID` (`EDY_RDP_PULSE_SEAT_SOCKET` still
overrides the path) and then starts `edy-rdp-pulse-rebind@<uid>.service` once, for a seat logged in
at deploy time. Because the source directory is a SHARED mount, a bind made into it later
propagates into the RUNNING container: audio for the next session, no restart. Outcomes are one
journal line each (`bound`, `seat socket absent - no audio until a seat login`, a refusal, or the
real mount error); an absent socket exits 0, a refusal or a genuine mount failure now STOPS the unit
(R4: if that proves too strict live, the operator can put the `-` back — but then read the log).
`install.sh --verify` checks that `/run/edy-rdp-pulse` is shared and that `native` is a mountpoint
whenever the seat socket exists. The old `/run/edy-rdp-pulse.sock` file is left alone (tmpfs; gone
at reboot). **Two review findings folded into the design before it shipped:** (1) the first draft
used `PathExists=/run/user/%i/pulse/native`, which systemd re-evaluates the instant the oneshot
exits — while the socket exists that is true again, five starts in ~100 ms hit `StartLimitBurst`
and the **path unit itself fails** (proven on edt1's systemd 259 with `systemd-run
--path-property=PathExists=<existing file> /bin/true`); enabling it while the seat was logged in
would have killed the watch within a second and left the unit looking enabled — hence
`PathChanged=` on the directory (fires once per inotify event, never for a state; it does not fire
for a socket that already exists, which is what the explicit `systemctl start` after enabling and
guacd's `ExecStartPre` cover). (2) The script runs as root on paths the seat user owns and `-S`,
`stat -L` and `mount --bind` all follow symlinks, so a seat user (or, through a read-write
`rshared` mount, a compromised guacd planting a symlink named `native`) could have had root bind
any host socket into the container or create a file at an arbitrary host path. Now the source is
vetted with `lstat` (no symlink on `/run/user/<uid>`, `/run/user/<uid>/pulse` or the socket; a
socket owned by the seat uid, override included), the target must be absent, a mountpoint or the
empty root-owned file the script made, the mount is re-read and undone if it is not the vetted
socket, and the container gets the directory `ro,rslave` (host → container only; no write access —
`connect()` on a unix socket needs none). `--check` applies the same vetting without root and
`tests/installer_tests.sh` proves each refusal. **Upgrading:** a 1.3.x `.env` with
`PULSE_SERVER=unix:/run/pulse.sock` is refused by validation as stale — change it to
`unix:/run/pulse/native` ([AUDIO.md](AUDIO.md)) BEFORE deploying: `deploy.sh`'s pre-flight validates
the live `.env`'s present keys and stops with `DEPLOY FAILED (pre-flight)` while the host is
untouched, instead of after the alias swap (I43). **Live verification is pending** — the propagation
claim is a design argument until the operator re-tests on edt1: log in → `mountpoint
/run/edy-rdp-pulse/native` → `podman exec edy-rdp-guacd ls -l /run/pulse/native` shows the socket →
the Sound toggle streams, all without `systemctl restart edy-rdp-guacd.service`.

### I43 · edt1 half-deployed: payload alias 1.3.0, libexec links 1.1.2, hand-copied files under /usr/share/cockpit/guac-rdp · Sev H · OPEN (reclaim procedure)
**State found 2026-09-27:** `/opt/cockpit-guac-rdp/payload` → `payload-1.3.0`, but every
`/usr/libexec/edy-rdp/*` link still resolves into `payload-1.1.2` (the Sep-18 deploy died in
`install.sh` before linking — I41). Under `/usr/share/cockpit/guac-rdp/` the page is a REGULAR
`index.html` plus ~45 `*.bak` files, all hand-copied during the repairs that followed the silent
failures. That directory is therefore not `owned_by_us` (the installer's test that every entry is a
link it would have made), so `install.sh` **correctly refuses** to take it over rather than delete
somebody's files — and `--verify` used to misreport the regular `index.html` as "resolves into a
checkout" (fixed: it now says `NOT a symlink (hand-copied?)`). Nothing here is deleted by any script:
the removal primitives never `rm -r` under `/usr/share/cockpit`, `/usr/libexec` or `/etc`, by contract.
**Reclaim procedure (operator, via the root job runner):** (1) **quarantine, never delete** —
`mv /usr/share/cockpit/guac-rdp /var/backups/guac-rdp.quarantine-$(date +%F)` (one `mv` of the whole
directory; no `rm -r`); (2) fix the one stale value edt1's live `.env` carries —
`PULSE_SERVER=unix:/run/pulse.sock` → `unix:/run/pulse/native` in `/opt/cockpit-guac-rdp/.env` — because
`deploy.sh`'s pre-flight now validates the present keys of the live `.env` and refuses with
`DEPLOY FAILED (pre-flight)` BEFORE copying or swapping anything (the alternative was dying from the
installed `install.sh` after the alias swap: this very state, again); then, from a checkout on the fixed
version, `sudo ./deploy.sh --with-units` (copies `payload-1.4.0.20260927`, swaps the alias,
places/reconciles `.env`, links everything, enables the units including `edy-rdp-pulse-seat@1000.path`
and runs the rebind once); (3) `sudo ./deploy.sh --verify` must end
`DEPLOY VERIFY OK` — and `install.sh --verify` inside it must show every libexec link resolving into
the new payload and `index.html` as a symlink; (4) hard-reload Cockpit, confirm the page serves, then
delete the quarantine directory by hand. Leftover `payload-1.1.2`/`payload-1.3.0` are pruned by
deploy's keeper policy. Until this runs, edt1 serves a mixture of versions.

### I44 · Stale ~/.config/pipewire/pipewire-pulse.conf.d/20-edy-tcp.conf: anonymous loopback TCP listener on 4713 · Sev L · OPEN (remove)
The 1.2.x audio attempt made pipewire-pulse listen on TCP (`module-native-protocol-tcp` on
`127.0.0.1:4713`) via a per-user drop-in `~/.config/pipewire/pipewire-pulse.conf.d/20-edy-tcp.conf`
in the seat user's home. The socket bind design (I42, [AUDIO.md](AUDIO.md)) superseded it and nothing
reads the TCP port, but the drop-in was never removed: it exposes the seat user's audio server —
record from any source monitor, play into any sink — to **every local uid** on loopback, with no
authentication, for no benefit. Not something a system-scope installer should edit in a user's
`$HOME`, so it stays a manual step: as the seat user, delete the file and
`systemctl --user restart pipewire-pulse`; confirm with `ss -tln | grep 4713` (nothing) and
`pactl info` still working over the unix socket. Recorded here so the next audio audit does not
rediscover it.

### I45 · Typing "<" sent ">" to the guest (Xvfb ISO-compat keycode collides with a held Shift) · Sev M · FIXED (1.4.2.20260928)
Reproduced live against a throwaway Xvfb with `x11vnc -debug_keyboard`: the bridge runs
`x11vnc -nomodtweak` (see I39a), so x11vnc never adds or removes an X11 modifier itself — it resolves a
keysym to an Xvfb keycode the way Xlib's `XKeysymToKeycode` does (lowest shift-level column, tie-broken
by lowest keycode) and presses that keycode as-is, trusting whatever modifier is already down. The Xvfb
"us" keymap defines an ISO-only compat key (keycode 94, no physical existence on a real US keyboard) as
`[less, greater, bar, brokenbar]`; `less`'s lowest-column location is that key's UNSHIFTED level. A US
client always holds real Shift to type "<", and Shift + that same keycode's level 1 is "greater" — so
"<" silently arrives at the guest as ">". (`greater` and `bar` were already resolving to their correct,
unambiguous keycode by the same Xlib rule — only `less`, `parenleft` and `parenright` are genuinely
mis-resolved keysyms.)

**A first fix attempt (Shift-only, five hardcoded keys) was caught before merge by an independent
adversarial review agent, plus a live re-check that exposed a follow-on bug in its own bookkeeping —
recorded here because the reasoning generalizes and the mistake is worth not repeating:**
- The existing parenleft/parenright fix, and the first pass at this one, assumed Shift is always held
  when the browser reports these keysyms — true on a US keyboard, not in general. French AZERTY types
  "(" UNSHIFTED; German types "|" via AltGr, not Shift; and — the finding that actually broke the first
  attempt — **French AZERTY holds Shift for every digit, and German holds Shift for "."**. A fix that
  only ever ADDS Shift never handles a client that holds Shift for a key the Xvfb keymap needs
  UNSHIFTED — the exact same bug, mirrored, and it hits far more characters than the five originally
  suspected.
- The first attempt's per-keysym "did I add a synthetic Shift" flag was also unsound against a REAL
  Shift press/release overlapping a managed key's hold: press "<" with no real Shift held (synthetic
  Shift added) → user starts holding real Shift for an upcoming ">" → release "<" → the flag says
  "release the Shift I added", killing the user's now-genuine Shift press.

**Fix (`guac-rdp.js`, `KEYCODE_FIX` + `SHIFT_LEVEL` + `sendGuestKeyEvent`), computed once from a live
Xvfb "us" keymap dump, not guessed:**
- `KEYCODE_FIX` — `parenleft`/`parenright`/`less` are genuinely ambiguous keysyms (Xlib's rule picks a
  keycode xfreerdp3 can't scancode, or one colliding with a held Shift) and get substituted to their one
  other, unambiguous, always-scancode-able location: digit 9/0, comma. A substitution always relies on
  the substitute's *shifted* level by construction (Shift+9 is parenleft, not 9's own unshifted
  meaning) — `needsShift` for a substituted key is hardcoded `true`, never looked up from the
  substitute's own table entry (that was the bug caught in code review of the second draft, before any
  of this reached a test run).
- `SHIFT_LEVEL` — every digit and ASCII punctuation keysym (not letters: unshifted-lower/shifted-upper
  is universal across every layout, so they need no correction) gets its Shift state forced to match
  what the Xvfb "us" keymap needs for THAT keysym, regardless of what modifier the client's layout used
  to produce it — added when missing, or **suppressed** when the client's real Shift doesn't belong
  there. Only digits/punctuation are managed; Tab/arrows/F-keys/letters/modifiers all pass through
  untouched, so Ctrl+Shift/Alt+Shift combos — the reason `-nomodtweak` was chosen over x11vnc's own
  `-modtweak` in the first place (I39a) — are unaffected.
- The add/remove is undone on keyup checked against the **current** real Shift state, not the state
  recorded at keydown, so an overlapping real Shift press/release is never fought. State is reset in
  `teardown()` so a mid-press disconnect can't leak into the next session on the same page.

**Verification:** live end-to-end against a real throwaway Xvfb + `x11vnc -nomodtweak -debug_keyboard`
for both directions — Shift added for a no-Shift client input (parenleft/parenright/less/greater/bar),
and Shift suppressed-then-restored for a Shift-holding client input landing on an unshifted target
(digit "1"): confirmed the actual `XTestFakeKeyEvent` ordering at the X11 level (Shift released before
the digit keycode is pressed, restored after), not just the JS call sequence.
**Tests:** `tests/js/keyboard_remap.test.js` (new) loads the actual shipped block (via the
`TESTHOOK:KEYREMAP` sentinels) into a sandbox and covers both Shift directions, the overlapping-real-
Shift desync scenario, key-repeat, mid-press client loss and its `teardown()` reset, and the
pre-existing Meta/Mac-Option remaps; wired into `run_tests.sh`.

### I46 · Numpad decimal key (`KP_Decimal`) resolves to a Brazilian/JIS numpad-comma keycode, not the real numpad `.` · Sev L · OPEN (deferred)
Found while sweeping the Xvfb "us" keymap for every ambiguous keysym during I45. `KP_Decimal` is bound
to BOTH `<KPDL>` (keycode 91, the real numpad `.`/Del key, at shift-level column 1) and `<I129>`
(keycode 129, alias `<KPPT>`, evdev `KEY_KPCOMMA` — a real Brazilian/JIS numpad-comma key — at column
0 AND column 1). Xlib's `XKeysymToKeycode` rule (lowest column, tie-broken by lowest keycode) resolves
`KP_Decimal` to keycode 129, not 91. Unlike I45, this is **not a Shift problem** — numpad keys level-
select on NumLock (a separate XKB modifier axis this file already syncs elsewhere, see the
NumLock/CapsLock/ScrollLock mirroring near `remoteLocks`), so the I45 fix's machinery doesn't apply
here, and fixing it needs its own investigation into how NumLock state interacts with x11vnc's keycode
choice for this specific ambiguity. **Deferred rather than rushed into the I45 fix** — recorded here so
it isn't lost. Reproduce with `x11vnc -debug_keyboard`: send keysym `0xFFAE` (`KP_Decimal`) and confirm
which keycode gets XTestFakeKeyEvent'd.

### I47 · A pop-out could only ever show the one scenario it opened with, with no way to recover · Sev M · FIXED (1.5.0.20260929)
(Also folds in two related UX asks delivered in the same pass: the same "Session…" modal now declutters
the main Connect panel's bar too, and its tabs reflect in the URL.)
Reported: after a reboot with nobody logged into the physical seat, Pop-out (hardcoded to the `console`
mirror, which needs an active per-user desktop session on :3389) can't connect until someone signs in via
the GDM greeter through the main tab — expected, since nothing is listening on the per-user :3389 grd
service before a login. Once logged in, Pop-out connects fine. But if the connection carrying that
greeter sign-in is later disconnected from the main tab, the Pop-out's console mirror drops too, and
Pop-out had no way to reconnect or switch scenario short of closing the window (it auto-connects exactly
once, to whatever `enterSeatMode()`/`enterMonitorMode()` hardcoded, and exposed only a small fixed subset
of controls — a monitor picker and Sound).

The exact reason the console mirror drops when the greeter connection disconnects was not nailed down
live in this pass — worth confirming against this project's own documented grd/lock-screen interaction:
a disconnected RDSTLS/greeter-handover connection plausibly locks the physical seat, and a locked seat is
already known here to make grd kill any active screencast (I39a: "the active grd screencast" is
terminated and new ones refused while locked). But the practical gap is the same regardless of the exact
mechanism: **a pop-out is a genuinely separate page load** (`window.open` to the same URL with a
different hash — not a shared JS context with the opener), so it was never actually tied to the opener
tab in the code, only by having no UI to exploit that independence.

**Fix (`guac-rdp.js`, `buildSessionCard()` + `addSessionButton()`):** both pop-out types (`#seat` /
`#monitor`) AND the main Connect panel (`enterConnectMode()`) now get a "Session…" button opening a modal
— a native `<dialog>`, since this project has no modal component of its own and `<dialog>`/`showModal()`
is the universal one (free backdrop dimming, Escape-to-close, focus handling) — with the full connect
controls: Session target (+ host/port for Remote/VNC), Sign-in + credentials, Resolution, Scale,
Clipboard, Sound, and Connect/Disconnect — by reparenting the EXISTING elements (same ids, same event
listeners; nothing duplicated or rewired). A pop-out can now try `console`, fail pre-login, switch to
`greeter` to reach the GDM screen, and switch back to `console` after login — entirely on its own, no
opener tab required. (First shipped as a dropdown anchored to the button; changed to a modal per a
follow-up request — a `<dialog>` is simpler than the hand-rolled backdrop-div + outside-click-listener
the dropdown needed, and was caught losing a `bar.appendChild(b)` during that rewrite by the same jsdom
smoke test before it ever reached a browser.) The main Connect panel's tabs also now reflect in the URL
as `tab=<name>` (same `replaceState` pattern as `URL_CONTROLS`), restored on load.

**Live user testing then caught a real gap in the tab/URL sync that jsdom alone could not:** the URL
appeared to update by every internal check, but the browser's VISIBLE address bar stayed on
`tab=connect` regardless of which tab was clicked. Root cause: `history.replaceState()` changes this
document's own `location.hash` but does NOT fire a `hashchange` event — only a real hash-navigation
does. Decompiling the installed `/usr/share/cockpit/base1/cockpit.js` confirmed Cockpit's shell-sync
(mirroring the embedded page's location into the actual browser address bar, over the iframe<->parent
`cockpit1` transport) runs entirely off a `window.addEventListener("hashchange", ...)` listener — with
no event, the shell never learns anything changed. New shared `writeHash()` keeps `replaceState` (still
no history-spam per click) and additionally dispatches a `hashchange` event by hand; both `selectTab()`
and the pre-existing `saveControls()` (Session/Resolution/Scale/Clipboard/Sound persistence) now go
through it — `saveControls()` had the exact same silent gap since before this release, just never
reported, since apparently nobody had watched the actual address bar while changing those controls.

Verified via a DOM-level smoke test (jsdom, ad hoc, not part of the repo's Playwright suite; jsdom has no
`HTMLDialogElement.showModal`/`close` at all, stubbed to toggle the `open` attribute) that the dialog is
built correctly, opens/closes via the button/close-button/backdrop-click idiom, the pre-existing
`refreshUi()` show/hide logic still works on the reparented fields, and the tab/URL sync round-trips AND
fires `hashchange` (simulating the listener Cockpit's shell registers) — for all three modes; not
live-tested against a real Cockpit/relay session in this pass.

### I48 · Console (mirror) connect with nobody signed in on the seat dead-ended instead of offering the greeter · Sev M · FIXED (1.6.0.20260929)
Reported as the first hop of the I47 scenario: on a freshly booted host with no local login, connecting
to the Console mirror (from the main panel, the Pop-out's auto-connect, or the pop-out's monitor-picker
reconnect) failed opaquely — a bridge transport error, or nothing listening on the per-user :3389 grd at
all. That is inherent: `mirror-primary` streams the seat's per-user desktop, and pre-login there is no
desktop; the GDM greeter (a session of its own) is the only thing that can render before someone signs
in. 1.5.0 made recovery *possible* by hand (open Session…, pick Login screen, sign in, switch back) but
the user still had to diagnose the dead end themselves first.

This is a **different case from the locked seat** (I38/I39, `LOCKED_SEAT_RE`): there a session exists
and is worth resuming, which is exactly why that path deliberately does NOT auto-redirect to the greeter
(a greeter login starts a NEW session and cannot attach to the locked one — it resets the login rather
than resuming it). With zero local logins there is no session to preserve, so switching loses nothing.
That handling is untouched.

**Fix (`guac-rdp.js`, `resolveConsoleFallback()` + `showToast()`; `#toast` in `guac-rdp.css`):**
`connect()` now resolves the effective scenario BEFORE dialling out. For `console` only, it asks the
relay's existing read-only `deskui-status` control op (the same one the Desktop UI tab renders; any
authenticated caller, not admin-gated) for `active_graphical_sessions` — computed server-side as
"active, graphical, seated, non-greeter sessions right now", so `0` means nobody is locally logged in.
On an explicit `0` it flips the Session selector to `greeter`, runs `refreshUi()` so the dropdown and
hint reflect it, shows a transient toast ("No one is signed in on the physical console — opening the
sign-in screen instead.") and connects to the greeter — a seamless fail-over, not a message-and-stop.
Anything else (a count > 0, a control error, a channel that will not open, a missing field, or no answer
within 4s) proceeds with `console` exactly as before: the probe **fails open**, like the relay's own
`physical_session_locked()`, and can never block a normal console connect. Scoped strictly to `console`
(`virtual` etc. never probe); every caller funnels through `connect()` so all three entry points get it
without special-casing; no re-entry (the resolved key goes to the split-out `connectAs()`, which never
calls `connect()`). No relay code changed. The toast is the project's first transient notification
(there was only the persistent `#status` line): one lazily created `#toast` div, `role="status"`/
`aria-live="polite"`, `pointer-events:none`, bottom-centre, same `--panel`/`--ink`/`--line` surface as
the Session… card, fade in/out, self-dismissed after 5s. Known and accepted: like `#status` it sits
outside the Session… `<dialog>`, so while that modal is open (browser top layer) it renders dimmed
behind the `::backdrop` — consistent with `#status` today, not worth a second modal.

Verified via a DOM-level smoke test (jsdom, ad hoc, scratch project, not a repo dependency — same
approach as I47) driving the real `index.html` + `guac-rdp.js` through `connect()` with `cockpit` and
`Guacamole` stubbed, asserting on the `scenario=` marker in the wire-level `connect` instruction: 0
sessions → `greeter` + toast; 1 session → `console`, no toast; control reject / synchronous throw /
no answer (timeout) → `console`; `virtual`/`greeter` never probe; the `#seat` pop-out auto-connect
takes the same path; toast auto-hides and a second toast resets its clock. Not live-tested against a
real Cockpit/relay session in this pass — confirm on edt1 against a freshly booted seat.

**Follow-up (1.6.1.20260929), found by a multi-agent adversarial review before this ever reached
edt1:** the "known and accepted, dimmed behind the `::backdrop`" call above understated the actual
problem. A native `<dialog>` opened with `showModal()` makes everything OUTSIDE it *inert* per the
HTML spec — removed from the accessibility tree, not merely dimmed — and since Connect lives inside
the Session… card, the ordinary path (open Session…, pick Console, click Connect) left the toast
silently unannounced to assistive tech for the exact message this feature exists to convey.
Two further, independent bugs in the same function: the 5s auto-hide only removed the `.show` CSS
class, so `opacity:0` alone left the stale text permanently discoverable in the accessibility tree
(only `display`/`visibility`/`hidden`/`aria-hidden` actually remove a node from it); and the very
first toast of a page load skipped its fade-in entirely, because the element's initial (hidden) style
was never committed to a frame before the `.show` class was applied in the same synchronous call, so
the browser collapsed both changes into one. Fixed: `showToast()` now reparents `#toast` into
whichever `<dialog>` is currently open (or back to `<body>` once none is — `position:fixed` keeps it
viewport-anchored regardless of DOM parent), so it renders above the `::backdrop` and stays reachable
by assistive tech instead of inert; toggles `aria-hidden` on hide/show so the node actually leaves and
rejoins the accessibility tree; and forces a style flush (`el.offsetWidth`) right after the element's
first creation so the very first toast fades in like every later one. All three were confirmed with a
concrete reproduction (one against a real headless Chromium accessibility-tree dump) before being
accepted as real, and eight other candidate findings from the same review — including a claimed
relay-side admin-gate gap on the `greeter` scenario — were independently checked and refuted; see the
review's own reasoning in the corresponding commit for why. Re-verified with an extended jsdom check:
reparents into an open dialog and back on close, `aria-hidden` clears on show and is set on hide, and
the forced-reflow line runs without throwing.

### I49 · New capability: self-update (check GitHub for a newer Release, one-click apply with automatic rollback) · Sev N/A · SHIPPED (1.7.0.20260929, backend half)

Not a bug fix — a new capability, recorded here in the same spirit as I47. A deployed host has no
git repository at all (`deploy.sh`'s own payload packaging excludes `.git/`), so "check for updates"
goes through the GitHub API (`GET .../repos/x86Since8088/linux-cockpit-remote-desktop-guac/releases/latest`)
and "apply" means fetching that tag's tarball (one top-level directory containing the full repo tree,
`deploy.sh` included) and re-running **that** `deploy.sh --install-to <root>` — no `--with-units` —
against the existing install root, reusing its payload-swap/`.env`-reconcile logic rather than
reimplementing it. Four new control-socket ops (`update-status`, `update-check`, `update-apply`,
`update-rollback`; see `docs/SELFUPDATE.md` for the full contract) are wired into
`relay/control.py`'s `handle_control()` through a new injected `selfupdate=` object
(`relay/selfupdate.py`'s `SelfUpdate`, mirroring `DesktopUI`'s shape), behind two NEW,
deliberately **parameterless** privileged units (`edy-rdp-selfupdate-apply.service`,
`edy-rdp-selfupdate-rollback.service` — no `%i`, no instance argument at all: one step past the
existing `%i`-templated deskui/unlock pattern, since it means zero caller-influenced data crosses the
`systemctl start` privilege boundary). The apply unit re-fetches and re-validates the "latest version"
question itself from a fresh GitHub call — it never trusts the unprivileged relay's cache, an argument,
or an environment variable — and on a failed post-restart health check (a `systemctl is-active` check
plus a real `{"op":"ping"}` round-trip on the control socket, retried for ~20s) it automatically swaps
back to the one non-current `payload-<version>` directory and restarts the relay again. Only
`edy-rdp-relay.service` is ever restarted by this path; `edy-rdp-guacd.service` is deliberately never
touched (a live RDP screencast is never dropped by an automated flow in this project — see any commit
history mentioning "restart guacd"), which also means a version bump needing a new `guacd` image is
out of scope for the automatic path (documented, not solved, in `docs/SELFUPDATE.md`).

**Trust model, stated plainly (not overstated):** this verifies TLS to `api.github.com` and
`codeload.github.com` and nothing more. There is **no code-signing or GPG verification** of the
fetched release tarball in this pass — a compromised repository owner account is a compromised fleet.
See `docs/SELFUPDATE.md`'s "Trust model" section for the full statement; a signature-verification pass
is a plausible future follow-up, deliberately not attempted here.

**This repository has no GitHub Releases or tags yet** as of this writing (`gh release list` and
`git tag --list` both empty, verified this session) — so `update-status` will correctly report
`update_available: false` / `latest_version: null` on every host until the maintainer cuts the first
tagged Release. That is the expected result of the check, not a bug in it.

**Verification (backend half):** `relay/test_selfupdate.py` (new) covers version parse/compare across
equal/older/newer/malformed input (malformed never reports an update available — fails closed), the
cache read/write round trip and its TTL staleness decision, the rollback-candidate selection logic
(none/exactly-one/ambiguous-refuse), and `relay/control.py`'s exit-code-to-response mapping for all
four ops including every refusal path (not admin, bad confirm, nothing to apply, rate-limited).
`run_tests.sh` green (`test_selfupdate` added to the existing unit-test line), plus the existing
install-completeness gate (`install.sh --verify`'s pre-flight), which now also asserts the two new
units render clean with no leftover placeholder and every `LIBEXECDIR` reference they carry resolves
to something the manifest actually installs. Not live-tested against a real tagged Release on edt1 in
this pass (none exists yet, per the note above) — the mechanics were exercised via mocked
`urllib`/`subprocess`/socket calls only, never a real network call, per this project's existing test
philosophy.

**Follow-up (same 1.7.0.20260929, frontend half): the "Update" tab.** A new tab (`guac-rdp.js`'s
`TAB_NAMES`/`selectTab()`, `index.html`'s `#panel-update`) reads and drives the four control ops
above: `update-status` on tab-open (plus once at page load, for the badge — no new polling timer in
the browser), `update-check`/`update-apply`/`update-rollback` on their own buttons. "Update now" is
admin-gated and stays disabled until `update_available` is true, then needs the operator to type this
host's name to confirm — built as a direct sibling of the Desktop UI tab's Stop/Disable confirmation
UX (same `-confirm-wrap` pattern, same "type the host name to confirm" copy). "Roll back" is
admin-gated with no typed confirmation, per the contract's own low-friction-recovery /
disruptive-needs-confirmation asymmetry. A wrinkle worth recording: `update-status`/`update-check`
never carry this host's name (unlike `deskui-status`) — only `update-apply`'s `need_confirm` refusal
does — so the tab borrows `deskui-status`'s `hostname` field (read-only, not admin-gated) as the
confirmation label rather than adding a new field to the wire contract; both controllers derive it
identically (`socket.gethostname()`, same relay process) and the relay re-checks its own value
regardless. An available update (and any recorded `last_apply` outcome) is ongoing host STATE, not a
one-off event, so it is surfaced two ways that both deliberately avoid `showToast()` (I48's
auto-dismissing transient notice): a small persistent badge dot on the tab itself
(`#update-badge`/`.badge-dot`), and `last_apply`'s outcome text (e.g. "...failed its health check and
was automatically rolled back to...") as its own non-auto-dismissing status line. Verified with a
scratch jsdom smoke test (same ad hoc, throwaway approach as this entry's own — loads the real
`index.html`/`guac-rdp.js` with `cockpit`'s channel/permission plumbing stubbed): version/release-link
rendering, the bootstrap "no releases published yet" wording shown verbatim (this repository's actual
current state), the badge tracking `update_available`, "Update now" refusing to fire until both
`update_available` and a matching typed hostname hold, "Roll back" firing with no `confirm` field, a
non-admin never seeing either button enable, and `last_apply` rendering/hiding correctly. `run_tests.sh`
re-run green (untouched Python/relay half included).

**Follow-up (1.7.1.20260929): five real defects found by adversarial review, before any of this ever
reached edt1 or was pushed.** A multi-agent review (four dimensions in parallel, each candidate
finding independently re-checked by a skeptic on a different model) confirmed 5 of 10 candidate
findings and refuted the other 5, including a "critical"-labelled claim that the pre-3.12 tar-extraction
fallback could be bypassed via a symlinked intermediate directory — real as a code-level flaw, but NOT
reachable via a genuine GitHub-generated tarball (a git tree cannot hold both a symlink entry and a file
entry nested under the same name), so hardened anyway as defence in depth rather than treated as the
claimed privilege escalation. The five confirmed and fixed: (1) **high** — apply and rollback had no
mutual exclusion at all and could race on the same `payload` symlink and relay restart if an admin
clicked "Roll back" while "Update now" still looked stuck; reproduced (two processes racing the real
swap lost the symlink update on ~half of 20,000 stress-test iterations); fixed with a non-blocking
`flock()` (`relay/selfupdate.exclusive_run()`) held for the entire privileged run, plus a new exit code
6 ("already in progress") and a per-process-unique temp symlink name as defence in depth. (2) **medium**
— the worst-case exit path could log a successful payload swap as having "also failed" whenever only
the post-rollback health check was the actual problem, and silently dropped the rollback's own restart
error; now reports which of three distinct failure modes actually happened. (3) **low** — rollback's
refusal message collapsed "no earlier version" and "more than one exists (ambiguous)" into identical,
sometimes-false text; now distinct and accurate. (4) **medium** — the "no releases published yet" state
(this repo's actual, expected, day-one state) rendered as a bold red error, indistinguishable from a
real GitHub outage, because both shared one untyped `check_error` field; fixed with a typed `no_releases`
boolean. (5) **low, but the fix it enabled was not** — `_safe_extract()`/`fetch_and_extract_release()`
had zero test coverage; writing it immediately surfaced a real, previously-unnoticed bug: on this
project's own Python (3.14), a path-traversal tarball raised a raw `tarfile.OutsideDestinationError`
that `_safe_extract()` did not catch, so it would have crashed the privileged script with an uncaught
traceback instead of the intended, accurate "nothing was touched" refusal — fixed by catching
`tarfile.TarError` and wrapping it as `SelfUpdateError`. `run_tests.sh` green throughout (82 tests now
in `relay/test_selfupdate.py` alone).

### I50 · New capability: shadow-group gate for mirroring a DIFFERENT signed-in user's console session · Sev N/A · SHIPPED (1.8.0.20260929)

Not a bug fix — a new capability, recorded here in the same spirit as I47/I49. The console
scenario's existing gate (I4, above) answers one question: is the caller a Cockpit
administrator? That is the right question for "may this person use the mirror at all," but
it is silent on a genuinely separate one — if a *different* user is currently signed in at
the physical seat, may this admin secretly watch **that specific person's** active desktop?
An organization can reasonably want every admin able to mirror an *empty* seat or *their
own* session, while restricting who may mirror a **co-worker's** live screen to a smaller,
deliberately-provisioned set — a privacy boundary the old gate had no way to express, since
it only ever asked "admin or not."

**Mechanics.** `Connection._peek_scenario_from_connect()` now runs a second, additive check
for `scenario == "console"`, immediately after the existing admin gate and using the exact
same `is_admin(uid, group)` primitive (I4) against a *different* configured group
(`EDY_RDP_SHADOW_GROUP`, default `rdp-shadow`) — reused as-is, not reimplemented, since
`is_admin()` was already a generic "is this uid a member of this named group" check despite
its name/docstring. A new `seated_uids()` (`relay/edy_rdp_relay.py`) answers "who, if
anyone, is physically at the seat right now" via `loginctl list-sessions` + `show-session
-p User` (the same uid space Cockpit sessions run under, since `self.uid` already comes
from SO_PEERCRED); a new pure `shadow_gate_required(seated, requester_uid)` decides the
gate applies iff a uid *other than the requester* is seated. Nobody seated, or the
requester seated alone, needs nothing beyond the existing admin gate — unchanged in every
respect, same wording, same code path. The gate is evaluated fresh on every console connect
attempt (never cached), since who is seated can change between connects.

**Fail-closed by design — the opposite of `physical_session_locked()`'s role.**
`seated_uids()` returns `None`, not an empty set, when it cannot determine who (if anyone)
is seated at all (`loginctl list-sessions` itself failed or errored); `shadow_gate_required()`
treats `None` as "cannot rule out someone else," so an admin with no shadow-group membership
is refused rather than let through on a lookup failure. This is deliberately the mirror image
of `physical_session_locked()` (above): that function feeds a *cosmetic* message-relabeling
role and must fail OPEN (an undetermined lock state must never block a connection), while
`seated_uids()` feeds an actual authorization decision and must fail CLOSED, the same posture
`is_admin()` already takes on an unresolvable uid or a missing group. A future reader should
not "fix" `seated_uids()` to match `physical_session_locked()`'s fail-open behavior — they
answer different kinds of questions on purpose. **A per-session `show-session` lookup
failure is ALSO a categorical failure here (returns `None`), not a skip-and-continue** — see
the follow-up below for why the first version of this function got that distinction wrong.

**Deliberately un-hardened at install time, and that is the correct default.** Unlike
`EDY_RDP_ADMIN_GROUP` (which must exist on the host — `sudo` does, on essentially every real
Linux install), `lib/edy-rdp-env.sh` validates `EDY_RDP_SHADOW_GROUP` only for shape (empty,
or a syntactically valid unix group name), never for existence. `rdp-shadow` is a brand-new,
project-specific name that will not exist on any host until an operator creates it, and
`install.sh`'s preflight validates the environment *before* copying anything — hard-refusing
every install and every routine redeploy (this project's own edt1 included) until someone
pre-creates a custom group would be a deploy-breaking foot-gun for no safety gain, since
`is_admin()` already turns a nonexistent group into "nobody is a member" (fails closed) with
no crash risk either way. `EDY_RDP_SHADOW_GROUP` is therefore deliberately **not** in
`install.sh`'s `REQUIRED_ENV`, mirroring `EDY_RDP_REMOTE_ALLOW`'s precedent: `.envdefault`
ships it non-empty (`rdp-shadow`) so it is live on every fresh install, but an operator may
explicitly blank it in their own `.env` as a supported way to turn this extra gate off
entirely and revert to admin-only console gating. **Operational note: the group is not
created or populated by any tooling in this project** — an operator runs `groupadd
rdp-shadow` and `usermod -aG rdp-shadow <user>` themselves (or points the variable at an
existing group) before anyone can shadow a different user's console session; until then the
gate's fail-closed default means nobody can.

**Verification.** `relay/test_edy_rdp_relay.py`: `SeatedSessionPredicate` (pure, literal
`loginctl` property dicts, no subprocess — same style as `LockedScreenHint`) covers the
seated/graphical/non-greeter classification; `ShadowGateDecision` (pure) covers
`shadow_gate_required()` for nobody-seated, requester-seated-alone, a-different-uid-seated,
and the `None` fail-closed case; `ConsoleShadowGate` (integration, `Guard`-style, driving the
real `_peek_scenario_from_connect` with `seated_uids()` monkey-patched the same way
`R.bridge.start_bridge` already is) covers nobody seated (admin gate alone suffices), the
same user seated as the requester (no shadow membership needed), a different user seated
with the requester out of the shadow group (refused), a different user seated with the
requester in it (allowed), the `seated_uids() is None` fail-closed path both with and
without shadow-group membership, and `EDY_RDP_SHADOW_GROUP=` empty disabling the gate
entirely. `run_tests.sh` green throughout (187 relay unit tests across all four suites, up
from 175; no regression in the untouched admin gate, remote-allow, credential-injection, or
any other existing suite).

**Follow-up (same 1.8.0.20260929): two real bugs found by adversarial review, before this
ever reached edt1.** A multi-agent review (four dimensions in parallel, each candidate
finding independently re-checked by a skeptic on a different model) confirmed 3 of 7
candidate findings and refuted the other 4 — including a claim that uid 0 unconditionally
bypasses the gate, which is real but not a bypass (root already has every capability this
gate could possibly restrict, and Cockpit's own shipped default, `/etc/cockpit/disallowed-
users`, refuses a root login in the first place). The two confirmed:

- **The one that mattered: `seated_uids()`'s original per-session failure handling was
  exactly backwards for an authorization function.** It treated a `show-session` call that
  RAISED or returned NON-ZERO the same as "that session doesn't exist" — `continue`, drop it,
  keep going — following `_active_graphical_sessions()`'s existing precedent for a narrow
  session-ended-mid-query race. But that precedent's function is cosmetic (a miscounted
  desktop-in-use tally); this one decides who may watch whom. A reviewer reproduced it
  directly: `list-sessions` reporting two real, seated uids while every `show-session` call
  failed (a plausible transient logind/D-Bus hiccup, not something a requester can trigger on
  demand) made `seated_uids()` return an EMPTY set instead of `None` — silently skipping the
  gate for an admin who was never checked against `rdp-shadow`, in precisely the situation
  the `None` path exists to catch. Fixed: any `show-session` failure (exception, non-zero
  exit, or a seated session with an unparseable `User=`) now fails the WHOLE call closed
  (`None`), not just that one session — there is no reliable way to tell "session ended
  benignly" apart from "logind errored" from the command's output alone, so this trades a
  narrow, rare false "someone might be seated" against ever again silently reporting an empty
  seat that was not. New `SeatedUidsSubprocessHandling` tests drive the REAL function against
  a fake `subprocess.run` (every prior test monkey-patched `seated_uids()` itself away
  entirely, so this exact regression had zero coverage) — a clean success case, a greeter
  correctly excluded, and every failure mode above asserted to return `None`.
- **Two integration tests used uid 0 (root) to prove the gate does NOT apply when it
  shouldn't** — but `is_admin()` returns `True` unconditionally for uid 0 regardless of which
  group is asked about, so those tests could not distinguish "the exemption logic correctly
  skipped the gate" from "the gate ran and trivially passed because the caller is root." A
  mutation test proved it: hard-coding the shadow gate to apply unconditionally to every
  console connect still left the whole relay suite green. Fixed by switching both tests to a
  non-root, non-shadow-group admin uid with `is_admin()` mocked explicitly — the mutation now
  fails both tests, as it should.

`run_tests.sh` green throughout (63 tests in `relay/test_edy_rdp_relay.py` alone, up from
55).

### I51 · New capability/clarification: `cockpit-guac-rdp` group rename, a safe migration, and an explicit non-admin access model · Sev N/A · SHIPPED (1.9.0.20260929)

Not a bug fix — a rename plus a clarification, recorded here in the same spirit as
I47/I49/I50. The relay's unix group was named `edy-rdp` since this project's first
release; it is now `cockpit-guac-rdp`, matching the project's own name. On its own that
is cosmetic. What makes it worth an entry is what it forced this project to finally say
out loud: **membership in this group was already, on its own, sufficient for most of
what the plugin does** — a property that had never been asserted anywhere as a single,
explicit claim, let alone tested.

**The migration.** An already-deployed host (edt1, per `docs/DEFENSE-LAYER.md`) has a
real `edy-rdp` group with real members. A naive check-and-create in `deploy.sh`'s
`create_users()` would have left that group alone and `groupadd`-ed a fresh, EMPTY
`cockpit-guac-rdp` — every member losing access silently the moment the relay/sockets
next restarted onto the new group name. `create_users()` (still `--with-users`-gated)
now prefers `groupmod -n cockpit-guac-rdp edy-rdp` — same GID, same members — falling
back to `groupadd` only when neither name exists. A plain `deploy.sh` run (no
`--with-users`, consistent with every other host-mutating action in this script staying
opt-in) cannot perform that rename itself, so it now warns loudly instead when the old
group exists and the new one does not, naming the exact fix.

**The access model, made explicit for the first time.** `ADMIN_ONLY_SCENARIOS` has
always been exactly `{"console"}` — isolated, virtual monitor, wayland-vnc and greeter
have never had an `admin_required` path, and remote/vnc are admin-gated only when an
operator opts in via `EDY_RDP_REMOTE_ADMIN_ONLY=1` (default off). None of that changed
here. What changed is that it is now: (1) tested — `relay/test_edy_rdp_relay.py`'s new
`NonAdminAccess` class asserts none of the four raise `Refuse` for a non-admin,
non-elevated uid, closing a real gap (nothing before this asserted "no admin path
exists" as its own property, only that specific gates behaved correctly where they did
exist); and (2) documented in one place — `docs/GROUP-ACCESS-MODEL.md` — instead of
scattered inferences across `docs/ARCHITECTURE.md`, `docs/SCENARIOS.md` and the deploy
banner, including an honest operator-facing note that the greeter scenario lets a group
member attempt to sign in as any account the host knows, not just their own, and that
this rename's migration deliberately preserves existing group membership rather than
prompting anyone to re-audit it.

**Verification.** `run_tests.sh` green throughout (199 tests across the four relay unit
suites, up from 195; 67 in `relay/test_edy_rdp_relay.py` alone, up from 63);
`install.sh --verify`'s manifest-completeness gate and `tests/installer_tests.sh`'s
staged installer/deploy roundtrip unaffected by the rename.

**Follow-up (1.9.1.20260929): the migration design above was wrong, found by adversarial
review before this ever reached edt1 or was pushed — and the fix was itself verified live
against edt1's actual group state.** A multi-agent review (three dimensions in parallel,
each candidate finding independently re-checked by a skeptic on a different model)
confirmed 5 of 6 candidate findings. The one that mattered:

- **HIGH: gating the `groupmod` migration behind `--with-users` broke the very
  redeploy pattern this project uses every day.** `install.sh`'s own preflight has
  *always* required `$RELAY_GROUP` to exist *unconditionally*, on the assumption that a
  fresh host ran `--with-users` exactly once at initial setup and every plain redeploy
  since could rely on the group already being there. The 1.9.0 design gated the *rename*
  itself behind that same flag — so a plain `deploy.sh` (no flags), the pattern used for
  every routine update this project makes, and the *only* one self-update's own
  `deploy.sh` invocation ever uses, would print the correct warning and then immediately
  hit install.sh's fatal group-missing check anyway, on every host deployed before this
  rename. Verified directly against edt1's real state (`getent group edy-rdp` →
  `edy-rdp:x:970:cptest,eddie,cpadmin,eddie2`; `cockpit-guac-rdp` does not exist), and
  reproduced end to end: self-update to 1.9.0 would have failed deterministically on the
  one real deployment until an operator stepped in by hand — no access lost (the failure
  is in `install.sh`'s preflight, before anything is rendered), but the just-shipped
  self-update feature (I49) broken for this release. **Fixed:** the rename is now its own
  `migrate_group_rename()`, run *unconditionally* in `do_deploy()` (same reasoning as the
  pre-existing `migrate_legacy_env()`: renaming an *existing* group to the name this
  version's units now reference is a compatibility carry-forward, not a new grant of
  capability) — `create_users()` (still `--with-users`-gated) goes back to a plain
  check-and-create, since the rename has already happened unconditionally by the time it
  runs. A genuinely fresh host, where neither group exists, is untouched by the rename
  step and still needs `--with-users` on its first-ever deploy, exactly as before.
- **A bug the fix itself introduced, caught by this project's own test suite before it
  ever shipped:** making the migration unconditional meant it ran during the staged/
  DESTDIR roundtrip test too — which executes on a real host that may itself have a
  genuine `edy-rdp` group (this one does). Unlike `create_users()`, which was only ever
  implicitly protected by no test passing `--with-users`, the now-unconditional function
  had no guard of its own and attempted `groupmod` against this session's **actual**
  system group table during a test run that must never touch real host state. Caught
  immediately by `run_tests.sh` going red; confirmed no actual mutation occurred
  (`groupmod` failed on privilege first) before fixing it with the same `-z "$D"` guard
  `preflight()`'s noexec check and the `--with-units` unit-enabling step already use.
- Two low-severity documentation fixes: the CHANGELOG's own verification paragraph
  mis-stated the post-rename test count (203 instead of 199); and two comments in
  `relay/selfupdate.py` still said the relay's default `--group` was `"edy-rdp"` after
  the rename changed it.
- **Refuted:** a claim that the new `NonAdminAccess` tests prove nothing because they'd
  also pass for an admin uid — true, but beside the point: they are positive-path
  regression guards, and a mutation test confirmed they correctly fail if an admin gate
  is later added to any of the four scenarios, which is the property that matters.

`run_tests.sh` green throughout after both fixes.

### I52 · "guacd build" self-test false-FAILs for a non-admin (passes only with Administrative access) · Sev L · FIXED (1.9.2.20260929)
Reported live: running Self Tests as a non-admin ("limited mode") always failed "guacd build (FreeRDP 3
needed for grd)"; the identical check passed once Administrative access was turned on. The check itself
(`stSpawn2`, only ever used by this one test) ran `podman ps --filter name=edy-rdp-guacd` with
`superuser: "try"` — which, per Cockpit's own semantics, does NOT reject for a non-elevated session; it
silently runs the command AS THE PLAIN LOGGED-IN USER instead. `edy-rdp-guacd` runs under ROOT's
**rootful** podman (a systemd system unit), a completely separate scope from a regular user's own
**rootless** podman (this project's own already-documented two-scope split — see
`edt1-container-management`-style host notes). So the unprivileged query saw zero containers — not an
error, just the wrong scope — and the check's own `if (!img) return {status:"fail", ...}` branch
correctly, but wrongly, read that as "the container is not running." The intended degrade-to-skip path
(`.catch(...) -> {status:"skip", ...}`) never fired because `"try"` never rejects; it only ever silently
downgrades privilege. **Fixed:** `stSpawn2` now uses `superuser: "require"` — the same option this
file's own admin-elevation-challenge code already uses (`cockpit.file(..., {superuser:"require"})`) —
which DOES reject when the session is not already elevated via Cockpit's header toggle, correctly
routing into the existing skip-on-rejection handler instead of running unprivileged. No prompt is
introduced: elevation still only ever comes from the operator's own "Administrative access" toggle, as
everywhere else in this plugin. Verified: `node --check` clean; manually traced the two code paths
(`superuser:"try"` on a non-elevated session runs unprivileged and returns empty stdout; `"require"`
rejects, landing in the existing catch handler) against Cockpit's documented `cockpit.spawn()` semantics.

### I53 · Opt-in tracing for clipboard/sound decisions · Sev N/A · SHIPPED (1.9.2.20260929)
Not a bug fix — a diagnostic capability, recorded here in the same spirit as I47/I48. Clipboard and
sound are the two features this project's own history shows get reported as "just doesn't work" with
nothing in the UI to go on (see the clipboard root-cause investigation elsewhere in this project's
history, which was only possible by adding ad hoc `console.log` calls by hand and removing them
afterward). A new "Trace clipboard/sound" checkbox (off by default, persisted the same way
Clipboard/Sound already are via `URL_CONTROLS` + localStorage) gates a new `trace(category, msg)`
helper that logs every decision point either feature actually makes to the browser console under a
`[guac-rdp:clipboard]`/`[guac-rdp:sound]` prefix: whether `enable-audio` was negotiated at connect, every
`AudioContext` suspend/resume transition (and why), both clipboard auto-sync directions (remote→browser
via `client.onclipboard`, browser→remote via the focus handler) including byte counts and every reason a
sync was skipped or blocked by the browser's Clipboard API, and the manual Send/Receive clipboard
buttons. Deliberately logs **byte counts, never clipboard contents** — this is meant to be left on
during a live support session without exposing what was actually copied. Zero effect on the connection
itself; when the toggle is off (the default) every call is a single `if (!traceOn) return` with no
console output at all. Verified with a jsdom smoke test (scratch project, not a repo dependency, deleted
after use) loading the real `index.html` + `guac-rdp.js`: the checkbox exists and starts unchecked,
toggling it on/off emits/withholds the enabled/disabled marker, and the Clipboard/Sound toggles' own
trace lines appear only while tracing is on. `run_tests.sh` green throughout.

### I54 · Five new Self Tests: guacd digest pin, grd patch integrity, PulseAudio TCP, vendored-lib ownership, group membership · Sev N/A · SHIPPED (1.9.3.20260929)
Not a bug fix — five new read-only checks added to the existing Self Tests panel (`SELF_TESTS`,
`guac-rdp.js`), each surfacing something this project had already identified as a real risk but only
checked at install/deploy time, or only in a design document, never live and on demand.
- **"guacd image matches the pinned digest"** is the live equivalent of `install.sh --verify`'s own
  check 2 (same `INSTALL_PATH` → `.env` → `GUACD_IMAGE` lookup, same `podman inspect --format
  {{.ImageName}}`) — lets an operator check for image drift anytime, not just at deploy time. Needs
  `superuser:"require"`, same reason as the existing "guacd build" check: `edy-rdp-guacd` runs under
  ROOT's rootful podman, a separate scope from a logged-in user's own rootless one.
- **"gnome-remote-desktop patch integrity"** is the live equivalent of `install.sh --verify`'s check 3
  (`patches/README.md`): the 3390 greeter handover needs a hand-rebuilt daemon installed OVER the stock
  package path, protected only by an `apt-mark hold` — an upgrade that gets through (a forced reinstall,
  an OS version bump, the hold being lifted) silently reverts it with nothing else noticing. Compares the
  live daemon against the `.orig-edt1` stock backup the patch procedure itself leaves (`cmp -s`), and
  separately flags a patched-but-unheld daemon as its own distinct failure (the patch is still in place
  today, but the next unattended upgrade will remove it). Read-only; no elevation needed.
- **"No anonymous PulseAudio TCP (4713)"** turns the still-open KNOWN_ISSUES I44 finding (a stale
  `~/.config/pipewire/pipewire-pulse.conf.d/20-edy-tcp.conf` drop-in leaving an anonymous-auth TCP
  listener up, although CHANGELOG 1.2.9 says the TCP approach was removed) into a live, on-demand check
  instead of something only documented. Same `ss -tln` pattern as the existing "guacd listening on
  loopback only" check, inverted: here the only correct state is nothing listening at all.
- **"Vendored client library ownership matches served tree"** turns the DEFENSE-LAYER design review's
  D-13 finding (`guacamole-common-js/all.min.js` found owned differently from the rest of this plugin's
  served files — a provenance anomaly from being placed outside the normal install pipeline, not a
  content problem) into a live check, comparing its ownership against `manifest.json`'s (shipped by the
  same `install.sh` PAGE manifest entry) as the reference.
- **"cockpit-guac-rdp group exists with expected membership"** confirms the group the I51 rename
  produced still exists with `edy-relay` as a member, live and on demand, rather than only at
  install/deploy time.
- **Deliberately not added in this pass:** a "Dependency tracking status" check surfacing the
  dependency-tracking feature's own `deps-status` control op — that feature (I51 follow-up work) is still
  on its own, separate, not-yet-merged branch; the check will ship as part of that branch instead of being
  built against a control op that does not exist yet on `main`.
- **Verification:** `run_tests.sh` green throughout. A jsdom smoke test (scratch project, not a repo
  dependency, deleted after use) loaded the real `index.html` + `guac-rdp.js`, stubbed `cockpit.spawn`
  with a per-command fake dispatcher, and drove six scenarios through the real "Run self tests" button:
  every check passing on a fully-healthy host; every check failing on a fully-broken one; the
  patch-never-applied-here skip path; the patched-but-unheld failure distinct from the stock failure; a
  group that exists but is missing the expected member; and the guacd-container-not-running skip path —
  all six produced the exact expected pass/fail/skip status and detail text.
  **Also live-tested**, running each check's exact shell command (not the jsdom fake dispatcher) against
  two real hosts: a full `deploy.sh --with-users` onto the `rockytest` Rocky 9 container (a genuinely
  fresh RHEL-family host, `apt-mark` absent, no grd patch ever applied there) confirmed the
  `INSTALL_PATH` → `.env` → `GUACD_IMAGE` lookup, the `stat`-based ownership comparison, and the
  `getent`/`id -nG` group-membership lookup all parse real dnf-host output correctly and resolve to PASS
  once the deploy completed (guacd itself correctly SKIPs there, since `--with-image`/`--with-units`
  were deliberately not passed — Rocky 9 lacks a stock FreeRDP 3 package, a known, pre-existing
  limitation of this container, unrelated to this change); and edt1 itself (the one real host the grd
  patch is actually deployed to) confirmed the patch-integrity check's full PASS path
  (`APTMARK=yes HELD=yes STATE=patched`) against the genuine patched binary. Read-only checks against
  edt1's OWN current live state (not redeployed there — edt1 is still on an older, pre-group-rename
  version) incidentally reconfirmed two already-known, real gaps this feature is meant to catch: I44's
  PulseAudio TCP listener is still live on 127.0.0.1:4713 right now, and edt1's `cockpit-guac-rdp` group
  does not exist yet (edt1 has not been updated past the pre-rename `edy-rdp` name) — exactly the kind of
  drift "No anonymous PulseAudio TCP (4713)" and "cockpit-guac-rdp group exists with expected membership"
  exist to surface once this ships and edt1 is eventually updated.

### I55 · `EDY_RDP_SHADOW_GROUP` default renamed to `cockpit-guac-rdp-shadow`, and `--with-users` now guarantees it exists · Sev N/A · SHIPPED (1.10.0.20260929)
Not a bug fix — a rename plus a reversal of one part of I50's original product decision, recorded here
in the same spirit as I51 (which this entry otherwise leaves untouched: I50's own reasoning for shipping
the shadow gate fail-closed and un-hardened-at-install-time is still valid and still applies; what
changed is a narrower, later decision about who creates the group, not why the gate behaves as it does).

**The rename.** I50/1.8.0 shipped `EDY_RDP_SHADOW_GROUP` defaulting to `rdp-shadow`, chosen before I51/
1.9.0 renamed this project's own relay group `edy-rdp` → `cockpit-guac-rdp`. The default is now
`cockpit-guac-rdp-shadow`, matching that same convention. `relay/edy_rdp_relay.py`'s three `"rdp-shadow"`
literal defaults (`Connection.__init__`, `handle()`, `--shadow-group`'s `argparse` default) and
`.envdefault`'s shipped value all moved together; nothing about the gate's own logic changed. Found by
adversarial review, missed in the first pass: `systemd/edy-rdp-relay.service.in`'s own
`Environment=EDY_RDP_SHADOW_GROUP=` fallback line still named the old default. `.env`'s own value
normally shadows it, but on any host where `EDY_RDP_SHADOW_GROUP` were ever absent from the effective
`.env` (a hand-edited file, a future `env_place` regression), the relay would silently fall back to
gating console-shadow access on the retired group name instead of the new one — fixed in the same
commit as the rest of the rename, not a separate follow-up.

**The migration — two independent, unconditional, idempotent steps, mirroring I51's own
`migrate_group_rename()`.** A new `migrate_shadow_group_rename()` in `deploy.sh`, run right after
`migrate_group_rename()` on every `do_deploy()` (no `--with-users` gate, same reasoning I51 already
settled: renaming something that already exists on an already-deployed host is a compatibility
carry-forward, not a new grant of capability) and guarded by the identical `[[ -z "$D" ]] || return 0`
a staged/DESTDIR test roundtrip needs for the same reason I51's guard does:
1. A real `rdp-shadow` group, if one exists and `cockpit-guac-rdp-shadow` does not, is renamed in place
   (`groupmod -n`, same GID and members preserved) — a plain check-and-create here would have left a
   real group's members behind and created a second, empty one under the new name. If
   `cockpit-guac-rdp-shadow` already exists (a prior run of this same migration, or an operator who
   already created it by hand under the new name), this step does nothing and that is not an error.
2. Separately, this host's own `.env` — if it carries the *exact*, full-line old default
   (`EDY_RDP_SHADOW_GROUP=rdp-shadow`, checked with `grep -qx`, never a substring match) — is rewritten
   in place to the new default. This is NOT the same kind of migration as (1): a deployed `.env`'s value
   only ever got there because an earlier deploy's `install.sh` reconciliation step auto-filled it
   *from `.envdefault` at the time*, so it must track the new default the same way (1) retargets the
   group that old default used to name. An operator who deliberately chose some *other* group name is
   never touched by this line, by construction of the exact-match check. The one intentionally
   unhandled edge case: an operator who happened to deliberately choose the literal string `rdp-shadow`
   itself as their own custom group name — astronomically unlikely, and harmless either way (their
   group either already exists, and step (1) already left it alone, or it does not, and pointing their
   `.env` at the new default is a reasonable outcome) — no extra logic was added to try to distinguish
   this from the common case, deliberately, since there is no way to and no need to.

**The reversal: `--with-users` now guarantees the group exists.** I50 deliberately left this group
uncreated by any tooling — "an operator's own, deliberate step" (see I50, above) — reasoning that
`install.sh`'s preflight never required it to exist (unlike `EDY_RDP_ADMIN_GROUP`), so nothing forced an
operator to have it ready before a routine deploy. That reasoning about the *preflight* is unchanged and
still correct. What changed is the separate question of whether `deploy.sh` should offer to create it
for an operator who *does* opt in, the same way it already creates `RELAY_GROUP`/`RELAY_USER` under that
flag. A new `ensure_shadow_group()`, gated behind the same `WITH_USERS` flag (no new flag introduced),
reads the resolved `EDY_RDP_SHADOW_GROUP` out of `$ENVF` and `groupadd --system`s it if missing and
non-empty; a blanked value (the gate turned off) creates nothing, matching the gate's own semantics.

**Ordering constraint (this is why the call site is not simply "beside `create_users()`").**
`create_users()` runs *before* `do_deploy()` invokes the installed `install.sh`, because `install.sh`'s
own preflight (check 8) requires `RELAY_GROUP`/`RELAY_USER` to already exist. But at that point `.env`
has not yet been placed or reconciled — `install.sh` is what does that. `EDY_RDP_SHADOW_GROUP` carries
no equivalent preflight requirement (`lib/edy-rdp-env.sh`'s validation for it deliberately has no
`getent`-existence check, for the same reason I50 gave: refusing every install over a not-yet-created,
project-specific group name would be a needless, deploy-breaking foot-gun), so nothing forces
`ensure_shadow_group()` to run early. It instead runs *after* the installed `install.sh` completes, so
it reads the FINAL, fully-reconciled `.env` — respecting an operator's actual customized value, or a
value this same release's `migrate_shadow_group_rename()` (2) just rewrote — rather than guessing at a
value from `.envdefault` before reconciliation has happened, which would create the wrong group
entirely on any host that customizes this variable.

**Verification.** `run_tests.sh` green throughout (199 relay unit tests, unchanged — only a test
fixture default moved in `relay/test_edy_rdp_relay.py`'s `_conn()`). `tests/installer_tests.sh` gained
two tests: `deploy_migrate_shadow_group_rename` (a real `rdp-shadow`-named group renamed with members
preserved; an `.env` carrying the exact old default rewritten; a deliberately-customized `.env` value
left untouched by both the rename and the rewrite even with a real `rdp-shadow` group also present; a
second run of every case above a safe no-op) and `deploy_ensure_shadow_group` (the group created when
missing and non-empty; left alone when it already exists; nothing created when blanked; structurally
confirmed to still be gated behind `((WITH_USERS))`). Both `groupadd`/`groupmod`/`getent` and the
group-rename migration call real system commands against the actual host account table exactly like
`create_users()`/`migrate_group_rename()` already do, and this suite's own header states its invariant
plainly: non-root, nothing on the host touched. Reaching either function's real (non-staged) code path
through `deploy.sh` itself needs root, which these tests intentionally never assume — so, like
`load_manifest()` above already does for `install.sh`'s `BEGIN-MANIFEST`/`END-MANIFEST` block, both new
tests extract just the one function's source with a `sed` range and drive it directly against fake
`getent`/`groupmod`/`groupadd`/`say` shell functions (a bare command name resolves to a same-named shell
function before `PATH`, so these shadow the real tools with no `PATH` trick needed); the host's actual
`/etc/group` is never touched no matter who runs this suite.
