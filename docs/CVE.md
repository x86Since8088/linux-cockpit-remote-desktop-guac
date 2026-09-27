# CVE register — Apache Guacamole / guacd

Which Guacamole CVEs this architecture addresses, which remain relevant, and which
do not apply. Confirmed via the Apache security page + NVD/GitHub advisories; the
deployment facts below were re-verified against v1.3.2 (`8fc87cc`) and host edt1 on
2026-09-27 as part of the [defence-layer review](DEFENSE-LAYER.md), which corrected
three earlier claims in this file (marked **corrected**).

**Architecture recap:** guacd binds **host loopback only** (127.0.0.1:4822) with an nftables
owner-match admitting solely the relay uid — no host-reachable port for other users — fronted
by the AF_UNIX relay (SO_PEERCRED auth + per-user UUID binding); browser uses Cockpit HTTPS +
guacamole-common-js directly; **the Guacamole Java webapp / Tomcat and all its extensions
are removed.** The relay **re-parses and re-encodes every instruction in both directions**
(`parse_one`/`drain`, `encode`), so a browser can never hand guacd a raw length prefix.

**What guacd actually speaks here (corrected):** every relay-managed scenario — console,
virtual, greeter, isolated, remote — is rewritten by `_inject_vnc_target` so that guacd is a
**VNC client** to a host-local x11vnc on an Xvfb painted by `xfreerdp3`. The RDP leg to
gnome-remote-desktop (or to an operator's remote host) is spoken by **`xfreerdp3` on the host,
as uid `edy-relay`, inside the relay's own unit**. Only the `vnc` scenario hands guacd an
operator-chosen server directly. The earlier "RDP-only" framing of this file was therefore
inverted: the reverse-RDP CVE class lands on the host's FreeRDP client, and the
malicious-VNC-server class is the one in guacd's path.

**Which guacd (corrected):** the live image is Janua **1.0.1** =
`ghcr.io/skylark-software/janua@sha256:2279eac0…` — the Apache `guacamole-server-1.6.0` tarball
+ FreeRDP 3.10.3 + three Janua RDP patches (rdpsnd v8, H.264/AVC, RDPGFX/GDI sync) on
Debian 13. Pinned by digest in `.envdefault` since 1.4.0 (it was recorded nowhere in git before
that). Janua republishes `1.0.1`/`latest` monthly; the pin is orphaned from 2026-10-01 unless
re-pinned with the integration fixtures DEFENSE-LAYER.md §10 calls for. `policy.json` is
`insecureAcceptAnything`: integrity rests on the digest alone.

## The key distinction
The relay defends the **front** of guacd — who may talk to it and whose session they may
attach to. It does **nothing** for the **back** — the server guacd (or xfreerdp3) dials out to.
The severe guacd CVEs (the 2020 "Reverse RDP" cluster, the audio UAF, the 2023 VNC overflow)
are a malicious *server* attacking client code; only a patched client + a trusted-endpoint
allow-list close those. The base is guacd 1.6.0, so every CVE below is closed **by version**;
what the [defence layer](DEFENSE-LAYER.md) is for is the *next* bug of each class, and the
holes that exist regardless of guacd's version (its §4).

## Addressed by this architecture (webapp/extensions removed, or session-join blocked)
| CVE | Component | Why addressed |
|---|---|---|
| CVE-2021-43999 | SAML extension | extension not used |
| CVE-2021-41767 | REST API tunnel-ID leak → cross-user session interaction | REST API removed **and** directly countered by the relay's UUID→user binding |
| CVE-2020-11997 | connection-history info disclosure | webapp feature not used |
| CVE-2018-1340 | insecure session cookie | no Guacamole cookie; sessions ride Cockpit HTTPS |
| CVE-2016-1566 | file-browser stored XSS | webapp UI not used — **caveat:** `setStatus` and the tables use `textContent`, but three `innerHTML` sinks with relay-supplied text remain (guac-rdp.js `renderDeskUi`/rejection handlers) — DEFENSE-LAYER C19 |

CVE-2021-41767 is worth calling out: it is exactly the session-join-by-identifier class the
relay is built to stop. Even at the protocol layer, binding each guacd UUID to the
authenticating uid is the direct defense. The raw guacd UUID still reaches the browser today
(as `ready $uuid`, and in full in admin `list` rows); DEFENSE-LAYER C10 replaces it with a
relay-minted handle.

## Closed by version — class still in path
| CVE | Component | Version status | Residual class and where it lands |
|---|---|---|---|
| CVE-2020-9497 | guacd RDP static-channel info disclosure | fixed 1.2.0; base 1.6.0 | guacd's RDP plugin is reachable only through an **unpinned `select rdp`** (relay does not pin the protocol) — closed by C4 |
| CVE-2020-9498 | guacd RDP UAF → RCE ("Reverse RDP") | fixed 1.2.0 | same; and the deployment's real reverse-RDP surface is **`xfreerdp3` on the host** (FreeRDP 3.31, uid `edy-relay`, all channels on) — C21 |
| CVE-2023-30576 | guacd RDP audio-input UAF → RCE | fixed 1.5.2 | the client never sets `enable-audio-input`, but the relay **passes every browser-supplied connect parameter through** — C5 |
| CVE-2023-30575 | guacd handshake instruction injection | fixed 1.5.2 | the relay's re-encode already normalises framing; its **own** parser is unhardened (`int()` accepts non-ASCII digits; per-chunk UTF-8 decode desyncs on a split multibyte char) — C1 |
| CVE-2023-43826 | guacd VNC framebuffer integer overflow → RCE | fixed 1.5.4 | **corrected: in path.** guacd is a VNC client in every scenario; the `vnc` scenario with `EDY_RDP_REMOTE_ALLOW=any:*` puts libvncclient against an operator-chosen server, and the browser-settable `reverse-connect`/`listen-timeout` make guacd **listen** for an inbound "server" in the host netns — C5, C12, C13, C20 |
| CVE-2024-35164 | guacd terminal emulator (ssh/telnet) | fixed 1.5.5 | reachable only via an unpinned `select ssh|telnet` if the image built those plugins — C4 closes it regardless of the image |
| CVE-2012-4415 | ancient libguac plugin overflow | historical | — |

## Could not confirm as standalone CVEs
- **SSRF:** no dedicated Guacamole SSRF CVE. The SSRF-flavoured work is Sonar's "Avocado"
  chain leveraging CVE-2023-30575 + deployment behaviour. **Takeaway:** guacd dials whatever
  host it is told. **Corrected:** the relay's `--allow-target` gate (`_enforce_target`,
  `EDY_RDP_ALLOW_ARGS`) is defined and unit-tested but **never invoked on the live connect
  path**; what keeps relay-managed scenarios on loopback is that the relay overwrites
  `hostname`/`port`. And `any:*` accepts loopback, link-local and `0.0.0.0`, which reaches the
  host's four password-less qemu VNC consoles (127.0.0.1:5900-5903). DEFENSE-LAYER C5 + C12.
- **LDAP:** no dedicated Guacamole LDAP CVE; the LDAP extension is part of the removed webapp anyway.

## Actions this project takes / must take
1. **Pin guacd by digest and own the re-pin.** Done for the pin (1.4.0 `.envdefault`,
   `requires.txt`, `--verify` image check). Still needed: a monthly re-pin gated by the
   integration replay, signature/provenance verification, and a named advisory watch for
   Apache, Janua, FreeRDP, Debian, xorg-server and libvncserver (DEFENSE-LAYER §10).
2. **Pin the protocol in the relay** — `select` must be `vnc`; refuse a second `select`
   (C4). Until this lands, "SSH/telnet/RDP not applicable" is policy-by-accident of the
   browser, not a property of the middleware.
3. **Author the guacd `connect` server-side** — explicit allowlist of client-settable
   parameters, everything else forced empty and treated as a tripwire; actually call
   `_enforce_target`; strip relay markers anywhere in the vector (C5).
4. **Fence remote targets** — explicit CIDRs instead of `any:*`; deny `self`, `0.0.0.0/8`,
   loopback, link-local, multicast regardless; require the proven session token for
   `remote`/`vnc` (C12).
5. **Take the grd gate/door credentials out of the browser** (C17) and fix the group-readable
   bridge/headless credential files (C18) — the two items that are a hole today independent
   of any CVE.
6. **Escape / bound server-supplied strings** in `guac-rdp.js` — the three `innerHTML` sinks,
   the unbounded `lastRemoteClip`, the focus-triggered clipboard push to remote hosts (C19);
   and scrub `name`/`error`/`clipboard` in the relay (C9).
7. **Move `xfreerdp3` (and, for isolated, its x11vnc/Xvfb) out of the relay's uid** — a
   DynamicUser transient unit per bridge (C21). This is the only control that addresses the
   reverse-RDP class as it actually lands here.
8. **Container posture and egress** — cap-drop, no-new-privileges, read-only, limits, a
   deterministic uid map, and a cgroup-keyed egress chain with `ct state established` first;
   make the firewall unit a `Requires=` so nft is not fail-open (C20).
9. **Emit structured security events** with a stated trust contract (C2), and name who reads
   them (§8).

Sources: Apache Guacamole Security Reports (https://guacamole.apache.org/security/);
Check Point "Would you like some RCE with your Guacamole?"; NVD/GitHub advisories per CVE;
Sonar "Avocado" research; elttam CVE-2023-43826 write-up; Janua `guacd/Dockerfile` and
CHANGELOG (skylark-software/janua).
