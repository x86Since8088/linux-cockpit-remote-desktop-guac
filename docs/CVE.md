# CVE register — Apache Guacamole / guacd

Which Guacamole CVEs this architecture addresses, which remain relevant, and which
do not apply. Confirmed via the Apache security page + NVD/GitHub advisories.

**Architecture recap:** guacd binds **host loopback only** (127.0.0.1:4822) with an nftables
owner-match admitting solely the relay uid — no host-reachable port for other users — fronted
by the AF_UNIX relay (SO_PEERCRED auth + per-user UUID binding); browser uses Cockpit HTTPS +
guacamole-common-js directly; **the Guacamole Java webapp / Tomcat and all its extensions
are removed.**

## The key distinction
The relay defends the **front** of guacd — who may talk to it and whose session they may
attach to. It does **nothing** for the **back** — the RDP server guacd dials out to. The
severe guacd CVEs (the 2020 "Reverse RDP" cluster, the audio UAF) are a malicious RDP
*server* attacking guacd's client code; only a patched guacd + a trusted-endpoint allow-list
close those. **Pin guacd ≥ 1.6.0** and this whole list is cleared in one move.

## Addressed by this architecture (webapp/extensions removed, or session-join blocked)
| CVE | Component | Why addressed |
|---|---|---|
| CVE-2021-43999 | SAML extension | extension not used |
| CVE-2021-41767 | REST API tunnel-ID leak → cross-user session interaction | REST API removed **and** directly countered by the relay's UUID→user binding |
| CVE-2020-11997 | connection-history info disclosure | webapp feature not used |
| CVE-2018-1340 | insecure session cookie | no Guacamole cookie; sessions ride Cockpit HTTPS |
| CVE-2016-1566 | file-browser stored XSS | webapp UI not used — **caveat:** escape server-supplied strings in our own JS UI |

CVE-2021-41767 is worth calling out: it is exactly the session-join-by-identifier class the
relay is built to stop. Even at the protocol layer, binding each guacd UUID to the
authenticating uid is the direct defense.

## Still relevant — guacd RDP path — mitigated by unreachability, real fix is a patched guacd
| CVE | Component | Status |
|---|---|---|
| CVE-2020-9497 | guacd RDP static-channel info disclosure | server-side; relay does NOT stop it — guacd ≥1.2.0 + trusted endpoints |
| CVE-2020-9498 | guacd RDP UAF → RCE ("Reverse RDP") | server-side; guacd ≥1.2.0 |
| CVE-2023-30576 | guacd RDP audio-input UAF → RCE | in-path if RDP audio-input enabled; guacd ≥1.5.2 or disable audio-in |
| CVE-2023-30575 | guacd Guacamole-handshake instruction injection | front-side; relay auth + UUID binding reduce it to an authenticated user's own handshake; guacd ≥1.5.2 |

## Not applicable while RDP-only (return to scope if SSH/telnet/VNC are added)
| CVE | Component |
|---|---|
| CVE-2024-35164 | guacd terminal emulator (SSH/telnet only) — ship guacd ≥1.6.0 regardless |
| CVE-2023-43826 | guacd VNC integer overflow (VNC only) |
| CVE-2012-4415 | ancient libguac plugin overflow (historical) |

## Could not confirm as standalone CVEs
- **SSRF:** no dedicated Guacamole SSRF CVE. The SSRF-flavoured work is Sonar's "Avocado"
  chain leveraging CVE-2023-30575 + deployment behaviour. **Takeaway:** guacd dials whatever
  host it is told — the relay MUST enforce an allow-list of RDP targets (planned; see below).
- **LDAP:** no dedicated Guacamole LDAP CVE; the LDAP extension is part of the removed webapp anyway.

## Actions this project takes / must take
1. **Pin guacd to a current release** (pod image tag; ≥1.6.0). Owner: pod/install.
2. **Allow-list RDP targets in the relay** — guacd must only be told to dial 127.0.0.1:3389/3390/3391.
   (Relay enhancement: reject `connect` hostnames/ports outside the allow-list. Tracked as a follow-up
   to Task 2.)
3. **Consider disabling RDP audio-input** to shrink the 9498/30576 surface.
4. **Escape server-supplied strings** in `guac-rdp.js` (CVE-2016-1566 class).
5. Keep the **RDP-only** posture explicit; SSH/telnet/VNC re-introduce CVE-2024-35164 / CVE-2023-43826.

Sources: Apache Guacamole Security Reports (https://guacamole.apache.org/security/);
Check Point "Would you like some RCE with your Guacamole?"; NVD/GitHub advisories per CVE;
Sonar "Avocado" research; elttam CVE-2023-43826 write-up.
