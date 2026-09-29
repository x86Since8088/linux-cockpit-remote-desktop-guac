# Relay defence layer — output filtering, secret sanitisation, deception

> **STATUS: DESIGN, not deployed.** Written 2026-09-27 against v1.3.2 (`8fc87cc`) after a
> 33-agent review: five independent code readers (relay, client, guacd posture, existing
> security docs, event sink), one threat map, three independent designs (protocol firewall /
> need-to-know / deception), a judge that merged them, one adversarial critic per control
> (22 of 22 came back **repair**, none *keep*, none *drop*), and a completeness pass that found
> 16 gaps. Every control below is stated **after** its critic's repair. Line references are to
> `8fc87cc`; they will drift, the function names will not.
>
> Read §4 first. It lists what is a **defect today**, not a design choice. §6–§9 are the plan.

The three asks this answers, in the user's words: review the layers where *middleware* can
filter for threats by **filtering outputs**; inject **masked, random or decoy URLs/identifiers**
that only a bad actor would ever use, so that touching one **triggers a security event**; and
plan a layer that **sanitises RDP/guac secrets that do not need to be relayed from the host** —
all to protect the guacd service.

## 0. Summary

1. **The five named CVEs are closed by version.** The live image
   `ghcr.io/skylark-software/janua@sha256:2279eac0…` is Janua **1.0.1** = the Apache
   `guacamole-server-1.6.0` tarball + FreeRDP 3.10.3 + three Janua RDP patches on Debian 13
   (Janua `guacd/Dockerfile`, CHANGELOG 1.0.0/1.0.1). CVE-2020-9497/9498 (fixed 1.2.0),
   CVE-2023-30575/30576 (1.5.2), CVE-2023-43826 (1.5.4), CVE-2024-35164 (1.5.5) are all
   behind it. What this design defends against is the **next bug of each class** — and, as
   §4 shows, several holes that exist regardless of guacd's version.
2. **The reverse-RDP surface of this deployment is not guacd.** Every relay-managed scenario
   (console, virtual, greeter, isolated, remote) is rewritten so guacd speaks **VNC** to a
   host-local x11vnc on an Xvfb that `xfreerdp3` paints (`_inject_vnc_target`,
   relay :1131-1143). A malicious RDP server therefore attacks **`xfreerdp3` running on the
   host as uid `edy-relay`**, inside the relay's own unit — the uid that is admitted to
   guacd:4822, reads every bridge/headless credential and holds the polkit grants. Only the
   `vnc` scenario hands guacd an operator-chosen server. `docs/CVE.md` used to say VNC was
   "not applicable"; it is the one class squarely in path.
3. **There is exactly one choke point, and it is already the right shape.** The relay
   fully re-parses (`parse_one`/`drain` :125-165) and re-encodes (`encode` :107-112) every
   instruction in both directions (`on_up` :1235-1239, `on_down` :1241-1254). A hostile
   browser can never deliver a non-canonical length prefix to guacd today. Everything in this
   plan hooks that path; nothing adds a hop.
4. **Three layers on that choke point, plus the two things the relay cannot do alone:**
   *prevent* (codec hardening, handshake state machine, connect authoring, target fence),
   *minimise* (reason codes, scrubbed outputs, handle aliasing, server-side credentials, file
   modes), *detect* (zero-false-positive decoys, backend detectors, a structured
   security-event contract) — and, outside the relay, container/egress posture and moving
   `xfreerdp3` out of the relay's uid.
5. **Rollout is observe-first with a runtime kill-switch**, because the critics showed that
   several draft controls would have killed live mirrors (C7's mouse clamp, C8's auto-close,
   C11's challenge cap, C20's egress chain without `ct state established`).

## 1. Topology and the trust boundaries

```
browser (guac-rdp.js + guac-proto.js) ──Cockpit channel──▶ relay (uid edy-relay)
   ▲  Guacamole wire protocol over AF_UNIX /run/edy-rdp/guacd.sock       │ re-parse + re-encode
   │  control NDJSON over /run/edy-rdp/control.sock                       ▼
   │                                                          guacd (container, host netns,
   │                                                          127.0.0.1:4822, nft owner-match
   │                                                          admits uid 0 + edy-relay)
   │                                                                      │ VNC (RFB)
   │            console/virtual/greeter/isolated/remote:                  ▼
   │            x11vnc ◀── Xvfb ◀── xfreerdp3 (uid edy-relay) ──RDP──▶ grd :3389/:3390/33000+uid
   │            wayland-vnc: wayvnc 34000+uid (enable_auth=false)         or an operator host
   │            vnc:        guacd ──RFB──▶ operator-chosen IPv4:port (EDY_RDP_REMOTE_ALLOW=any:*)
   └── secrets that cross today: 3389 gate key + 3390 door credential (browser round-trip),
       guacd uuid, error text with paths/uids, clipboard both ways
```

| # | Boundary | Channel | Trust today |
|---|---|---|---|
| B1 | browser → relay (data) | Cockpit `stream` → AF_UNIX, SO_PEERCRED uid, group `cockpit-guac-rdp` 0660 | any `cockpit-guac-rdp` member; the shipped JS is honest, a hand-built client is not |
| B2 | browser → relay (control) | NDJSON, same peer-cred | same; `superuser:'require'` channels arrive as **uid 0** (unmapped identity, §10) |
| B3 | relay → guacd | 127.0.0.1:4822, nft `meta skuid {0, edy-relay}` | relay only — **fail-open** if the firewall unit is down (§10) |
| B4 | guacd → VNC server | RFB to x11vnc/wayvnc (loopback) or an operator host | local servers run as `edy-relay` / the user; remote is untrusted |
| B5 | xfreerdp3 → RDP server | grd on loopback or an operator host, `/sec:rdp:off /cert:tofu` | the **actual reverse-RDP boundary**; the client runs as `edy-relay` in the relay's unit |
| B6 | relay/guacd → browser | everything guacd emits + relay `error` text, verbatim | no output filtering exists (`on_down` is a pure passthrough) |
| B7 | relay → host | polkit grants for `edy-rdp-{headless,waylandvnc,deskui,unlock}@*` any instance | a relay-uid compromise inherits all of it |
| B8 | relay → security consumers | free-text `WARNING` lines at `PRIORITY=6`, nothing structured | no consumer exists |

## 2. Corrections to `docs/CVE.md`

`docs/CVE.md` is updated in the same change. The substantive corrections:

- guacd is a **VNC client** in this architecture, so the "Not applicable while RDP-only" section
  was wrong for CVE-2023-43826 and its class; SSH/telnet are unreachable only because the
  shipped client happens to send `select vnc` — the relay does **not** pin the protocol
  (`classify_select` :172-183, `_guard_upstream` :819-835 accept any string; a second
  `select` is forwarded).
- "Pin guacd ≥ 1.6.0" is satisfied by Janua 1.0.1, which is not recorded anywhere in git
  (fixed by 1.4.0's `.envdefault`); Janua republishes `1.0.1`/`latest` monthly, so the pin is
  orphaned from 2026-10-01 and nothing re-pulls or scans it.
- The relay's `--allow-target` gate (`_enforce_target` :1145-1160, `EDY_RDP_ALLOW_ARGS`) is
  defined and unit-tested but **never invoked on the live connect path** (`on_up` calls only
  `_guard_upstream`). The only thing keeping guacd off arbitrary targets in relay-managed
  scenarios is that the relay overwrites `hostname`/`port`.

## 3. Threat map

Exposure is for **this** deployment with the live `.env` (`EDY_RDP_REMOTE_ALLOW=any:*`,
`EDY_RDP_REMOTE_ADMIN_ONLY=1`). "n/a" = closed by version; the row is kept for its class.

| Id | Class | Boundary | Exposure | Existing mitigation | Gap → control |
|---|---|---|---|---|---|
| CVE-2020-9497/9498 | reverse RDP → guacd RDP plugin | guacd→server, only via unpinned `select rdp` | LOW, n/a | guacd 1.6.0; client sends `select vnc`; relay overwrites target | no protocol pin → **C4** |
| CVE-2023-30575 | handshake length miscalc → instruction injection | B1 | LOW, n/a | guacd 1.6.0; relay re-encodes every instruction | relay's *own* parser unhardened → **C1** |
| CVE-2023-30576 | RDP audio-input UAF | B1 param passthrough | LOW, n/a | client never sets it | **every** browser-supplied param passes through → **C5** |
| CVE-2023-43826 | malicious VNC server → libvncclient overflow | B4 (`vnc` any:*, or inbound via `reverse-connect`) | **MEDIUM** | guacd 1.6.0; vnc admin-only; IPv4 literal | no target deny-list, `reverse-connect` browser-settable, no detectors → **C5, C12, C13, C20** |
| CVE-2024-35164 | terminal escape injection (ssh/telnet) | via unpinned `select` | LOW, n/a | no ssh/telnet scenario | protocol pin → **C4** |
| G1a | next malicious-VNC-server bug; server-shaped output to the browser | B4, B6 | MEDIUM | DOM writes use `textContent` | `on_down` passthrough; `name`/`error`/`clipboard` unsanitised → **C8, C9** |
| G1b | malicious RDP server → **xfreerdp3 on the host** | B5 | **HIGH** | admin-only; IPv4 literal; `/sec:rdp:off`; TOFU | runs as `edy-relay` in the relay unit with all channels → **C21**, and §10 (isolated dials a *user-owned* grd) |
| G2 | hand-built browser client attacks relay/guacd | B1, B2 | **HIGH** | uid binding, tokens, marker strip | unpinned select, param passthrough, no arity/size bounds, trailing-only marker strip, `--allow-target` never called → **C1, C4–C7, C11** |
| G3 | compromised guacd pivots | container→host | **HIGH** | nft ingress owner-match; seccomp/AppArmor default | rootful, host netns, no userns (uid 999 == host `dnsmasq`/`edy-agent`), 11 bounding caps, `NoNewPrivs=0`, rw rootfs, **no egress control** (reaches 8444, 9090, 445, 631, 4713, qemu VNC 5900-5903) → **C20, C16** |
| G4 | host internals leak to the browser | B6 | MEDIUM | uuid truncated in the table | `.env` path, uid + foreign uuid, OSError/systemd text, FreeRDP log tail, `args` fingerprint, `deskui-status` hostname to any member → **C3, C9, C10, C11** |
| G5 | replay / scraping of tokens, ids, storage | browser origin | LOW | uid-bound join + token; no secrets in URLs | raw guacd uuid is a join capability; hash auto-connect → **C10, C14, C19** |
| G6 | `any:*` = operator-directed SSRF / lateral movement | admin→relay→guacd/xfreerdp3→any IPv4 | **HIGH** | admin gate (or sudo-group fallback, no token) | loopback + link-local + **`0.0.0.0`** accepted; qemu consoles have no password → **C12** |

## 4. Defects present today (Phase 0 — these are not design questions)

Each is verified in code at `8fc87cc` or on edt1. Fix these before, or as the first step of,
the layered plan; the control that formalises each is named.

| # | Defect | Where | Impact | → |
|---|---|---|---|---|
| D-1 | **Connect-parameter passthrough.** `_inject_vnc_target` rewrites only `hostname`/`port`/`password`; every other value the browser supplies is copied verbatim. Live guacd `args` (journal 2026-09-25) advertise `reverse-connect`+`listen-timeout` (guacd **listens** on all interfaces in the host netns for an inbound "server" — an inbound path into libvncclient), `audio-servername` (libpulse dials an arbitrary host from the host netns — SSRF), `wol-send-packet`/`wol-*` (arbitrary UDP; `wol-wait-time` is a free sleep), `recording-path`/`create-recording-path` (browser-named file writes inside the container), `dest-host`/`dest-port`, `enable-audio-input`, `autoretry`, `disable-server-input`, `username` | relay :1131-1143 | any `cockpit-guac-rdp` member, any scenario, no admin needed | C5 |
| D-2 | **No protocol pin; second `select` unguarded.** | relay :172-183, :819-835 | any member can make guacd load whatever plugin the image bundles | C4 |
| D-3 | **`--allow-target` gate never invoked** on the live path. | relay :1145-1160 vs `on_up` :1235 | the documented SSRF control is inert | C5 (target assertion) |
| D-4 | **`any:*` accepts loopback, link-local and `0.0.0.0`** (`_parse_remote_target` :1105-1129; `connect()` to 0.0.0.0 reaches loopback). Reachable with no password: the four qemu VNC consoles on 127.0.0.1:5900-5903 (`w11peer`, `w11client`, `ws2025-mem1`, `ws2025-mem2`), plus 4713, 4822-adjacent, 8444, 9090. The admin gate falls back to sudo-group membership without a token (:904-907). | relay :310-332, :897-913 | operator-directed SSRF; VM console takeover by any Cockpit admin | C12 |
| D-5 | **Gate/door credentials round-trip through the browser.** The 3389 key via `cockpit.spawn(grdctl status --show-credentials)` and the 3390 door credential by a `superuser:'require'` read of the **whole** `credentials.ini`, then back over the data channel as `rdpcred=`. The isolated scenario already proves the server-side pattern (`ensure_headless_session` → `relay_cred`, :1069-1078). | guac-rdp.js :598-618, :770-773 | a host secret lives in every admin's JS heap and crosses the channel | C17 |
| D-6 | **Group-readable secrets.** Bridge `<key>.env` (VNCPASS+port) is `chgrp cockpit-guac-rdp; chmod 0640` (bridge script :185-187); headless `<uid>.env` (PORT/USER/CRED/DESKTOP_ID) is `root:cockpit-guac-rdp 0640` (:97-114); `*.krblog` (KDC names/IPs) are 0644 and never removed (25 accumulated). On edt1, this group's members were `cptest, eddie, cpadmin` when it was still named `edy-rdp`; the rename's `groupmod` migration (`deploy.sh --with-users`, see CHANGELOG) preserves the same GID and membership under the new name — this describes the group's role, not a verified post-migration state. wayvnc runs `enable_auth=false` on `34000+uid` with no owner-match on that range. | bridge, headless, waylandvnc scripts; `edy-rdp-tmpfiles.conf` | every RDP user can read every other user's live VNC password and headless RDP credential, then attach a stock client to their desktop — defeats I29's own-desktop isolation | C18 |
| D-7 | **Error text leaks host internals.** `_env_file_hint()` ships the live `.env` path (:32-48 → :935-937, :1094-1096); "uid %d may not join session %s" (:828) confirms a guessed uuid; OSError/systemd stderr/paths under `/run/edy-rdp` (:392-397, :535-545, :574-577, :586, :613-616, :626); the `xfreerdp3` log tail — up to 280 chars produced while talking to a possibly hostile server — via `Refuse("could not start desktop bridge: %s")` (bridge :183-192 → :1024); status `769` reused for backend-unavailable. | relay, bridge.py | reconnaissance for free; a hostile RDP server gets a channel into the operator's status line, whose regexes drive UX (the locked-seat regex adds an *Unlock* button that issues control `unlock`) | C3, C13 |
| D-8 | **Client sinks.** Three `innerHTML` concatenations of relay-supplied text (guac-rdp.js :1123-1125, :1159, :1222 — `e` can be a `JSON.parse` SyntaxError embedding relay bytes); a blind `superuser:'require'` read of a relay-named `challenge_path` (:711); `lastRemoteClip` unbounded and never cleared (:91, :865); local clipboard pushed on **every focus** while the toggle is ON — default ON — including to an operator-chosen remote host (:963-982, index.html:85). | guac-rdp.js | HTML/UI spoofing in the admin's Cockpit iframe; relay→root file-read primitive; paste-jacking; clipboard exfiltration to untrusted hosts | C19 |
| D-9 | **Container and firewall posture.** Rootful podman, `--network host`, no `--userns` (in-container uid 999 **is** host `dnsmasq`, and `edy-agent` also runs as 999), `CapBnd` keeps 11 caps incl. SETUID/SETGID/DAC_OVERRIDE/SYS_CHROOT, `NoNewPrivs=0` with Debian setuid binaries, rw overlay, no pids/memory limits, **no egress control**. `hardening/edy-rdp-firewall.nft` is not installed and references a stale bridge; grd binds `*:3389/*:3390` LAN-reachable (I7 open). No unit `Requires=` the firewall unit. | `edy-rdp-guacd.service.in`, hardening/ | a guacd RCE reaches every loopback service and LAN/WAN; nft is fail-open | C20, §10 |
| D-10 | **Anonymous PulseAudio TCP on 127.0.0.1:4713** (`auth-anonymous=true`, `~/.config/pipewire/pipewire-pulse.conf.d/20-edy-tcp.conf`) is live although CHANGELOG 1.2.9 says the TCP approach was removed. | host (eddie) | any local uid controls the seat's audio server | KNOWN_ISSUES I44 (host cleanup) |
| D-11 | **Marker strip is trailing-only** (`_peek_scenario_from_connect` :859-870): a `scenario=`/`rdpcred=`/`sessiontoken=`/`remotehost=` element placed mid-vector by a hand-built client is zipped positionally into a guacd parameter. | relay | marker confusion; credential material into a guacd arg | C5 |
| D-12 | **No structured security signal.** Every relay journal line lands at `PRIORITY=6` (stderr stream transport, no `SyslogIdentifier=`/level prefix); refusals are free text `WARNING … REFUSED uid=…`; nothing consumes them. | relay :1285, unit | the SOC is blind by construction | C2 |
| D-13 | **Supply chain.** Janua digest recorded nowhere in git; `policy.json` is `insecureAcceptAnything`; no re-pull, scan or advisory watch; `guacamole-common-js/all.min.js` is owned `eddie:eddie` unlike the rest of the served tree; no SRI; the self-test only checks HTTP 200. | repo, host | the "closed by version" argument has no owner; a one-hop path into every admin's Cockpit origin | §10 |

## 5. Secrets and identifiers that must not leave the host

The register the sanitising layer is built from. "Needed" = does the receiver need it to do
its job. Items 1–4 are the ones the user's third ask is about.

| # | Item | Crosses | Needed | Handling |
|---|---|---|---|---|
| 1 | 3389 gate key + 3390 door credential | grd store → **browser** → relay → bridge | no | C17: materialised by root, read once by the relay, never in the browser |
| 2 | guacd connection uuid (`ready $uuid`, `list` rows) | guacd → relay → browser | no (client never rejoins; uses it only for `terminate`) | C10: relay-minted opaque handle |
| 3 | `.env` path, denied host:port, caller uid + foreign uuid, OSError/systemd text, `/run/edy-rdp` paths, FreeRDP log tail | relay → browser (`error` text) | no | C3: stable reason code + ref; internals to the journal only |
| 4 | guacd protocol version + full plugin parameter list (`args`) | guacd → browser | only the client-settable names | C9: synthetic advertised list |
| 5 | VNC desktop `name` (x11vnc/wayvnc, or an attacker's string) | server → browser | no (`onname` unassigned) | C9: fixed label per scenario |
| 6 | guacd `error` text | guacd → browser status line, regex-classified | a category, not the text | C9/C3: numeric status → code |
| 7 | `list` fields `desktop_id` (`remote:<ip>:<port>:<uid>`), `desktop_created`, full uuid | control → browser | UI shows 8 chars, scenario, state, live, age | C11: minimised per caller |
| 8 | `deskui-status` hostname, DM unit, default target, session count | control → **any** member | only admins with write enabled | C11 |
| 9 | bridge VNCPASS + port; headless CRED/PORT/USER; wayvnc endpoint | files → every `cockpit-guac-rdp` member | relay only | C18 |
| 10 | seat audio (uid 1000 sink monitor) | container → any session that sets `enable-audio` | seat-mirroring scenarios only | C5: coerced off elsewhere |
| 11 | operator's local clipboard on every focus | browser → session, incl. remote hosts | explicit sends only | C19 + C5 defaults for remote/vnc |
| 12 | session-side clipboard retained after disconnect | guacd → `lastRemoteClip` → OS clipboard | no | C19 |
| 13 | `*.krblog` (realm, KDC hosts/IPs) | bridge → group-readable dir, never removed | no | C18 |
| 14 | relay markers (`scenario=` …) | browser → relay | never to guacd | C5: strip anywhere, refuse duplicates |
| 15 | a hub ingest API key (if tier 1 is used) | root file → relay memory → loopback | relay only; **never** the container or bridge children | C22 |

## 6. The three layers (controls, post-critique)

Each control: what it does as repaired, where it hooks, what it addresses, mirror risk, and
the critic's material change. "Mirror" means the 60 fps console/virtual path with
keyboard (`-nomodtweak` 3-key combos), clipboard Send/Receive, audio, reconnect/resume of
isolated+virtual desktops, pop-out and virtual-monitor windows, the Self Tests tab, the greeter
handover and the reaper.

### 6.1 Prevent — codec and protocol firewall

**C1 · Wire-codec hardening (relay's own parser, both directions).** Length token must be
1–5 chars, `isascii() and isdigit()` (bare `isdigit()`/`int()` accept `+5`, ` 5`, `1_0`,
Unicode digits); bound the separator search to `buf.find('.', i, i+6)` so a digit flood cannot
make `find` scan the buffer; `MAX_INSTR` = whole-instruction wire length in codepoints with
guacd's own `GUAC_INSTRUCTION_MAX_LENGTH` semantics; max elements 64 up / 96 down; per-direction
incremental UTF-8 decoder (`codecs.getincrementaldecoder`) replacing the per-chunk
`decode('utf-8','replace')` that desyncs codepoint lengths on a split multibyte character and
wedges the session while keepalives keep guacd alive; `parse_one` returns a `MALFORMED`
sentinel distinct from *need more*. Upstream violation → `Refuse PROTO_MALFORMED/PROTO_OVERRUN`
(768/781) + event; downstream → close + `proto.guacd_suspect`. *Where:* `parse_one` :125-152,
`drain` :155-164, recv loop :1257-1272, `Connection.__init__`. *Addresses:* CVE-2023-30575
class, G2. *Mirror risk:* LOW (caps are at/above guacd's; `guacamole-common-js` chunks blobs at
6048 bytes). *Critic's change:* the draft's 64 KiB **pre-drain** buffer cap false-tripped the
mirror (a legitimate residual tail is one incomplete max instruction); the cap is applied after
`drain`, and the grammar is `isascii+isdigit`, not `isdecimal`.

**C4 · Upstream handshake state machine + protocol pin.** `Connection.phase ∈ {SELECT,
AWAIT_ARGS, NEGOTIATE, CONNECTED_WAIT_READY, SESSION}`. SELECT admits exactly `['select','vnc']`
(exact compare) or the existing join branch `select $<id>` gated by `may_join(id, uid)` as today
(the id becomes a handle with C10); any other protocol → `Refuse E_MALFORMED_SELECT` + critical
`proto.select_pinned{protocol[:16]}` — closing the loadable-plugin path for every RDP/SSH/telnet
class regardless of what the image bundles. Any `select` after the first → Refuse (tripwire).
AWAIT_ARGS: any client instruction before guacd's `args` → Refuse. NEGOTIATE: only `size`,
`audio`, `video`, `image`, `timezone`, `connect`; `video` must be empty, `audio` limited to
L8/L16 forms, `image` ⊆ {png, jpeg, webp}. CONNECTED_WAIT_READY: only `sync`/`nop`; the 30 s
deadline is anchored on the **forwarded** rewritten `connect` (`monotonic()` set in `on_up`),
not on receipt. *Where:* `_guard_upstream` :812-841 (replacing :819-835), `classify_select`
:172-183, `_watch_downstream` :1163-1185. *Addresses:* CVE-2020-9497/9498, CVE-2023-30576,
CVE-2024-35164, G2, G1a. *Mirror risk:* LOW — the shipped client sends `select vnc` once per
channel (guac-rdp.js :586); every reconnect, pop-out, virtual monitor and greeter handover is a
fresh channel. Effectively zero false positives. This is what lets `docs/CVE.md` say
"unreachable: the relay pins `select vnc`" honestly.

**C5 · Upstream connect authoring (allowlist, marker discipline, audio/clipboard policy,
target assertion).** Replace the positional passthrough with `_build_guacd_connect(target,
browser_opts)`: start from `{n: '' for n in real_arg_names}`; set `hostname`/`port`/`password`
from the relay-resolved target; `username` forced `''`. `CLIENT_SETTABLE`, by name, with
validators: `enable-audio` (`'true'|''`, and coerced to `''` — not refused — for any scenario
outside `LOCAL_SEAT_SCENARIOS`, with an info trace: the seat's audio is not another user's to
hear), `color-depth ∈ {8,16,24,32}`, `cursor ∈ {local,remote}`, `swap-red-blue`,
`clipboard-encoding`, `force-lossless`, `compress-level`/`quality-level` 0–9, `read-only`,
`encodings` `[a-z0-9 ]{≤64}`, `disable-copy`/`disable-paste` (relay **defaults both to
`'true'` for `remote`/`vnc`** unless the client explicitly sends `'false'`). The `VERSION_*`
slot is accepted only if it equals the advertised token and matches `^VERSION_\d+_\d+_\d+$`,
forwarded unchanged. `forced = set(real_arg_names) − CLIENT_SETTABLE − {hostname, port,
password, username, VERSION}` is computed **per connection**; a non-empty browser value for a
forced name (`reverse-connect`, `listen-timeout`, `audio-servername`, `dest-host/port`,
`autoretry`, `disable-server-input`, `recording-*`, `create-recording-path`, `wol-*`,
`enable-audio-input`, `sftp-*`) → Refuse + critical `proto.forced_param{name,value_sha12}` —
the shipped client sets only `enable-audio` (guac-rdp.js :77-87), so this tripwire has zero
false positives for it. Markers are stripped **anywhere** in the vector; a duplicate marker →
Refuse. Finally `_enforce_target` is actually **called** on the authored connect (D-3).
*Where:* `_inject_vnc_target` :1131-1143 (replaced), `_peek_scenario_from_connect` :843-870,
`_enforce_target` :1145-1160 from `on_up`. *Addresses:* CVE-2023-30576 class, CVE-2023-43826
(inbound listener), G2, G3, G1a, G6. *Mirror risk:* LOW — no parameter on the keyboard/mouse/
reconnect/pop-out path; Sound on console/virtual is regression-tested. *Critic's change:* the
draft dropped the `VERSION` echo (which would have broken the handshake), refused rather than
coerced `enable-audio`, and computed the forced set statically.

**C6 · Size, geometry and connection bounds.** `size` elements must match `^[0-9]{1,5}$`
(3 or 4 elements) else `Refuse PROTO_SIZE`; in-shape but out-of-range values are **clamped**
into 200..7680 × 200..4320, dpi 48..300 — one `proto.size_clamped` warning, never a Refuse,
so an 8K or odd native mode degrades instead of failing; the clamped values feed
`req_w/req_h` → `Xvfb -screen` and `xfreerdp /size` (today `int()` at :838 feeds `%dx%d` into
the `.req` with no check at all) and the re-encoded `size` to guacd; `virtual` is tightened to
≤ 5120×2880 (the seat mutter allocation); ≤ 2 `size`/s in SESSION. Per-uid **data**
connections ≤ 10 across all scenarios (`MAX_BRIDGES_PER_UID=6` covers bridged ones only),
acquired **before** `_connect_guacd` so an idle pre-select connection counts, released in
`finally`. Upstream bytes 512 KiB/s sustained / 2 MiB burst and ≤ 4 open upstream streams are
the only rate limits until an observe-mode p99×4 calibration justifies per-instruction buckets.
*Where:* `_guard_upstream` :836-840, `_peek_scenario_from_connect` ~:994 →
`bridge.start_bridge(geom=…)`, `handle()` :1204-1215/:1289. *Addresses:* G2. *Mirror risk:*
LOW (seat + 4 monitor pop-outs + main = 6 < 10). *Critic's change:* refuse-vs-clamp
contradiction resolved in favour of clamp.

**C7 · Upstream SESSION opcode/arity allowlist + stream table.** Applies **only** after
guacd's `ready` (phase SESSION); NEGOTIATE stays with C4/C5. Frozen tables on the hot path
(dict lookup + `len` compare): `sync 2`, `nop 1`, `mouse 4`, `key 3`, `clipboard 3` (mimetype
exactly `text/plain`), `blob 3` (stream known-open, ≤ 8192, content unscanned), `end 2`,
`ack 4`, `size 3-4`, `disconnect 1`, `touch 8`. Two-tier response: **DENIED** opcodes in
SESSION `{put, get, file, pipe, argv, audio, select, connect, size-with-dpi}` → `Refuse
PROTO_OPCODE_DENIED` + critical event; **UNKNOWN** opcode → drop + one warning per (conn, op)
(guacd ignores unknown opcodes; this protects against library upgrades, not attackers);
**out-of-spec values of an allowed opcode are clamped or dropped, never refused** — the
critic showed that the draft's `mouse` floor of −1 would have killed every session on a
drag-out (`Guacamole.Position.fromClientPosition` has no clamp), that a > 256 KiB paste is
routine, and that a leaked stream index past 63 happens in long sessions with a flaky clipboard.
Upstream streams: ≤ 4 concurrent, 256 KiB per clipboard stream (matching guacd's own
`GUAC_VNC_CLIPBOARD_MAX_LENGTH`; over-cap → send `end`, swallow the rest). The C0-charset
check runs on SESSION elements only and never on `connect` (the `rdpcred` marker legitimately
contains `\x1f`). *Where:* `_guard_upstream` with module-level `UP_POLICY_SESSION`; `ops_up`
counters :816 supply observe-mode telemetry. *Addresses:* G2 (bounded hygiene; with C4's pin,
libguac's VNC client is the only consumer of these opcodes anyway). *Mirror risk:* MEDIUM
until an observe-mode soak confirms the table, LOW after; tables are re-validated on every
`guacamole-common-js` upgrade (write into `COMPATIBILITY.md`).

**C12 · Remote-target policy (SSRF / lateral-movement fence) + decoy targets.** Replace
`any:*` with explicit CIDRs in `EDY_RDP_REMOTE_ALLOW`. Independently of the allow-list, an
**address-based** deny applied to every port: `EDY_RDP_REMOTE_DENY` default
`self,0.0.0.0/8,127.0.0.0/8,169.254.0.0/16,224.0.0.0/3`, where `self` is any address local to
the host, determined per connect without subprocesses by a bind probe (`socket(AF_INET,
SOCK_DGRAM).bind((host, 0))` succeeds only for a configured local address; AF_INET is already
permitted) or by parsing `/proc/net/fib_trie` LOCAL entries — addresses change (macvlan,
wg-lan, podman). Port exclusions apply only to host-local addresses (the critic showed a global
port deny kills the remote scenario's default 3389 and vnc's 5900 for every legitimate LAN
target). Require the **proven session token** for `remote`/`vnc` (drop the sudo-group fallback
:904-907 for these two scenarios). Emit every remote target with uid; per-uid distinct-target
counter per hour, threshold 5 → `proto.target_scan`. **Decoy targets:** 1–2 operator-reserved,
never-assigned RFC1918 `ip:port` in `EDY_RDP_DECOY_TARGETS` (live `.env` only), checked
**before** the allow-list in both the `vnc` and `remote` branches; a hit never dials, refuses
with the same `E_TARGET_DENIED` text as a real miss, and emits critical
`decoy.remote_target{uid, scenario, target, admin_proven}`; matching on the decoy IP for any
port catches scanning. The page is not told the decoy value (the critic: every member's browser
holding it is a leak and a false-positive source — a curious admin reading localStorage). The
decoy therefore catches a scanner or a scraped target list, not a client that reads the page.
*Where:* `remote_target_allowed` :310-332, `parse_remote_allow` :272-307, vnc branch :932-951,
admin gate :897-913, `_grd_target` :1079-1102, `main()` argparse. *Addresses:* G6,
CVE-2023-43826, G1a, G1b, G5. *Mirror risk:* NONE for console/virtual/greeter/isolated/
wayland-vnc (branches untouched).

### 6.2 Minimise — need-to-know outputs

**C3 · Reason codes; internals to the journal only.** `Refuse(code, ref=None)` with a
`relay/reasons.py` table `CODE → (guac status, operator-safe sentence)`;
`_send_error_and_close` emits `error "<CODE>: <sentence> (ref r-xxxxxx)" <status>`; raw detail
(uid, uuid prefix, denied host:port, OSError text, unit names, systemd stderr, `/run/edy-rdp`
paths, the `xfreerdp3` log tail, `_env_file_hint()`) goes only to `log.warning` + the event,
keyed by ref. Distinct statuses replace 769-for-everything: 769 `E_ADMIN_REQUIRED`/
`E_JOIN_DENIED`/`E_TOKEN_INVALID`/`E_TARGET_DENIED`; 768 `E_BAD_CLIENT`/`E_MALFORMED_SELECT`/
`PROTO_*`; 512 `E_BRIDGE_FAILED`/`E_SESSION_START`; 521 backend-unavailable/
`E_TARGET_UNREACHABLE`; 519 `E_AUTH_REJECTED`; 776 too many; 781 overrun. `bridge.BridgeError`
gains `.verdict ∈ {auth, seat_locked, cert_changed, unreachable, unknown}` (extend
`AUTH_ERR_RE` with a TOFU-mismatch and a refused/timeout regex); `_rdplog_tail` is trace-logged,
never returned. The same `{ok:false, code, error, ref}` shape applies to `control.py` replies.
Helpers publish **codes**, not prose: `edy-rdp-headless-start.sh` writes `CODE=E_SEAT_IN_USE` to
`<uid>.err` and the relay maps it to the existing actionable sentence (the critic caught that
the draft would have lost "the Isolated desktop cannot run alongside a local login…"). The
client's `explain()` matches the CODE prefix case-sensitively. *Where:* `Refuse` :1188,
`_send_error_and_close` :1192-1201, every Refuse site, `bridge.py` :30-37/:141-150/:183-192,
`control.py` :119-120/:138/:180-181. *Addresses:* G4, G1b, G5, G6. *Mirror risk:* LOW —
failure-path wording only; the Unlock button and auth hints keep their triggers by construction.

**C9 · Downstream output scrubber for server-shaped opcodes (`DOWN_SLOW`).** `args`: keep
the real list in `self.real_arg_names`; send the browser a **synthetic** advertised list =
`[guacd's VERSION token] + (CLIENT_SETTABLE ∩ real_arg_names) + [hostname, port, password
placeholders]` + 2–3 **decoy names** an attacker wants and this build does not advertise
(`enable-sftp`, `sftp-hostname`, `sftp-password`, `enable-audio-input` — verified absent from
the live Janua list; deduped against the real list; pool rotated per relay start). The client
fills unknown names with `''` (guac-rdp.js :544), so any non-empty decoy position → critical
`decoy.connect_param{name, value_sha12}` + Refuse; the relay zips the browser's positional
`connect` against the synthetic list, then authors the real one (C5) — the fork/plugin
fingerprint never leaves the relay. `ready`: C10 handle. `name`: fixed label per scenario
(`Mirror`, `Isolated desktop`, `Remote desktop`); original trace-logged, 64 chars, C0-stripped.
`error`: numeric status → code + short text; raw text to the journal, event when it follows a
remote connect. `clipboard`: **size caps drop, rate limits only detect** — measured on decoded
bytes, mirror = 262144 (mirrors guacd, zero behaviour change), remote/vnc = 65536 (policy);
scrub **per blob** (decode base64 → strip C0 except `\t\n\r` and ESC → re-encode) with no
cross-blob buffering; on over-cap send `end` once, swallow the rest of that stream. `audio`
forwarded only if `enable-audio` was actually authored for the connection. *Where:*
`_watch_downstream` :1163-1185 → `scrub(elements) -> elements | None`, `on_down` :1241-1254.
*Addresses:* G1a, G4, G5, CVE-2023-43826 class, G1b, G2. *Mirror risk:* LOW-MEDIUM — ship the
allowlist half with the real list still advertised, then switch to synthetic (observe mode
computes both). A prepared attacker who never fills a decoy position is neither caught nor
harmed; the decoy is for the impatient.

**C10 · Session-identifier aliasing (the guacd uuid never leaves the relay).** New
`relay/handles.py` `HandleTable` (`'h1_' + token_urlsafe(24)` → `{uuid, uid, token, created}`,
reverse map). Mint on `ready` after `table.open`, forward `ready $<handle>` (keep `$` so
`Guacamole.Tunnel.setUUID` and guac-rdp.js :921 work). `select $<handle>` resolves to the real
uuid only if owner uid == SO_PEERCRED uid; control `list` returns the handle under the existing
`uuid` key (UI slices 8 chars — zero client change); `terminate` resolves handle→uuid first and
returns `already_gone` for unknown handles **without** calling `live.terminate()` (fixes the
owner-None-but-live path, control.py :207-215). A handle lives exactly as long as its registry
row — the critic removed the draft's 24 h hard TTL, which would have orphaned a live > 24 h
session's Terminate button; `HandleTable.for_uuid()` mints lazily so rows loaded from
`sessions.json` after a restart get handles too. Registry stays keyed by guacd uuid
(`sessions.json` 0600). Honest scope: this closes browser-side and admin-list exposure (G5, G4);
the relay-uid path (`sessions.json` + 4822) is closed by C21, not C10. *Where:* new
`handles.py`; `_watch_downstream` :1177-1185, `on_down`, `_guard_upstream` :825-830, `handle()`
finally; `control.py` list/terminate/prune. *Mirror risk:* LOW.

**C11 · Control-API hardening, field minimisation, op tripwires.** Per-caller op allowlist:
browser peers `{register, elevate, terminate, unlock, deskui-status, deskui, list, canary}`;
`ping`/`prune` only from the reaper (uid 0 — attributed by cgroup, §10); unknown op, `ping` from
a peer, `prune` from uid ≠ 0, wrong challenge, malformed JSON → reply identical to today's
failure + `control.op_denied`. **Challenge files only on request**: `register` accepts
`{"prove": true}` (the client sends `prove: needAdmin`); `tokens.issue(uid, now,
want_challenge)` never writes a root-only file for a uid outside the admin group; outstanding
unconsumed challenges capped at 3 per uid by **FIFO eviction, not refusal** — the critic showed
the draft's hard cap of 3 broke reconnect/resume, pop-outs, virtual monitors and the live
Sound/Resolution toggles, all of which `register`. `SessionTokens.sweep()` (:745, never called
today) runs from a 60 s daemon timer. `list` for non-admins: `{uuid:<handle>, scenario, state,
live, mine, created, last_seen}`; `uid` and `desktop_id` for admins only. `deskui-status` for
non-admins: `{enabled: false}` only. Optional server-side decoy ops (`export`, `session-key`,
`credentials`, `rejoin`) return a plausible non-fatal reply + critical `decoy.control_op` — with
the honest note that `control.py` is world-readable, so this catches **blind probing only**.
*Where:* `control.py` :57-243, `control_server` :1360-1402, `SessionTokens` :691-745,
guac-rdp.js `registerSession` :707-720. *Mirror risk:* LOW.

**C17 · Server-side grd gate/door credential (the top secret item).** Goal: the 3389 gate
key and the 3390 door credential never enter the browser. The critic refuted the draft — a
relay-started root helper would have **granted the relay uid a pull path** to the door
credential that today only root can read, i.e. handed a new capability to exactly the G1b
compromise the control claims to address. Repaired design keeps root as the only principal that
materialises it: for the 3390 **door**, the instance is started from the admin's
**already-elevated Cockpit session** — after `registerSession()` proves elevation the client runs
`cockpit.spawn(['systemctl','start','edy-rdp-gatecred@door-<challenge_id>'], {superuser:
'require'})` (the same elevation it uses today to read the challenge at :711); the helper
`gatecred/edy-rdp-gatecred-start.sh` validates the instance against
`^door-[A-Za-z0-9_-]{8,32}$`, checks `/run/edy-rdp/reg/<challenge_id>` exists and is fresh, reads
the store as root, writes `/run/edy-rdp/gatecred/door-<id>.env` (`USER=`, `PASS=`) owner
`edy-relay` 0600 in a new tmpfiles dir `d /run/edy-rdp/gatecred 0700 edy-relay edy-rdp`; the
relay reads once and unlinks (as `bridge.py` does with `.req` :155). For the per-user **3389**
key: instance `3389-<uid>` runs `runuser -u <caller> -- env DBUS_SESSION_BUS_ADDRESS=… grdctl
status --show-credentials` — the caller's own keyring, exactly what the browser does today,
without the browser; the polkit line permits `edy-rdp-gatecred@3389-<uid>` only for the
caller's own uid. Relay: `ensure_gate_credential(port, uid)` beside `ensure_headless_session`;
`_grd_target` returns `relay_cred` for console/virtual/greeter; the relay **prefers a present
`rdpcred`** during rollout so an old client keeps working, and the `greeter` scenario joins
`ADMIN_ONLY_SCENARIOS`. Concurrency: systemd coalesces a second `start` into the running
oneshot; the relay waits on the unit, not the file. *Where:* new `gatecred/` + unit + tmpfiles +
polkit line + `install.sh` manifest; relay :223, :1043-1068, :953-965; guac-rdp.js
`fetchGateKey` :598-618 (deleted), :766-773, :832-833. *Addresses:* G4, G5, G2 (and G1b only in
the sense that the browser stops holding the secret). *Mirror risk:* MEDIUM — the highest in
the plan; it changes how console/virtual authenticate. Ship relay + helper first while the
client still sends `rdpcred`, verify with a hand-built connect, then delete the client path.

**C18 · Host files — keep "the relay is the only reader" true end to end.**
`bridge/edy-rdp-bridge-start.sh`: `umask 077` after `set -uo pipefail` (covers `.env`,
`.rdplog`, `.krblog`, `.krb5.conf`); delete the `chgrp`+`chmod 0640` at :187 and the `chgrp` at
:146 (`mktemp` is already 0600; the relay is the file owner and sole reader, `bridge.py` :151);
`Xvfb … -nolisten tcp -nolisten local` (kills the abstract socket; x11vnc/xfreerdp3 keep the
filesystem socket inside the unit's `PrivateTmp`). `headless/edy-rdp-headless-start.sh`:
`install -o edy-relay -m 0600` for `<uid>.env/.desktop/.err`. `bridge.py stop_bridge` and the
script's cleanup trap unlink `*.krblog`. wayvnc: a per-connection password like the bridge, or
an nft `skuid` match on `34000-34999`. *Addresses:* G5(f), G2 — retargeted by the critic from
G1b/G3, which file modes cannot address. *Mirror risk:* LOW; a mistake fails isolated loudly
(`E_SESSION_STATE`), not the mirror.

**C19 · Client hygiene.** (a) The three `innerHTML` sinks → `textContent`, wrapping `e` as
`String(e).slice(0,200)` (rationale: HTML/UI spoofing in the admin's iframe — the Cockpit CSP
already blocks script from `innerHTML`, I11). (b) Challenge read: id regex
`^[A-Za-z0-9_-]{8,32}$` + constant prefix `/run/edy-rdp/reg/` **and** content validation — the
relay writes `edy-rdp-challenge:<token_urlsafe(24)>`, the client requires
`^edy-rdp-challenge:[A-Za-z0-9_-]{32}$` on the trimmed first line and echoes only the token
(the critic: `/run/edy-rdp/reg` is writable by the relay uid, so a symlink to `/etc/shadow`
passes an id-only check and `cockpit.file` reads it as root; content validation makes a foreign
file leak nothing, not even a 32-char bare key). (c) Clear `lastRemoteClip` in teardown. (d) For
`vnc`/`remote`: Clipboard default **OFF**, no focus-triggered `clipReadHandler`; because C5
defaults `disable-copy/paste` to `'true'` for those scenarios and guacd fixes them at connect,
the explicit Send/Receive buttons **also** send the params — the draft's "buttons remain"
promise was false without that. (e) `explain()`/`offerUnlock` match the C3 CODE prefix. (f) Do
**not** brand every `(ref …)` refusal as "security event recorded" — after C3 every mistyped
password carries a ref. *Where:* guac-rdp.js :1123-1125, :1159, :1222, :707-720, :679-687,
:959-982, :860-877, :882-914, :500-524; index.html :85. *Mirror risk:* LOW-MEDIUM only for
clipboard on remote/vnc (explicit there by design).

### 6.3 Detect — deception, detectors, events

**C2 · Tier-0 security-event emitter (credential-free).** New stdlib-only
`relay/secevent.py`: `SecEvent(kind, severity, uid, user, conn, scenario, phase, op, target,
handle8, decoy_id, value_sha12, ref, detail)`; `emit()` = one non-blocking `sendto` on a
pre-bound `AF_UNIX SOCK_DGRAM` to `/run/systemd/journal/socket` — **every field in journald's
binary form** (`NAME\n` + le64 length + bytes + `\n`, `struct.pack('<Q', …)`) so no value can
inject fields; C0-strip/200-char cap applied to **all** browser- and server-influenced text for
readability. `PRIORITY` 2 critical / 4 warning / 6 info, `SYSLOG_IDENTIFIER=edy-rdp-relay`, a
fixed `MESSAGE_ID` per class (`proto`, `decoy`, `refuse`, `backend`, `control`), fields
`EDY_RDP_EVENT/UID/USER/PID/CONN/SCENARIO/PHASE/OP/TARGET (ipv4:port, remote/vnc only)/HANDLE
(8 chars, never the uuid)/DECOY_ID/VALUE_SHA (12 hex, never the value)/ISSUED_UID/AGE_S/PEER/
REF/VERSION`. Flood control: first occurrence per (conn, kind) immediate, repeats summarised
at teardown; per-uid budget 60/min then one `suppressed N`. **Trust contract, stated plainly:**
`/run/systemd/journal/socket` is world-writable, so any local uid can send
`SYSLOG_IDENTIFIER=edy-rdp-relay` + a decoy `MESSAGE_ID`; the sender-chosen fields are
**forgeable**. Consumers MUST match `_SYSTEMD_UNIT=edy-rdp-relay.service _UID=<edy-relay uid>
_COMM=python3` in addition to `MESSAGE_ID` — the kernel-stamped fields are the provenance. The
`refuse` class is split: benign operator outcomes (wrong gate password, seat locked, expired
token) at info; policy violations at warning. The unit gains `SyslogIdentifier=` and
`SyslogLevelPrefix=` so ordinary `WARNING` lines stop landing at priority 6. *Where:* new
`secevent.py`; `handle()` :1284-1286; `control.py` unknown-op :243; `edy-rdp-relay.service.in`.
*Mirror risk:* NONE (µs-scale, never on the data thread).

**C8 · Downstream opcode shape (guacd → browser) — event-only.** `DOWN_FAST = {img, blob,
end, sync, copy, rect, cfill, dispose, cursor, move, shade, transfer, size, nop, ack, mouse,
set}`: one `frozenset` lookup + `1 ≤ len ≤ 16`, then forward as today; `DOWN_SLOW = {args,
ready, name, error, disconnect, clipboard, audio}` → C9. Anything else (`file`, `filesystem`,
`pipe`, `nest`, `msg`, `required`, `argv`, `body`, `undefine`, `video`, `log`, `key`,
`select`, `connect`, a second `args`/`ready`) is **dropped + event**
(`proto.down_unexpected{op,count}`); `msg`/`required`/`argv` sit in a `KNOWN_DROPPED` set at
info. The draft's "3 drops in 10 s → close both sockets" **is removed**: the critic showed it is
a session-kill footgun (stream-suppressed `blob`/`end` of a dropped stream would have counted),
and that as *prevention* it is trivially bypassed by a post-RCE guacd that simply stays inside
`DOWN_FAST` with a crafted image. Its honest value is telemetry that feeds C13 and the
supply-chain watch. `audio` forwarded only if authored. Per-connection `perf_counter_ns`
accumulator in the teardown trace; acceptance: median added cost < 1 µs/instruction. *Where:*
`on_down` :1241-1254 (classify before `sendall`), `_watch_downstream`. *Mirror risk:* MEDIUM
if enforced blind (a missing FAST op drops frames — visible at once), LOW after an observe-mode
capture of every downstream op per scenario (verify `transfer`/`set` empirically).

**C13 · Backend-behaviour detectors (what the relay CAN see).** Honest scope: **crash/abort
telemetry, not exploit detection** — a successful libvncclient exploit keeps guacd alive and
fires nothing; and 8 of the 8 guacd `error` instructions in 60 days of journal were the routine
`Aborted. See logs. 515` teardown of the shipped UI, so the draft's 5 s window had a high
false-positive rate. Repaired: record which socket EOF'd; set `conn.terminated=True` inside
`terminate()` before the `SHUT_RDWR`; gate every detector on `not conn.closed and not
conn.terminated`; replace the 5 s window with **phase tracking** (`t_connect_fwd`, `ready_seen`,
`first_frame_seen` = first downstream `size 0`/`img`/`rect` on layer 0,
`client_disconnect_seen`, `last_down_op`). Emit `proto.guacd_abort_remote{target, phase}` only
for scenario ∈ {vnc, remote} when guacd EOFs or errors **before `first_frame_seen` and without
a client disconnect**; `proto.guacd_died_handshake` for EOF before `ready` in any scenario (also
flags a compromised local x11vnc/wayvnc); `bridge.py` classifies `xfreerdp3` log tails
(malformed TSRequest, truncated DER, unexpected PDU, reset-before-auth, certificate mismatch)
into `proto.hostile_rdp_server{target}` instead of shipping text (pairs with C3); downstream
bursts above C9 caps → `proto.down_anomaly`. *Where:* `handle()` recv loop :1257-1272 and
finally :1289-1314; `bridge.py start_bridge` :92-159. *Mirror risk:* NONE (pure observation).

**C14 · In-protocol honeytokens — narrowed to what they can actually catch.** On control
`register` the relay mints, beside the real token, a decoy `reconnect_token`
(`token_urlsafe(32)`) and `session_id` (`'$' + uuid4`, the shape of guacd's `ready` id;
`session_registry.py` :59 already has a dead `reconnect_token` slot), recorded in a
`DecoyTable{value → uid, pid, conn, issued_at}` with the 8 h token TTL. The page stores them in
`localStorage['edy-rdp-session']` and a `<meta name="edy-rdp-session">` it never reads.
Exact-match touch points placed **before** today's generic refusal so the reply is identical:
`sessiontoken=<decoy>` (`SESSION_TOKENS.check` :878), `select $<decoy>` (:825), control
`terminate{uuid:<decoy>}`, `elevate{token:<decoy>}` → critical `decoy.session_token` with
`issued_to_uid` vs presenting uid and *same bridge pid* vs *other pid* (pid plumbed from
`peer_credentials` into `handle_control`, which drops it today). **What it catches:**
untargeted storage scrapers, rogue extensions, a copy-pasted localStorage. **What it does not:**
a targeted attacker who wraps `cockpit.channel` and never reads storage; the guacd container
(no `/run/edy-rdp` mount — the draft's "uid 999 = compromised guacd" attribution was
unreachable and is removed); the CVE classes the draft listed. The **raw-uuid canary** (a
36-char guacd uuid presented where a handle is expected) and the **door-credential canary**
(`rdpcred` on `greeter`, or an `rdpcred` username equal to the door user anywhere) are kept but
armed only **after** C10/C17 have been live long enough that no pre-cutover tab can present the
old artefact — the critic showed every pop-out opened before the cutover would otherwise fire
it on window close. *Where:* `SessionTokens.issue` :691-709, check sites :878/:825-828,
`_peek_scenario_from_connect` :959-965; `control.py` :87-104, :203-212; guac-rdp.js :707-720
(store, never read). *Mirror risk:* LOW.

**C15 · Host IPC decoy socket under `/run/edy-rdp` — recon canary, neutrally named.** A third
socket unit binding `/run/edy-rdp/guacd-direct.sock` (`SocketMode=0660`, same user/group as the
two real sockets, handed to the relay via `LISTEN_FDNAMES` which it already resolves
:1405-1420). On accept: `SO_PEERCRED`, read ≤ 4 KiB for ≤ 2 s to capture the first opcode,
emit critical `decoy.unix_socket{uid, pid, comm, first_op}`, reply `error 'not permitted' 771`,
close — what a real guacd socket does to a malformed handshake. The critic's decisive point:
`systemctl list-sockets` prints `LISTEN → UNIT` for every socket to any user, so a unit named
`edy-rdp-decoy.socket` labels itself. Therefore: unit file `edy-rdp-guacd-direct.socket`,
`Description=edy-rdp guacd direct socket (legacy)`, `FileDescriptorName=direct`, and no
"decoy" string in the unit, `LISTEN_FDNAMES`, the relay function or log names
(`direct_server`, event kind `direct_socket`). Scope: a shell-holding `cockpit-guac-rdp` member doing
reconnaissance, or a blind relay-uid implant; not G3 (the container cannot see `/run/edy-rdp`),
not G5. The shipped client opens only `SOCK` and `CONTROL`; the reaper only `control.sock`; the
self-test spawns `ss -tln` (TCP). *Mirror risk:* NONE.

**C16 · Host loopback TCP decoy listeners on guacd's egress side, kernel-attributed.** The
relay (AF_INET is permitted) binds `127.0.0.1:5979` — one below the x11vnc allocation range
5980-6079; assert the allocator in `edy-rdp-bridge-start.sh` never picks it — speaking a real
`RFB 003.008` banner, offering VNC-auth type 2 with a random challenge and replying auth-failed
exactly like x11vnc with a wrong password; and `127.0.0.1:4823` ("guacd alternate"), silent,
closing after 2 s. **Attribution moves into the kernel** (the critic showed `/proc/net/tcp`
racing to a half-closed row mis-attributes to uid 0): in the C20 output chain, `ct state new`
rules with `log prefix "edy-rdp-decoy guacd "` for the container's cgroup, `"edy-rdp-decoy
bridge "` for `skuid edy-relay`, and a catch-all `"edy-rdp-decoy other "` (log only, accept) —
the kernel stamps the identity; the relay's `/proc/net/tcp` lookup is a secondary hint trusted
only for rows in state 01/08. Until C12 lands, an admin pointing the `vnc` scenario at
`127.0.0.1:5979` is dialled **by guacd** — so C12's `self` deny must precede arming these as
criticals. *Mirror risk:* LOW; nothing legitimate dials 5979/4823.

**Decoy arg names** (in C9) and **decoy targets** (in C12) complete the deception inventory.

### 6.4 Outside the relay

**C20 · guacd container posture + egress fence.** `podman run … --cap-drop=ALL
--security-opt=no-new-privileges --read-only --tmpfs /tmp --tmpfs /home/guacd --pids-limit 256
--memory 1g`, and a **deterministic** uid mapping (`--uidmap 0:2000000:65536 --gidmap
0:2000000:65536`, or `containers:2000000:65536` in `/etc/subuid`+`/etc/subgid`) — never
`--userns=auto`, whose allocation changes across `--replace` and would break any uid-keyed
rule. **Identity for the fence is the cgroup, not a uid:** run with `--cgroups=split` so the
container lands in `system.slice/edy-rdp-guacd.service/…`, and match `socket cgroupv2 level 2
"system.slice/edy-rdp-guacd.service"` in an nft output hook (nft 1.1.6 supports it) — stable
across restarts and uid mappings. Chain, in order: `ct state established,related accept`
(**the draft lacked this; without it every reply to the relay's 4822 connection is logged and
dropped — a 100 % false positive flood**); `oif lo tcp dport {5980-6079, 34000-34999,
5979, 4823} accept` (guacd never dials 3389-3391 or 33000-33999 — every relay-managed connect
is rewritten to the x11vnc bridge; the draft's accept set was over-broad in exactly the
direction G3 warns about); non-loopback only per the C12 allow-list; everything else
`log prefix "edy-rdp-guacd-egress " drop` — deployed **LOG-ONLY first**. Add
`Requires=edy-rdp-firewall.service` + `After=` to the guacd and relay units, ship an
`nftables.conf` `include "/etc/nftables.d/*.nft"` so a reload re-installs the tables, and have
the reaper assert `nft list table inet edy_rdp_guacd` (critical `backend.nft_missing` + stop
guacd when absent) — nft is fail-open today. Remove the 4713 drop-in (I44); deploy the
loopback-only rule for grd 3389/3390 (I7). The pulse-bind and image-pin items of the draft are
already done by 1.4.0. *Mirror risk:* LOW with `ct state` in place; verify `--read-only` against
guacd's recording/tmp paths in observe.

**C21 · Remote-target `xfreerdp3` isolation (the deployment's actual reverse-RDP surface).**
For `HOST != 127.0.0.1` — and, per §10, for the **isolated** scenario too, whose grd is
user-owned — run `xfreerdp3 + Xvfb + x11vnc` under a template unit
`systemd/edy-rdp-remote-bridge@.service.in` with **`DynamicUser=yes`** (a distinct uid per
instance in 61184-65519, so two admins' remote sessions cannot read or hijack each other),
`PartOf=edy-rdp-relay.service`, `PrivateTmp=yes ProtectSystem=strict ProtectHome=yes
NoNewPrivileges=yes RestrictAddressFamilies=AF_UNIX AF_INET RuntimeMaxSec=12h`, started/stopped
by the relay through a new `edy-rdp-remote-bridge@` line in `hardening/edy-rdp-headless.rules`
(the critic: `systemd-run --uid` from `edy-relay` is polkit-checked as
`org.freedesktop.systemd1.manage-units` and would need a broader grant; bwrap needs
`CAP_SYS_ADMIN`). The bridge's display/port allocation and the x11vnc password hand-off move
with it: the relay unit has `PrivateTmp`, so a separate unit sees a different
`/tmp/.X11-unix` — allocate under `/run/edy-rdp/bridge/<key>/` instead. Drop unneeded channels
for remote targets (`-clipboard` unless explicitly enabled, `-rdpsnd`, `-rdpdr`, `-drdynvc`,
`/disp:off`), add `/timeout`, keep `/sec:rdp:off` and TOFU. Pin the FreeRDP host package and
add `freerdp3`, `xorg-server`, `x11vnc`/`libvncserver1` to `requires.txt` with a CVE watch
(none tracked today). The draft's `WS-<hex>` client-hostname canary is **dropped**: it collides
with real LAN hostnames and `%CLIENTNAME%` is routinely consumed by RDS logon scripts. *Where:*
`bridge/edy-rdp-bridge-start.sh` :54-57, :86-88, :141-149; `bridge.py start_bridge` :92-121;
relay :998-1000, :1079-1102; new unit; polkit; nft owner set; `requires.txt`. *Mirror risk:*
LOW for console/virtual/greeter when gated on the target; MEDIUM for remote/isolated until the
transient-unit path is proven — keep the in-process launch behind a flag as the fallback. This
is the only control that addresses G1b; nothing else in the plan does.

**C22 · Tier-1 SOC integration — credential-free by default.** The critic reversed the
draft's default: a relay-held hub API key is readable by every bridge child (`bridge.py`
:127-133 launches the bridge with `child_env=dict(os.environ)` in the same uid and mount
namespace, and `$CREDENTIALS_DIRECTORY` is inherited), so a hostile-RDP-server RCE in
`xfreerdp3` would hold a `security_write` key. **Default:** a root unit
`journalctl -f -o json _SYSTEMD_UNIT=edy-rdp-relay.service MESSAGE_ID=<decoy>
MESSAGE_ID=<proto> …` (same-field terms OR) appending to `<auditDir>/edy-rdp.jsonl`
(`root:root 0600` — the hub runs as root), registered as a **trusted** tail source, with each
hub filter's `source_glob` pinned to it; size cap + logrotate (the tailer survives truncation).
**Optional API-key tier**, only after C21 has moved the bridge children out of the relay's uid:
bounded queue (1024, drop-oldest, drops counted), one daemon thread POSTing
`http://127.0.0.1:8080/api/events/ingest` with `{type:'ingest.edy_rdp.<class>', severity,
source:'edy-rdp-relay', username, ip, message, vars}`; key minted with role `security_write`,
`allowed_ip 127.0.0.1`, a TTL, delivered via `LoadCredential=` and popped from the environment
before any child is spawned; **never** in the guacd container env (host netns reaches
8080/8444). `.env` carries only `EDY_RDP_SOC_INGEST=0|1`; the unit must tolerate an absent key
file (`LoadCredential=` with a missing file fails the unit — render the line only when the flag
is set). What the hub does and does not do (verified in `edy-proxy-go`): ingest requires the
event pipeline **enabled** (`events.pipeline.enabled`, OFF by default, restart) or it records
without dispatching; `IngestRequest.type` must start with `ingest.`; every POST also produces a
native `api.mutation` row (two rows per hit); **no alert checker reads `security_audit_log`** —
an event becomes a notification only through an event filter's webhook/job or a forwarder; hub
webhooks **refuse loopback and the node's own addresses**, so notification must go off-box or
via a task-engine job; the `unacked_critical` triage tile counts all origins, so a critical
ingest row does light it. *Mirror risk:* NONE.

## 7. Deception scheme and false-positive discipline

Principle (from all three designs, tightened by the deception design's rejection list): every
decoy is something the shipped `guac-rdp.js` **provably never does**, is checked at a point the
relay already parses (no added latency), is minted with the same generator as the real artefact
it imitates, and answers a toucher with exactly the reply a real failure would give.

| Decoy | Placement | Fires on | Cannot be fired by |
|---|---|---|---|
| connect-param names (C9) | synthetic `args` list | non-empty value in a decoy position | shipped client (fills unknown names with `''`), cached older client, page reload, pop-out |
| session token + session id (C14) | `localStorage['edy-rdp-session']`, `<meta>` | presented as `sessiontoken=`, `select $`, `terminate`, `elevate` | anything that uses the real token/ready id (all shipped paths) |
| remote target (C12) | `EDY_RDP_DECOY_TARGETS`, not disclosed to the page | any port on the decoy IP, before the allow-list | a normal picker entry; the page never learns the value |
| control ops (C11) | server-side only | `export`, `session-key`, `credentials`, `rejoin` | the seven shipped ops, the reaper, Self Tests (`list`) |
| `/run/edy-rdp/guacd-direct.sock` (C15) | third socket unit, neutral name | any connect | client (`SOCK`, `CONTROL` only), reaper, self-test (`ss -tln`) |
| `127.0.0.1:5979` RFB / `:4823` (C16) | relay listeners, kernel-logged | any connect | bridge allocator (asserted), relay-injected targets, C12 `self` deny |
| raw guacd uuid where a handle is expected (C14, after C10) | join/terminate paths | 36-char uuid | pre-cutover tabs — **arm only after cutover** |
| `rdpcred` on `greeter` / door username anywhere (C14, after C17) | connect markers | presence | pre-cutover clients — **arm only after cutover** |

**Rejected placements** (each would have fired on a legitimate client): a decoy row in `list`
(every row gets a Terminate button), a decoy path in error text, a decoy entry in the target
picker `datalist`, decoy files in the Cockpit package dir (Self Tests fetches assets; link
prefetchers), clipboard injection, a decoy port inside the x11vnc allocator range, arbitrary
hash keys (the hash parser tolerates unknown keys), telling the page the decoy target.

**What an attacker learns:** the Janua image and this repo are public, so the real `args` list,
the control op names and the unit names are knowable; decoys are for the impatient and the
automated. That is stated in every control above rather than implied away.

## 8. Security-event contract

- **Tier 0 (always):** native journald datagram from the relay (C2). Provenance =
  `_SYSTEMD_UNIT + _UID + _COMM`; `MESSAGE_ID` per class; `EDY_RDP_*` fields; handles not uuids,
  hashes not values, `ipv4:port` targets only for remote/vnc. Severity: 2 for `decoy.*`,
  `proto.guacd_suspect`, `select_pinned`, `forced_param`, `opcode_denied_up`,
  `marker_misplaced`, `raw_uuid_presented`, `door_cred_presented`, `direct_socket`; 4 for
  arity/length/parse/overrun/rate, `opcode_denied_down`, `clipboard_capped`,
  `guacd_abort_remote`, `handshake_timeout`, `target_scan`, `hostile_rdp_server`, policy
  refusals, `control.op_denied`; 6 for summaries, mode transitions, benign refusals,
  `canary_issued`.
- **Tier 1 (SOC):** the trusted `journalctl` exporter into the hub's audit dir by default;
  the ingest API key only under the C22 conditions. Hub one-time setup: enable the event
  pipeline in a restart window; 3–4 filters (`^decoy `, `^proto\.(select_pinned|forced_param)`,
  `guacd_abort_remote`, `hostile_rdp_server`) with an off-box action; optionally a forwarder
  class `ingest.edy_rdp.` to a SIEM.
- **Consumer and SLA (completeness):** name the consumer — the hub's `unacked_critical` tile
  plus a daily digest job off-box, and a Cockpit `page_status` badge for admins on login
  (`cockpit.transport.control("notify", {page_status:…})`); add a **canary of the canary**: a
  weekly root timer touches one decoy from a test uid and asserts, via the same read path a
  human uses, that the event arrived within 60 s, else raises a separate *monitoring broken*
  alarm.
- **Journal exposure (completeness):** once internals move to the journal, the journal is the
  sensitive store. Set the `edy-rdp-trace` logger to DEBUG (off by default) and keep only
  reason-code lines at INFO; `LogNamespace=edy-rdp` on the relay, reaper and helper units so
  retention and readers can be set apart from the system journal; document the readers in
  `docs/SCOPE.md`.

## 9. Rollout

A mode switch `EDY_RDP_PROTO_FW ∈ {off, observe, enforce-up, enforce}` gates every
prevent/minimise control; decoys and detectors are `detect-only` flags. **The mode must be a
runtime value** (completeness): re-read on `SIGHUP` (`ExecReload=kill -HUP $MAINPID`), evaluated
per instruction from a cached atomic; a root-only control op `fw-mode`; and an automatic
circuit breaker — if `PROTO_*` refusals exceed X/min across ≥ 2 uids, fall back to `observe`
and emit critical `proto.breaker_tripped`. A restart-only kill-switch on a thread-per-connection
relay makes the revert itself an outage, which discourages ever enabling enforce mode.

| Step | Mode | Lands | Gate |
|---|---|---|---|
| 0 | — | complete the I43 reclaim so relay, JS and helpers are one version; capture one full session per scenario (console with keyboard+clipboard+audio, virtual pop-out ×2, isolated, wayland-vnc, greeter, remote, vnc) as fixtures; `install.sh --verify` as a hard gate at the start of every later step; **Phase-0 defects D-6, D-10, D-11 fixed** (file modes, 4713, marker strip) | zero events replaying fixtures |
| 1 | off | C1 codec caps (they bite only malformed input) + C3 reason codes + C2 tier 0 with the trust contract | fixtures replay clean; Unlock/auth hints still trigger |
| 2 | observe ≥ 7 days | C4 state machine, C5 authored connect (computed, real connect still forwarded; forced-param and marker checks log only), C6/C7 tables, C8/C9 classification, C13 phase tracking, C12 deny evaluation | observe telemetry shows zero would-be refusals from legitimate sessions |
| 3 | enforce-up (handshake) | C4 select pin + second-select refusal + mimetype rules; C5 allowlist + `_enforce_target` + marker strip; C12 `self`/loopback/`0.0.0.0` deny + token for remote/vnc + decoy targets | remote/vnc still reach legitimate LAN hosts |
| 4 | enforce-up (session) | C7 tables + stream caps, C6 bounds, C11 control-API limits/minimisation/greeter admin gate/sweep | pop-outs, resume, toggles all `register` fine |
| 5 | enforce | C8 drops (event-only), C9 scrubbers with the **real** list still advertised, then the synthetic list | args round-trip test; clipboard caps measured |
| 6 | detect-only | C9 decoy names, C14 session honeytokens, C15 direct socket, C16 loopback decoys (after C12) | one week, zero decoy events from staff |
| 7 | — | C17 (relay + helper first, client still sends `rdpcred`; then the client deletion), C18 remainder, C19, C10 handles; arm the raw-uuid and door canaries only after every pre-cutover tab is gone | console/virtual/greeter e2e on edt1 |
| 8 | — | C20 egress chain LOG-ONLY → drop; container posture; `Requires=` firewall; C21 remote-bridge unit behind a flag, then isolated | `journalctl -k -g edy-rdp-guacd-egress` quiet on healthy sessions |
| 9 | — | C22 exporter, hub filters, consumer + canary-of-the-canary; docs | a synthetic `select rdp` from a test uid is visible where the human looks within 60 s |

## 10. What the completeness pass added

1. **User-owned backend servers are "malicious servers" too.** The isolated scenario dials the
   caller's *own* headless grd (`edy-rdp-headless-start.sh` runs it as the user); a FreeRDP
   client-parser bug is then a **local privilege escalation from any RDP user to `edy-relay`**.
   → C21 covers `isolated`, not only non-loopback hosts; the relay verifies before dialling that
   the listener on `33000+uid`/`34000+uid` is the expected process.
2. **x11vnc/libvncserver and Xvfb face guacd as their client** inside the relay's uid; a guacd
   RCE → libvncserver bug → code as `edy-relay`. → each x11vnc+Xvfb pair under the same
   DynamicUser unit as C21 once proven; minimal x11vnc argv (`-nocmds -noremote -nofilexfer`);
   `xorg-server`/`x11vnc`/`libvncserver1` in `requires.txt` with a CVE watch.
3. **The relay's polkit grants are for ANY instance** (`edy-rdp-{headless,waylandvnc,deskui,
   unlock}@*`). → root helpers verify a fact the relay cannot forge: the target uid has a live
   logind session with `Service=cockpit` created within N hours; `unlock` additionally requires
   a root-readable challenge the browser wrote over a superuser channel.
4. **Cockpit's superuser bridge is an unmapped identity**: `superuser:'require'` channels arrive
   as **uid 0**, indistinguishable from the reaper, bypassing every uid-bound check. → plumb
   `SO_PEERCRED` pid; attribute uid-0 peers by `/proc/<pid>/cgroup` — only
   `system.slice/edy-rdp-reaper.service` may `ping`/`prune`; a uid-0 peer in a
   `session-*.scope` is the logged-in user and must still present a token.
5. **nft enforcement is fail-open.** → C20's `Requires=`, the `include`, the reaper assertion.
6. **The patched grd daemon is a single point of failure for I5** that nothing verifies at
   runtime (stock grd returning re-broadcasts the one-time door credential on the system bus).
   → 1.4.0's `--verify` hash/hold check, plus a reaper `backend.grd_unpatched` critical, plus
   a receive-side deny for the Handover interface matching the gdm-greeter uid range.
7. **Door-credential rotation defers itself forever** while any socket on :3390 is established,
   with no maximum and no event. → count deferrals; rotate anyway after N with a warning event;
   restrict the busy test to peers that are the bridge; emit `rotate.deferred/done` via C2.
8. **The relay unit's own sandbox is thin** for a process that is about to host a new parser and
   every bridge child. → `SystemCallFilter=@system-service ~@privileged @resources`,
   `IPAddressAllow=localhost` + rendered `EDY_RDP_REMOTE_ALLOW` CIDRs, `IPAddressDeny=any` (a
   kernel-enforced backstop to C12), `UMask=077`; validated with `systemd-analyze security` in
   the tests.
9. **The kill-switch must be runtime** (§9).
10. **Test coverage is unit-only.** → `tests/integration`: `podman run` of the pinned Janua image
    + the relay from the checkout + a stdlib client replaying the Step-0 fixtures per scenario
    against a tiny scripted RFB server (also the hostile-server fixture for C13: over-long
    name, bad rect, early EOF), asserting zero events; fixtures stored next to the image digest
    and the test fails when `.envdefault`'s digest changes without new fixtures.
11. **Supply chain.** → `install.sh` refuses to serve a file not owned `root:root`; Self Tests
    hash each served asset against a build-time manifest (the SRI intent); verify the image with
    `podman image trust`/cosign against Janua's signature or build it locally from the pinned
    tarballs; an advisory watch (Apache, Janua, FreeRDP, Debian, xorg, libvncserver) with a named
    owner.
12. **No named consumer or SLA for the events** (§8).
13. **The Cockpit auth boundary and the `cockpit-guac-rdp` group are outside the event stream.** → the
    reaper diffs `getent group cockpit-guac-rdp`/`sudo` each run and emits `control.group_changed`; the
    hub tails `cockpit.service` PAM lines as a trusted source so decoy hits can be joined to the
    login that preceded them.
14. **URL-level decoys were rejected too early.** They are the one place an attacker who never
    reaches the relay (credential stuffing against :9090, an SSRF into 9090, a scraped bookmark)
    can be caught. → verify whether :9090 is an edy LB backend; if so, LB match rules for 2–3
    never-linked paths under `/cockpit/@localhost/guac-rdp/` returning cockpit-ws's own 404 and
    emitting an LB security event with the client IP; if not, front it (the auth-gated frontend
    pattern exists) or add SPA-side decoy hash routes reported through C14.
15. **Journal exposure** (§8).
16. **Deployment coherence is assumed** (Step 0; `install.sh --verify` as the gate; a relay
    `version` in the `register` reply that the JS compares with its manifest).

## 11. Decisions the operator must make

| Decision | Options | Default in this plan |
|---|---|---|
| `EDY_RDP_REMOTE_ALLOW` CIDRs | the LAN prefix(es) actually used for remote/vnc | replace `any:*`; `self,0.0.0.0/8,127.0.0.0/8,169.254.0.0/16,224.0.0.0/3` denied regardless |
| decoy target IP(s) | 1–2 reserved, never-assigned RFC1918 `ip:port` | operator reserves in the DHCP/IPAM ledger |
| hub event pipeline | enable (restart) / leave off | enable in a window; exporter as the source |
| SOC credential | none (exporter) / `security_write` key | **none** until C21 |
| `vnc`/`remote` clipboard | explicit-only / auto | explicit-only |
| Janua update cadence | monthly re-pin with fixtures / freeze | monthly, gated by the integration replay |
| C21 for `isolated` | with remote / later | with remote (it is the same class) |

## 12. Cost (honest)

≈ 1,600–1,900 LOC of relay/control/bridge Python plus ≈ 60 tests; ≈ 150 LOC JS; one root
helper unit + polkit line (C17); one socket unit (C15); one template unit + polkit line (C21);
one nft chain + `Requires=` (C20); one exporter unit (C22); hub setup (pipeline, 3–4 filters,
one forwarder); an integration test that needs podman in the test environment; and the
operator decisions above. Steps 0–2 are risk-free to the mirror; Steps 3–5 are where the
observe-mode data must be read before flipping; C17 and C21 are the two changes that alter how
sessions authenticate and where processes run, and each ships behind a flag with the current
path as the fallback.

Related: [CVE register](CVE.md) · [architecture](ARCHITECTURE.md) · [scenarios](SCENARIOS.md) ·
[known issues](KNOWN_ISSUES.md) (I1, I3, I5, I7, I29, I35, I37, I42–I44) · `hardening/`.
