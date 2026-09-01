# Scenarios (with screenshots)

The plugin exposes three connection scenarios plus a session-tracking view. The images
below are captured from the live system by `cockpit-e2e/tests/doc-shots.spec.js`, running
as the **non-admin** throwaway user `cptest` — so the isolated desktop shown is a fresh,
empty session with no private content.

## The plugin page

![Remote Desktop plugin, idle](../img/plugin-ui-idle.png)

The "Remote Desktop" page under Cockpit's *System* menu. A **Connect** tab (session
picker + Connect/Disconnect) and an **Active Sessions** tab (the live session table).
Everything rides Cockpit's own HTTPS session; no port is exposed.

## Isolated desktop (your own private session)

![Isolated desktop connected](../img/scenario-isolated-fullpage.png)

Your own headless GNOME desktop, separate from the physical console — *"Started on demand;
you reach your own session; no credentials needed."* It is a real, persistent desktop:
disconnect and reconnect within 15 minutes and you land back on the **same** desktop
(identified by a stable `DESKTOP_ID` UUID). The first connect takes ~20 s to spin up the
session; reconnects are immediate.

Just the rendered display (a fresh GNOME Activities overview):

![Isolated desktop display](../img/scenario-isolated-desktop.png)

## Console (mirror of the physical screen) — admin only

![Console gate refuses a non-admin](../img/console-gate-refused.png)

The **console** scenario mirrors the physical display and is gated to Cockpit
administrators. A non-admin gets *"Console needs administrative access."* The gate is
enforced **server-side** by an elevation-proven session token (reading a root-only
challenge over a superuser Cockpit channel), not by a client-side check — so it cannot be
bypassed by driving the tunnel directly (see [KNOWN_ISSUES](KNOWN_ISSUES.md) I4). No
screenshot of a live console mirror is included here because it would show the operator's
real desktop.

## Virtual monitor

A second monitor attached to your *own* logged-in session (not the console, not a separate
login). Same rendering path as the console; requires you to be that logged-in user.

## Session tracking

The **Active Sessions** tab reads the relay's registry: each row is a live session with
its owner uid, scenario, and virtual-desktop identity. Inactive sessions are torn down on
disconnect (bridge + guacd connection released immediately); the backing desktop persists
for the reconnect window, then the reaper reclaims it once idle. See
[ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together.
