# Pattern adoption — cockpit-guac-rdp

How this project relates to `ai-orchestrator/project-patterns/`. Recorded in
`.patterns.json`; this file is the human-readable map.

| Pattern | Status | Where / how |
|---|---|---|
| **peercred-unix-relay** | **authored here** | `source/relay/edy_rdp_relay.py`. New stub contributed to the library; this project is its first consumer. AF_UNIX relay as the sole ingress to an unauthenticated backend (guacd), authenticating the peer by `SO_PEERCRED` and binding each backend session UUID to that uid. |
| singleton-with-checkpoints | shape adopted | `source/relay/session_registry.py` uses atomic `.tmp`+`os.replace` and restart-resume — the checkpoint primitive — over JSON rather than YAML. The relay is a single-instance service. |
| data-root-with-acl | kin (variant) | `/run/edy-rdp` (0750 root:edy-rdp) is the run-root; the `edy-rdp` group is the coarse ACL; the persisted `session_registry` is the control/breadcrumb. Identity comes from `SO_PEERCRED`, not DB principals — so it is a variant, not a straight adoption. |
| user-agent-session-binding | sibling | Same taxonomy ("bind a session to an identity signal; refuse on mismatch"), but the signal is the AF_UNIX peer uid, not the UA header. The mismatch response is a hard refuse (`error/769`). |
| api-security | shape adopted | The relay's console-admin gate (per-action role) and the RDP-target allow-list (egress restriction) are the same per-action-gate + allow-list shape, enforced server-side. |
| structured-errors | referenced only | The relay's control surface is the Guacamole wire protocol, so its errors are `error` instructions, not the `{ok:false,errors:{}}` envelope. Use that envelope for any HTTP admin surface added later. |

Deliberately **not** adopted: `self-describing-config`, `port-discovery` (no HTTP API — guacd
has no exposed port by design), `service-wrapper-nssm`/`windows-service-nssm` (Linux), the Go/Node
auth-schema patterns (auth here is the relay + Cockpit PAM, not a web auth.db).
