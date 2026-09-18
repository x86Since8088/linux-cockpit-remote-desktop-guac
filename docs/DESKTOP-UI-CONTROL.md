# Desktop UI control

The **Desktop UI** tab turns the host's graphical desktop on or off — now, or at
boot — from inside Cockpit. It is a thin, guarded front end over the display
manager and the default systemd target; it does not touch RDP or guacd.

It exists for hosts you administer **remotely** — servers and headless VMs where
the desktop is a managed service you want to bring up for a maintenance window and
take back down afterwards. It is deliberately awkward to use against a machine
somebody is sitting at (see *Guardrails*).

## What each action does (operation → systemd)

| Action | systemd |
|---|---|
| **Enable at boot** | `systemctl set-default graphical.target` + `systemctl enable <display-manager>` |
| **Disable at boot** | `systemctl set-default multi-user.target` + `systemctl disable <display-manager>` |
| **Start now** | `systemctl start <display-manager>` (no DM installed → `systemctl isolate graphical.target`) |
| **Stop now** | `systemctl stop <display-manager>` (no DM installed → `systemctl isolate multi-user.target`) |

The **display manager is detected, never assumed.** systemd maintains
`/etc/systemd/system/display-manager.service` as an alias symlink to the active
DM unit; the helper reads that first, then falls back to probing known unit names
(`gdm`, `gdm3`, `lightdm`, `sddm`, `lxdm`, `xdm`, `nodm`, `ly`, `greetd`). A host
with no display manager still gets its default target flipped, and *Start/Stop*
fall back to isolating `graphical.target` / `multi-user.target`.

The tab also shows a **read-only state** on every host: what it boots to, which
display manager it uses and whether that DM is running / enabled, and how many
graphical desktop sessions are **in use right now** (the number a *Stop* would end).

## Guardrails — "don't kill your own desktop"

Turning the desktop off is a footgun: run *Stop* against the machine you are
sitting at and you end your own session. Four independent layers stand in the way,
every write-side one enforced **server-side** (a browser check is cosmetic):

1. **Opt-in, fail closed (the main switch).** Writing is off unless the host sets
   `EDY_RDP_DESKUI_ENABLE=1` in its `.env`. A host that has not opted in can only
   *read* state; every write action is refused — by the relay, and again by the
   privileged helper, which reads the same flag through its unit's
   `EnvironmentFile`. **An operator's own workstation simply never sets this**, so
   the feature is inert there no matter who clicks what.
2. **Administrative access.** Every write requires a Cockpit administrator, gated
   on the caller's `SO_PEERCRED` uid and the admin group — the same gate as the
   session-unlock verb.
3. **Typed-name confirmation.** *Stop* and *Disable* refuse unless the operator has
   typed **this host's name** into the panel. The button stays disabled until it
   matches (client side), and the relay re-checks the typed name (server side)
   before it acts. Stopping while a desktop is in use additionally escalates to a
   `stop-force` verb that only this confirmed path can reach.
4. **Live-console refusal (in the privileged helper).** Plain `stop` refuses while
   any active, graphical, **seated** session exists — you cannot cut the desktop
   out from under someone using it. Only `stop-force` overrides that, and the relay
   issues `stop-force` solely after the typed-name confirmation above. Greeters and
   seatless (TTY / remote / service) sessions are not counted.

> The safety rule during development was blunter still: **never exercise these
> verbs on the operator's live workstation.** The functional tests run only in a
> throwaway container/VM. Layer 1 is what makes that rule enforceable in
> production — leave `EDY_RDP_DESKUI_ENABLE` unset on any host with a console you use.

## How it is wired (same pattern as the rest of the plugin)

Reads are unprivileged and writes go through a privileged oneshot unit — the same
read/write split as everything else here.

- **Read** (`deskui-status`): the relay runs `systemctl get-default`,
  `is-active` / `is-enabled`, reads the DM alias symlink and counts `loginctl`
  sessions — all read-only, as the unprivileged `edy-relay` uid. No escalation.
- **Write** (`deskui`): the relay validates admin + opt-in + confirmation, then
  starts `edy-rdp-deskui@<action>.service`. The relay itself is unprivileged; a
  polkit rule (`hardening/edy-rdp-headless.rules`) lets `edy-relay` start **only**
  the `edy-rdp-deskui@` unit family, and the helper
  (`deskui/edy-rdp-deskui.sh`, in `/usr/libexec/edy-rdp`) validates `%i` against a
  **fixed action enum** — there is no path that runs a caller-supplied unit,
  systemctl verb or command.

```
browser (Desktop UI tab)
   │  cockpit.channel -> /run/edy-rdp/control.sock  (SO_PEERCRED)
   ▼
edy-relay  (unprivileged)  ── reads: systemctl/loginctl (status)
   │  writes: systemctl start edy-rdp-deskui@<action>   (polkit-granted, this family only)
   ▼
edy-rdp-deskui@<action>.service  (root, oneshot)
   ▼
edy-rdp-deskui <action>   enum-validated · opt-in-gated · live-console-guarded
   ▼
systemctl set-default / enable / disable / start / stop  <graphical stack>
```

## Enabling it on a host

```sh
# In the host's .env (see .envdefault):
EDY_RDP_DESKUI_ENABLE=1
systemctl restart edy-rdp-relay.service
```

Leave it unset (the default) to keep the tab read-only. Do **not** set it on a host
whose graphical console you use locally.
