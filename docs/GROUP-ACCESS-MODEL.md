# The `cockpit-guac-rdp` group access model

This document exists because the group was, until this version, named `edy-rdp` (see
CHANGELOG), and the rename was the occasion to write down plainly what membership in it
actually grants — something that was previously scattered across `docs/ARCHITECTURE.md`,
`docs/SCENARIOS.md`, `docs/DEFENSE-LAYER.md` and the deploy banner, with no single place
that added it up. Nothing below is new behavior; it describes what this project already
does, in the same "state the real limitation plainly" spirit as `docs/DEFENSE-LAYER.md`'s
threat tables and `docs/SELFUPDATE.md`'s Trust model section.

## 1. What the coarse group gate actually grants

The AF_UNIX sockets (`guacd.sock`, `control.sock`) are `SocketMode=0660 SocketGroup=cockpit-
guac-rdp`, inside `/run/edy-rdp` (`0750 root:cockpit-guac-rdp` — the group gets `r-x`, list
and traverse, never write: a member cannot unlink the sockets themselves). Cockpit-bridge
connects to these **as the logged-in system user**, so ordinary kernel DAC on that socket
mode and group is the *entire* gate for reaching the relay at all — there is no separate
PAM or polkit restriction shipped by this project on top of it, and `manifest.json` declares
no admin-only visibility for the Cockpit menu entry. Once a connection reaches the relay,
`SO_PEERCRED` identifies the caller and the per-scenario logic in
`relay/edy_rdp_relay.py` decides what that uid may do — but for most scenarios that logic
adds nothing beyond "you are the group": see §2 and §3.

Reaching the relay is coarse-grained on purpose, and there is no finer control today: no
per-scenario rate limiting, no audit trail beyond the relay's own trace log, and no way to
grant a member some scenarios but not others short of the admin and shadow-group gates that
already exist for the two scenarios sensitive enough to need them (console, and shadowing a
*different* seated user's console session — see §2). A group member is, in effect, trusted
with everything this plugin can do except those two things.

## 2. Isolated, virtual monitor, wayland-vnc, greeter

**Isolated** and **virtual monitor** give a member their *own* desktop or their *own* logged-
in session extended — low risk relative to the others, since a member can only ever reach
something that is already theirs. **wayland-vnc** is the same shape.

**Greeter reaches the actual login screen of the physical host.** A group member can attempt
to sign in through it as *any account the host knows*, not only their own — the greeter does
not know or care which group member is asking. This is worth an operator knowing explicitly;
it is not something this task tightens. Actually restricting it would be a product/scope
decision (a smaller, separately-provisioned group for greeter access, the way `console`
already has `EDY_RDP_SHADOW_GROUP` for a narrower question) — flagged here as a discussion
point, not built in this pass (see `docs/KNOWN_ISSUES.md`).

None of these four scenarios has an `admin_required` path (`ADMIN_ONLY_SCENARIOS = {"console"}`
in `relay/edy_rdp_relay.py`) — reaching the socket, i.e. group membership, is already fully
sufficient for a member to use them today, with no Cockpit-administrator status of any kind.

## 3. Remote host / vnc

Remote/vnc let a group member dial the relay **out** to any host on the operator-curated
`EDY_RDP_REMOTE_ALLOW` allow-list, using either the server's automatic gate credential or the
member's own supplied credentials depending on which scenario and auth mode is in play. The
real control here is **the allow-list itself** (empty = deny-all by default) plus the optional
`EDY_RDP_REMOTE_ADMIN_ONLY` — group membership by itself decides nothing about *which* hosts
are reachable, and remote/vnc are admin-gated only when an operator explicitly sets
`EDY_RDP_REMOTE_ADMIN_ONLY=1`; the shipped default (`0`) leaves them open to every group
member against whatever the allow-list contains.

## 4. Console (for contrast)

Console is the one scenario that needs more than group membership unconditionally: an
elevation-proven Cockpit-administrator check (I4), server-side, on every connect. When a
*different* user is currently seated at the physical console, it additionally requires
`EDY_RDP_SHADOW_GROUP` membership on top of the admin gate (I50) — both already shipped,
already reviewed, untouched by this change.

## 5. Hardening recommendations for an operator

Each of these is a real trade-off, not a checkbox:

- **(a) Treat group membership as the primary access control it is.** Per §1–§3, membership
  in `cockpit-guac-rdp` already grants isolated/virtual/wayland-vnc/greeter access and, under
  the default configuration, remote/vnc access too — with none of the auditing or per-scenario
  granularity a smaller privileged group would usually get. Review the membership list
  periodically, the way you would any other privileged unix group, and do not fold it into a
  default login-shell provisioning profile.
- **(b) Set `EDY_RDP_REMOTE_ADMIN_ONLY=1`** if remote/VNC access to allow-listed hosts should
  be admin-only rather than open to every group member. Trade-off: every non-admin group
  member loses remote/vnc access outright, including legitimate uses, since this project has
  no per-user allow-list, only a global admin/non-admin switch.
- **(c) Keep `EDY_RDP_REMOTE_ALLOW` as narrow as operationally possible.** This control
  already exists and is unchanged by this rename; it is restated here because it is, per §3,
  the *actual* gate on remote/vnc reachability, not group membership.
- **(d) Scope greeter access as tightly as physical console access, not more loosely.** Per
  §2, any group member can attempt authentication as any host account through the greeter
  scenario. A host where "in the group" is treated more casually than "has physical access to
  the console" has a real gap between its own security posture, because greeter access
  functionally *is* console access to the login prompt.
- **(e) The rename does not re-audit who is in the group.** The `groupmod` migration in Task A
  deliberately **preserves** existing membership — that is the correct, non-disruptive
  behavior for an upgrade (see CHANGELOG), but it means nobody is prompted to check whether
  that membership list is still correct. A rename is nonetheless a natural moment for an
  operator to actually look at who is in the group and why.

## 6. Not built, future work

Matching how `docs/DEFENSE-LAYER.md` marks its own unbuilt sections: a narrower,
separately-provisioned group for the greeter scenario specifically (mirroring
`EDY_RDP_SHADOW_GROUP`'s pattern for console) is a genuine idea raised by §2, but it is a new
gate, not a rename-and-document task, and is deliberately not built here. See
`docs/KNOWN_ISSUES.md` I51.
