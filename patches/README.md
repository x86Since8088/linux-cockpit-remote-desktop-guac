# grd handover patch — 3390 Remote-Login greeter (KNOWN_ISSUES I29)

> **STATUS: NOT DEPLOYED.** Reverted to the stock package daemon on user request
> (2026-09-01, I29 addendum 5): stock binary restored (dpkg-clean), D-Bus drop-in
> removed, apt hold released, backup deleted. This patch stays as the reproducible
> recipe if the greeter fix is ever wanted again. NOTE: the original "signal never
> delivered" symptom was likely the old receive-deny drop-in (also now gone), so
> stock grd may hand over correctly without this patch — untested.

## THE FIX: `grd-handover-method-call.patch`  ✅ verified working when deployed (2026-09-01)

Fixes the 3390 "Remote Login" (greeter) handover on edt1. gnome-remote-desktop's
system daemon signals the greeter's handover daemon with `TakeClientReady` once the
redirected client reconnects. On this host the bus **never delivers Handover-interface
signals** to the handover daemon — broadcast *or* directed (proven with dbus-monitor +
Gio subscribers + `G_DBUS_DEBUG=signal`; ObjectManager signals from the same sender ARE
delivered; a maximally-permissive D-Bus policy does not help). D-Bus **method calls**,
however, are delivered reliably (`StartHandover` always worked).

So this patch removes the `TakeClientReady` *signal* from the handshake and drives the
FD hand-off entirely with **method calls**:

* **Handover daemon** (`grd-daemon-handover.c`): right after `StartHandover` returns the
  cert/key, it calls `TakeClient` **proactively** — before the client has reconnected —
  guarded by a `take_client_requested` flag.
* **System daemon** (`grd-daemon-system.c`): `on_handle_take_client` no longer requires
  `socket_connection` to be set. If the client has not reconnected yet it **stores the
  invocation** (`pending_take_client_invocation`) and returns; when the redirected
  connection arrives (`on_incoming_redirected_connection`) it completes the pending call
  with the client FD instead of emitting `TakeClientReady`. Either ordering resolves via
  `socket_connection`. `abort_handover` and `grd_remote_client_free` return an error on
  any still-pending invocation so the handover daemon never hangs.

Verified end-to-end: xfreerdp3 → `127.0.0.1:3390` (door credential `rdplogin`) renders
the GDM greeter, a mouse click selects a user, and a password login lands the user's
desktop. Server journal shows `received TakeClient call` **before** `Incoming connection
with routing token`, and **no** `Aborting handover` (no 30 s timeout).

### Apply / build / deploy (against gnome-remote-desktop 50.2 source)
```
patch -p1 < grd-handover-method-call.patch
meson setup build --prefix=/usr -Dbuildtype=release -Dfdk_aac=false -Dman=false -Dtests=false
ninja -C build src/gnome-remote-desktop-daemon
# back up the stock binary, then install the rebuilt daemon over it:
cp -a /usr/libexec/gnome-remote-desktop-daemon /usr/libexec/gnome-remote-desktop-daemon.orig-edt1
install -m0755 build/src/gnome-remote-desktop-daemon /usr/libexec/gnome-remote-desktop-daemon
systemctl restart gnome-remote-desktop.service
```
One binary serves `--system` (3390) and `--handover` (greeter); both sides of the patch
ship in it. The greeter's handover daemon is spawned per-connection by GDM, so it picks
up the new binary on the next connect. A door credential must be configured:
`grdctl --system rdp set-credentials rdplogin <key>` (the client passes NLA against it;
the real login happens at the GDM greeter). NOTE: an apt upgrade of gnome-remote-desktop
overwrites the daemon — re-apply after upgrades.

## SUPERSEDED: `grd-handover-takeclientready-directed.patch`  ❌ did not work
Earlier attempt that emitted `TakeClientReady` **directed** (like `RedirectClient`)
instead of broadcast. Confirmed directed on the wire, but the handover daemon still never
received it — the bus refuses Handover-interface signals regardless of addressing. Kept
only for the record; do not use.

## Audit hardening (2026-09-01)
A regression/correctness audit of the method-call patch produced two robustness fixes, now folded into
`grd-handover-method-call.patch` and the deployed daemon (rebuilt, sha `5c08514e…`):
* **S1 — reset `take_client_requested` per handover cycle** (`grd-daemon-handover.c`, top of
  `start_handover`). The flag is set when StartHandover returns; without clearing it each cycle, a handover
  daemon reused for a second redirect would skip the proactive TakeClient and hang until the 30 s abort.
  Reset-then-set is a no-op for the normal single-cycle flow.
* **Guard against orphaning a pending invocation** (`grd-daemon-system.c`, `on_handle_take_client`): a
  duplicate/early TakeClient now returns `G_DBUS_ERROR_FAILED "TakeClient already pending"` instead of
  overwriting `pending_take_client_invocation` (which would leak the first into a 25 s D-Bus timeout).

**Precondition (documented, out-of-scope for this deployment):** the proactive path is correct for the
rdstls case (`use_system_credentials == FALSE`) — guacd/FreeRDP and rdstls-capable mstsc. A legacy mstsc
that does NOT request rdstls sets `use_system_credentials = TRUE` and needs the `GetSystemCredentials`
step this path skips; such a client would fail NLA. Not fixed because every client on this host requests
rdstls. See KNOWN_ISSUES I29 addendum 4 and the audit synthesis.

**Also:** `gnome-remote-desktop` is now `apt-mark hold`d so an unattended upgrade cannot silently revert
the daemon; `install.sh --uninstall` now restores the stock daemon from `.orig-edt1`, clears the door
credential, `apt-mark unhold`s, and reloads D-Bus.
