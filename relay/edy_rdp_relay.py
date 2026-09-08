#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
#
# edy-rdp-relay — the security core of cockpit-guac-rdp.
#
# guacd has NO authentication (KNOWN_ISSUES I1) and joining an existing session
# by its UUID needs no credential at all (I2 — verified session hijack). This
# relay is the sole ingress to guacd: guacd runs in a pod netns with no host
# port, and the only way in is this AF_UNIX socket, reached over Cockpit's HTTPS
# stream channel. For every connection the relay:
#
#   * identifies the peer by SO_PEERCRED  (kernel-supplied uid, unforgeable)
#   * lets `select <protocol>` start a NEW session, but allows
#     `select $<uuid>` (join) ONLY if that uuid is owned by the same uid  (I2)
#   * records `ready $<uuid>` -> owning uid so later joins can be judged
#   * requires the caller be an admin for the console/mirror scenario  (I4)
#   * injects periodic `nop` keepalives or guacd aborts at ~18s  (I8)
#
# stdlib only. No pip. Python 3.9+.


# The payload is IMMUTABLE once deployed: nothing at runtime writes inside it,
# not a log, not a cache, not a __pycache__ (DEPLOY-CONTRACT section 1.3). This
# script is reached through a symlink in /usr/libexec/edy-rdp, and Python
# resolves that symlink for sys.path[0] - so without this line, importing the
# sibling modules writes bytecode into the deployed payload and into the libexec
# directory. Set BEFORE any project import, or the first one is already cached.
import sys
sys.dont_write_bytecode = True


def _env_file_hint():
    """The .env this host is configured by, for use in operator-facing messages.

    Read from /etc/cockpit-guac-rdp/install.conf, which install.sh writes -- never
    resolved relative to this file. This script is reached through a symlink; in a
    deployed install that resolves into the payload, and in a DEV install it
    resolves into somebody's checkout, so 'the .env beside me' is the wrong answer
    exactly when it matters (DEPLOY-CONTRACT section 4.3)."""
    try:
        with open("/etc/cockpit-guac-rdp/install.conf", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("ENV_FILE="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return "this host's cockpit-guac-rdp .env (see /etc/cockpit-guac-rdp/install.conf)"

import argparse
import grp
import ipaddress
import json
import logging
import itertools
import os
import re
import secrets
import selectors
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid as uuidlib

from session_registry import SessionRegistry
from control import LiveConnections, handle_control
import bridge

log = logging.getLogger("edy-rdp-relay")

# ---------------------------------------------------------------------------
# Tracing. A dedicated always-on trace logger that details EVERYTHING the
# middleware does — connection identity, every control-plane instruction in
# both directions, scenario/gate decisions, target resolution, bridge
# lifecycle, slot takeovers, registry transitions, and data-plane op COUNTS
# (per-op-name totals; the img/sync/mouse flood is summarized, not spammed) —
# with every password/credential value REDACTED to "<redacted:LEN>". Values
# never traced at all: the rdpcred password half, RDP/VNC passwords in connect
# rewrites, and headless CRED material.
# ---------------------------------------------------------------------------
trace_log = logging.getLogger("edy-rdp-trace")
_SENSITIVE_KEY = re.compile(r"pass|cred|secret|token", re.I)
_conn_counter = itertools.count(1)


def _redact_kv(name, value):
    if value and _SENSITIVE_KEY.search(name or ""):
        return "%s=<redacted:%d>" % (name, len(value))
    return "%s=%s" % (name, value)


def redacted_params(names, values):
    """'k=v k2=v2 ...' for a connect payload, password-family values redacted."""
    return " ".join(_redact_kv(n, v) for n, v in zip(names, values))

# ---------------------------------------------------------------------------
# Guacamole wire protocol codec.
# An instruction is  LEN.VALUE,LEN.VALUE,...;  where LEN counts Unicode
# codepoints (not bytes). This mirrors source/guac-proto.js so the shipped
# relay and the shipped browser codec agree byte-for-byte.
# ---------------------------------------------------------------------------


def encode(*elements):
    out = []
    for el in elements:
        s = "" if el is None else str(el)
        out.append("%d.%s" % (len(s), s))
    return ",".join(out) + ";"


def _cp_slice_end(s, start, cps):
    """Index just past `cps` codepoints of `s` beginning at `start`.

    Python strings are already codepoint-indexed, so this is start+cps bounded
    by len(s); returns -1 if the string is too short.
    """
    end = start + cps
    return end if end <= len(s) else -1


def parse_one(buf, pos):
    """Parse a single instruction from `buf` at `pos`.

    Returns (elements, next_pos) or None if `buf` does not yet hold a complete
    instruction (caller should read more and retry).
    """
    elements = []
    i = pos
    while True:
        dot = buf.find(".", i)
        if dot < 0:
            return None
        try:
            length = int(buf[i:dot])
        except ValueError:
            return None
        vstart = dot + 1
        vend = _cp_slice_end(buf, vstart, length)
        if vend < 0 or vend > len(buf):
            return None
        elements.append(buf[vstart:vend])
        sep = buf[vend:vend + 1]
        if sep == ",":
            i = vend + 1
            continue
        if sep == ";":
            return elements, vend + 1
        return None  # malformed separator


def drain(buf, on_instruction):
    """Feed every complete instruction in `buf` to on_instruction; return the
    unconsumed tail."""
    pos = 0
    while True:
        res = parse_one(buf, pos)
        if res is None:
            return buf[pos:]
        elements, pos = res
        on_instruction(elements)


# ---------------------------------------------------------------------------
# select classification.
# ---------------------------------------------------------------------------


def classify_select(elements):
    """Return ('new', protocol) | ('join', uuid) | ('bad', reason) for a parsed
    `select` instruction. guacd treats a leading '$' as "join this connection id"."""
    if not elements or elements[0] != "select":
        return ("bad", "not a select instruction")
    if len(elements) < 2 or elements[1] == "":
        return ("bad", "select with no argument")
    arg = elements[1]
    if arg.startswith("$"):
        return ("join", arg[1:])
    return ("new", arg)


# ---------------------------------------------------------------------------
# Peer identity (SO_PEERCRED) and authorization.
# ---------------------------------------------------------------------------

_UCRED = struct.Struct("3i")  # pid, uid, gid


def peer_credentials(conn):
    raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, _UCRED.size)
    pid, uid, gid = _UCRED.unpack(raw)
    return pid, uid, gid


def is_admin(uid, admin_group="sudo"):
    """True if uid is root or belongs to the admin group. Server-side console
    gate (I4): a client-side check is cosmetic and bypassable."""
    if uid == 0:
        return True
    try:
        pw_name = _username(uid)
    except KeyError:
        return False
    try:
        members = set(grp.getgrnam(admin_group).gr_mem)
    except KeyError:
        return False
    return pw_name in members


def _username(uid):
    import pwd
    return pwd.getpwuid(uid).pw_name


# ---------------------------------------------------------------------------
# Per-connection relay.
# ---------------------------------------------------------------------------

ADMIN_ONLY_SCENARIOS = {"console"}  # mirror of the physical screen (I4)
# These screencast the LOCAL seat session; grd refuses ("Session creation inhibited")
# when that screen is LOCKED, which reaches the client as an opaque transport error.
LOCAL_SEAT_SCENARIOS = {"console", "virtual"}
ALLOW_TARGETS = None  # set of 'host:port' guacd may dial; None = unrestricted
KEEPALIVE_SECONDS = 4.0

# Each live bridge consumes one of ~100 Xvfb/VNC display slots. Cap concurrent
# bridges per uid so one authenticated user cannot exhaust the pool (DoS).
MAX_BRIDGES_PER_UID = 6


class _BridgeCounter:
    """Per-uid count of live bridges, to bound resource use."""
    def __init__(self):
        self._lock = threading.Lock()
        self._by_uid = {}

    def acquire(self, uid):
        with self._lock:
            n = self._by_uid.get(uid, 0)
            if n >= MAX_BRIDGES_PER_UID:
                return False
            self._by_uid[uid] = n + 1
            return True

    def release(self, uid):
        with self._lock:
            n = self._by_uid.get(uid, 0)
            if n <= 1:
                self._by_uid.pop(uid, None)
            else:
                self._by_uid[uid] = n - 1


BRIDGE_COUNTER = _BridgeCounter()

# --- remote-host RDP scenario (jump into another RDP host on the LAN) ----------
# The "remote" scenario lets the browser supply an arbitrary target host:port to
# RDP into. That is an SSRF-class capability (the relay/bridge dials it, and the
# user's RDP credential is sent there), so it is FAIL-CLOSED: denied unless the
# target matches an admin-configured allow-list. REMOTE_ALLOW is a list of
# (ipaddress network | None=any, port:int | None=any-port); [] = deny all.
REMOTE_ALLOW = []
REMOTE_ADMIN_ONLY = False       # require proven Cockpit admin for the remote scenario
REMOTE_DEFAULT_PORT = 3389


def parse_remote_allow(spec):
    """Parse EDY_RDP_REMOTE_ALLOW into [(network|None, port|None)] (deny-list is []).
    Entry forms (comma/space separated): IP, CIDR, IP:port, CIDR:port, IP:*, CIDR:*,
    'any', 'any:port', 'any:*'. A missing port defaults to 3389; '*' means any port;
    'any' means any host. Only IPv4 is supported (colon is the port separator).
    Empty/unset spec => [] (deny all — fail closed)."""
    out = []
    for raw in (spec or "").replace(",", " ").split():
        item = raw.strip()
        if not item:
            continue
        host_part, port_part = item, None
        if ":" in item:  # split a trailing :<port|*> only if it looks like one
            h, _, p = item.rpartition(":")
            if p == "*" or p.isdigit():
                host_part, port_part = h, p
        net = None
        hp = host_part.strip()
        if hp.lower() != "any":
            try:
                net = ipaddress.ip_network(hp, strict=False)
            except ValueError:
                continue                       # skip a malformed entry (fail closed on it)
            if net.version != 4:
                continue                       # IPv4 only for remote (see parser note)
        if port_part is None:
            port = REMOTE_DEFAULT_PORT
        elif port_part == "*":
            port = None
        else:
            try:
                port = int(port_part)
            except ValueError:
                continue
        out.append((net, port))
    return out


def remote_target_allowed(host, port):
    """True iff (host, port) is permitted by REMOTE_ALLOW. host MUST be an IPv4
    literal (callers validate); a non-literal host is never allowed (no DNS
    rebinding). Empty allow-list denies everything (fail closed)."""
    if not REMOTE_ALLOW:
        return False
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    if ip.version != 4:               # IPv4 only for remote (matches the parser)
        return False
    try:
        p = int(port)
    except (TypeError, ValueError):
        return False
    for net, aport in REMOTE_ALLOW:
        if net is not None and (ip.version != net.version or ip not in net):
            continue
        if aport is not None and aport != p:
            continue
        return True
    return False


def _session_locked_props(props_text):
    """True iff `loginctl show-session` output describes an ACTIVE graphical seat
    session that is LOCKED (grd refuses to mirror a locked screen)."""
    d = {}
    for line in props_text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return (bool(d.get("Seat")) and d.get("Active") == "yes"
            and d.get("Type") in ("wayland", "x11") and d.get("LockedHint") == "yes")


def physical_session_locked():
    """Best-effort: is the active graphical seat session locked? Used ONLY to turn an
    opaque bridge transport failure into a clear message, so it FAILS OPEN (returns
    False) whenever the lock state cannot be determined — it never blocks a connection."""
    try:
        listed = subprocess.run(["loginctl", "list-sessions", "--no-legend"],
                                capture_output=True, text=True, timeout=3)
        for ln in listed.stdout.splitlines():
            parts = ln.split()
            if not parts:
                continue
            props = subprocess.run(
                ["loginctl", "show-session", parts[0],
                 "-p", "Type", "-p", "Active", "-p", "Seat", "-p", "LockedHint"],
                capture_output=True, text=True, timeout=3)
            if _session_locked_props(props.stdout):
                return True
    except (OSError, subprocess.SubprocessError, ValueError):
        return False
    return False

# Per-user isolated headless sessions (docs/KNOWN_ISSUES I29). The "isolated"
# scenario routes to the caller's OWN headless GNOME session on a loopback port,
# brought up on demand by edy-rdp-headless@<uid>.service, avoiding the broken
# 3390 greeter handover entirely.
HEADLESS_STATE_DIR = "/run/edy-rdp/headless"
HEADLESS_START_TIMEOUT = 90


def ensure_headless_session(uid):
    """Start (idempotently) the caller's per-user headless isolated session and
    return its {'PORT','USER','CRED'}. The unit is Type=oneshot and blocks until
    the RDP port is listening; a warm session returns at once. Requires the
    edy-relay -> edy-rdp-headless@ polkit grant (hardening/edy-rdp-headless.rules)."""
    unit = "edy-rdp-headless@%d.service" % uid
    try:
        subprocess.run(["systemctl", "start", unit], check=True,
                       timeout=HEADLESS_START_TIMEOUT,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as exc:
        # Prefer the human reason the start script publishes (e.g. the seat-desktop
        # refusal) over systemd's generic "Job for ... failed" boilerplate.
        reason = None
        try:
            with open(os.path.join(HEADLESS_STATE_DIR, "%d.err" % uid)) as fh:
                reason = fh.read().strip()
        except OSError:
            pass
        if reason:
            raise Refuse("isolated session refused: %s" % reason[:300])
        detail = (exc.stderr or b"").decode("utf-8", "replace")[:160]
        raise Refuse("could not start isolated session: %s" % (detail or exc))
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refuse("isolated session start failed: %s" % exc)
    env = {}
    try:
        with open(os.path.join(HEADLESS_STATE_DIR, "%d.env" % uid)) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    k, v = line.split("=", 1)
                    env[k] = v
    except OSError as exc:
        raise Refuse("isolated session state unreadable: %s" % exc)
    if not all(k in env for k in ("PORT", "USER", "CRED")):
        raise Refuse("isolated session state incomplete")
    return env


class DesktopSlots:
    """One active connection ('slot') per virtual desktop, keyed by uid+scenario.
    A new connection to an occupied desktop TAKES OVER: the previous connection is
    terminated and the caller reconnects to the SAME backing desktop (headless GNOME
    / physical seat), which persists across the handover. Enforces the "only one slot
    has access" rule and makes reconnects deterministic."""

    def __init__(self):
        self._by_key = {}
        self._lock = threading.Lock()

    def claim(self, key, conn):
        with self._lock:
            old = self._by_key.get(key)
            self._by_key[key] = conn
        if old is not None and old is not conn:
            log.info("desktop %s taken over by a new connection; terminating the previous slot", key)
            conn.trace("SLOT TAKEOVER desktop=%s: terminating previous conn#%d (uid=%d)",
                       key, old.cid, old.uid)
            try:
                old.terminate()
            except Exception:  # never let a takeover break the new connection
                pass

    def release(self, key, conn):
        with self._lock:
            if self._by_key.get(key) is conn:
                del self._by_key[key]


DESKTOP_SLOTS = DesktopSlots()


class SessionTokens:
    """The session table the plugin registers into. Each entry is a strong random
    desktop-session token BOUND to the registering uid (SO_PEERCRED), carried
    end-to-end as a `sessiontoken=` connect marker to link browser->relay->bridge
    traffic to one session (so a user's multiple connections are never confused) and
    to gate access:

      * `issue` mints a token for a uid plus a one-time CHALLENGE written to a
        root-only file. Only a Cockpit session that can elevate (open a superuser
        channel) can read that file — proving administrator mode SERVER-SIDE, not the
        cosmetic client check (KNOWN_ISSUES I4).
      * `elevate` flips admin=True once the plugin echoes that challenge back on the
        NORMAL (uid-bound) channel — so elevation is tied to the same user.
      * `check` gates a data connection: the presenting uid must equal the token's
        uid, so a leaked token is useless to anyone else (anti-hijack).

    Tokens are ephemeral (TTL) and in-memory only; a leaked token never survives a
    relay restart. secrets.token_urlsafe -> 256-bit tokens, 192-bit challenges."""

    TTL = 8 * 3600
    REG_DIR = "/run/edy-rdp/reg"

    def __init__(self):
        self._t = {}
        self._lock = threading.Lock()

    def issue(self, uid, now):
        token = secrets.token_urlsafe(32)
        challenge = secrets.token_urlsafe(24)
        chal_path = os.path.join(self.REG_DIR, secrets.token_urlsafe(12))
        try:
            os.makedirs(self.REG_DIR, exist_ok=True)
            os.chmod(self.REG_DIR, 0o700)
            # 0600, owned by the relay uid: readable only by root -> only a superuser
            # (elevated) Cockpit channel can fetch the challenge.
            fd = os.open(chal_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as fh:
                fh.write(challenge)
        except OSError as exc:
            log.warning("register: cannot write challenge file: %s", exc)
            chal_path = None
        with self._lock:
            self._t[token] = {"uid": uid, "admin": False, "created": now,
                              "challenge": challenge, "chal_path": chal_path}
        return token, chal_path

    def elevate(self, token, uid, challenge):
        with self._lock:
            e = self._t.get(token)
            ok = bool(e and e["uid"] == uid and e.get("challenge")
                      and secrets.compare_digest(str(e["challenge"]), str(challenge)))
            if ok:
                e["admin"] = True
                path = e.pop("chal_path", None)
                e["challenge"] = None
        if ok and path:
            try:
                os.unlink(path)
            except OSError:
                pass
        return ok

    def check(self, token, uid, now):
        with self._lock:
            e = self._t.get(token)
            if not e or e["uid"] != uid:
                return None
            if now - e["created"] > self.TTL:
                self._drop_locked(token)
                return None
            return {"uid": e["uid"], "admin": e["admin"], "created": e["created"]}

    def _drop_locked(self, token):
        e = self._t.pop(token, None)
        if e and e.get("chal_path"):
            try:
                os.unlink(e["chal_path"])
            except OSError:
                pass

    def sweep(self, now):
        with self._lock:
            for t in [t for t, e in self._t.items() if now - e["created"] > self.TTL]:
                self._drop_locked(t)


SESSION_TOKENS = SessionTokens()


class Connection:
    def __init__(self, client, uid, table, guacd_addr, admin_group):
        self.client = client
        self.uid = uid
        self.table = table
        self.guacd_addr = guacd_addr
        self.admin_group = admin_group
        self.guacd = None
        self.up_buf = ""    # client -> guacd
        self.down_buf = ""  # guacd -> client
        self.select_seen = False
        self.scenario = None
        self.uuid = None
        self.last_sync = None
        self._sockets_for_terminate = (client, None)  # (client, guacd) filled after connect
        self.arg_names = None
        self.allow_targets = None  # set of 'host:port' or None = allow all
        self.closed = False
        # per-connection FreeRDP3 bridge (xfreerdp3 -> Xvfb -> x11vnc); guacd dials
        # its loopback VNC. Torn down on disconnect; the backing desktop persists.
        self.bridge_key = None
        self.bridge_proc = None
        self._bridge_counted = False  # holds a per-uid bridge slot (released on close)
        self.desktop_id = None       # PRIMARY KEY of the virtual desktop (also the slot)
        self.desktop_created = None  # that desktop's creation time
        self.session_token = None    # end-to-end correlation/gate token (registered)
        self.session_token_admin = False
        self.remote_target = None    # browser-supplied "ip:port" for the remote scenario
        self.req_w = None
        self.req_h = None
        # tracing identity + data-plane op counters (summarized, not per-line)
        self.cid = next(_conn_counter)
        self.t_open = time.monotonic()
        self.ops_up = {}
        self.ops_down = {}

    # control-plane ops are traced line-by-line; everything else is counted
    _TRACE_UP = {"select", "connect", "size", "audio", "video", "image", "disconnect"}
    _TRACE_DOWN = {"args", "ready", "error", "disconnect", "name"}

    def trace(self, fmt, *args):
        trace_log.info("conn#%d uid=%d " + fmt, self.cid, self.uid, *args)

    def _count(self, table, op):
        table[op] = table.get(op, 0) + 1

    def terminate(self):
        """Force this connection down (control API 'terminate'). Closing the
        sockets unblocks the select loop, which then runs the graceful teardown."""
        self.closed = True
        for sock in self._sockets_for_terminate:
            try:
                if sock:
                    sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    # -- client -> guacd -----------------------------------------------------
    def _guard_upstream(self, elements):
        """Enforce policy on client->guacd instructions. Returns the (possibly
        unchanged) elements to forward, or None to drop, or raises Refuse."""
        op = elements[0] if elements else ""
        self._count(self.ops_up, op)
        if op in self._TRACE_UP and op != "connect":   # connect traced after rewrite
            self.trace("up %s %s", op, " ".join(elements[1:4]))
        if op == "select" and not self.select_seen:
            self.select_seen = True
            kind, val = classify_select(elements)
            if kind == "bad":
                self.trace("REFUSE malformed select: %s", val)
                raise Refuse("malformed select: %s" % val)
            if kind == "join":
                if not self.table.may_join(val, self.uid):
                    self.trace("REFUSE join of foreign session %s", val[:12])
                    raise Refuse("uid %d may not join session %s" % (self.uid, val[:12]))
                log.info("uid=%d rejoins own session %s", self.uid, val[:12])
                self.trace("join own session %s", val[:12])
            else:
                # New session. `val` is the protocol (rdp). The scenario is
                # carried later in connect args; the plugin also passes it via a
                # leading connection parameter we peek at connect time.
                log.info("uid=%d opens new %s session", self.uid, val)
        if op == "size" and len(elements) >= 3:
            try:
                self.req_w, self.req_h = int(elements[1]), int(elements[2])
            except ValueError:
                pass
        return elements

    def _peek_scenario_from_connect(self, elements):
        """On guacd's VNC `connect`, identify the scenario, start the per-connection
        FreeRDP3 bridge for it (xfreerdp3 -> Xvfb -> x11vnc), and rewrite the connect
        so guacd's VNC client dials the bridge's LOOPBACK VNC endpoint -- never grd
        directly. The RDP credential for xfreerdp3 comes from the relay for managed
        scenarios (isolated: the caller's OWN headless session) or from the browser
        (a stripped `rdpcred=` marker) for the rest, and reaches the bridge only via
        a 0600 file, never guacd. The explicit `scenario=` marker (plugin contract)
        is what the admin gate keys on, so it cannot be evaded by a hand-built
        client."""
        if not (elements and elements[0] == "connect"):
            return elements
        scenario = None
        rdpcred = None
        sessiontoken = None
        remotehost = None
        _markers = ("scenario=", "rdpcred=", "sessiontoken=", "remotehost=")
        while elements and any(elements[-1].startswith(p) for p in _markers):
            m = elements[-1]
            if m.startswith("scenario="):
                scenario = m.split("=", 1)[1]
            elif m.startswith("sessiontoken="):
                sessiontoken = m.split("=", 1)[1]
            elif m.startswith("remotehost="):
                remotehost = m.split("=", 1)[1]   # "<ip>:<port>", validated in _grd_target
            else:
                rdpcred = m.split("=", 1)[1]   # "<user>\x1f<pass>", stripped, never forwarded
            elements = elements[:-1]
        self.scenario = scenario
        self.remote_target = remotehost

        # Validate the registered desktop-session token (if present). It is BOUND to
        # the caller's uid, so a leaked token is useless to another user (anti-hijack,
        # I2); a token elevated via the superuser challenge marks admin (I4).
        if sessiontoken:
            tinfo = SESSION_TOKENS.check(sessiontoken, self.uid, time.time())
            if tinfo is None:
                self.trace("REFUSE invalid/foreign/expired session token")
                raise Refuse("invalid or expired session token; reload the page")
            self.session_token = sessiontoken
            self.session_token_admin = bool(tinfo.get("admin"))
            self.trace("session token OK admin=%s", self.session_token_admin)

        if rdpcred and "\x1f" in rdpcred:
            _cu, _cp = rdpcred.split("\x1f", 1)
            self.trace("up connect scenario=%s rdpcred user=%s password=<redacted:%d>",
                       scenario, _cu, len(_cp))
        else:
            self.trace("up connect scenario=%s (no client credential)", scenario)
        # remote RDP is optionally admin-gated (EDY_RDP_REMOTE_ADMIN_ONLY); console
        # is always admin-gated (I4). The gate keys on the SERVER-stripped scenario.
        admin_required = (scenario in ADMIN_ONLY_SCENARIOS
                          or (scenario == "remote" and REMOTE_ADMIN_ONLY))
        if admin_required:
            # PROVEN Cockpit administrator mode (the token was elevated via the
            # superuser challenge), not the cosmetic client check nor mere sudo-group
            # membership. is_admin(sudo) is accepted as a fallback ONLY for a
            # native/legacy caller that presents no session token at all.
            proven = self.session_token_admin
            fallback = (self.session_token is None
                        and is_admin(self.uid, self.admin_group))
            if not (proven or fallback):
                self.trace("REFUSE admin gate: scenario=%s token_admin=%s no fallback",
                           scenario, self.session_token_admin)
                raise Refuse("This scenario needs administrative access — turn on "
                             "Administrative access in Cockpit's header, then reconnect.")
            self.trace("admin gate PASSED for scenario=%s (proven=%s fallback=%s)",
                       scenario, proven, fallback)

        host, port, security, relay_cred, desktop_id, desktop_created = self._grd_target(scenario)
        if relay_cred is not None:
            username, password = relay_cred
            self.trace("target %s:%s security=%s cred=relay-managed user=%s "
                       "desktop=%s created=%s", host, port, security, username,
                       desktop_id, desktop_created)
        else:
            if not rdpcred or "\x1f" not in rdpcred:
                self.trace("REFUSE missing client credential for scenario=%s", scenario)
                raise Refuse("scenario %r needs an RDP credential" % scenario)
            username, password = rdpcred.split("\x1f", 1)
            self.trace("target %s:%s security=%s cred=client-supplied user=%s "
                       "desktop=%s", host, port, security, username, desktop_id)

        # The username/password are written VERBATIM into the newline-delimited bridge
        # .req file (bridge.py) and consumed by a KEY=VALUE shell loop. An embedded
        # newline/CR in a CLIENT-supplied credential could forge a HOST=/PORT=/SECURITY=
        # line and coerce the bridge into dialing an ARBITRARY host — SSRF that bypasses
        # the remote allow-list, and (via scenario=virtual/console, which also take a
        # client credential) escapes the loopback-only guarantee entirely. Reject any
        # newline/CR/NUL in either field before it can reach the .req.
        for _fld, _val in (("username", username), ("password", password)):
            if any(c in _val for c in ("\n", "\r", "\x00")):
                self.trace("REFUSE control character in RDP %s", _fld)
                raise Refuse("the RDP %s contains an illegal control character" % _fld)

        self.desktop_id = desktop_id
        self.desktop_created = desktop_created
        # Single-slot takeover: terminate any existing connection to THIS virtual
        # desktop (primary key = desktop_id) before bridging, so only one slot has
        # access and the backing grd session (one client at a time for headless) is
        # free for us. The desktop itself persists across the handover.
        DESKTOP_SLOTS.claim(desktop_id, self)

        # Bound per-uid resource use: refuse before spawning a bridge if this uid
        # already holds the maximum. Released in the teardown finally.
        if not BRIDGE_COUNTER.acquire(self.uid):
            self.trace("REFUSE bridge cap reached for uid=%d", self.uid)
            raise Refuse("too many concurrent sessions; disconnect one and retry")
        self._bridge_counted = True

        geom = "%dx%d" % (self.req_w or 1600, self.req_h or 1000)
        # bridge instance key is per-connection-unique (filesystem-safe) so a takeover
        # never collides with the outgoing connection's request/endpoint files.
        key = "%s-%d-%s" % (scenario or "rdp", self.uid, uuidlib.uuid4().hex[:8])
        try:
            info, proc = bridge.start_bridge(key, host, port, security,
                                             username, password, geom=geom)
        except bridge.BridgeError as exc:
            self.trace("bridge FAILED key=%s: %s", key, exc)
            # A locked physical screen makes grd refuse the mirror/virtual session
            # ("Session creation inhibited"), which the client only sees as an opaque
            # transport/broken-pipe error. If that is the case, say so plainly.
            if scenario in LOCAL_SEAT_SCENARIOS and physical_session_locked():
                self.trace("bridge FAILED with locked physical screen (scenario=%s)", scenario)
                raise Refuse("the physical screen is locked — unlock it on the machine "
                             "(or disable auto-lock), then reconnect.")
            raise Refuse("could not start desktop bridge: %s" % exc)
        self.bridge_key = key
        self.bridge_proc = proc
        log.info("uid=%d scenario=%s bridge %s:%s (%s) -> guacd VNC 127.0.0.1:%s",
                 self.uid, scenario, host, port, security, info.get("VNCPORT"))
        self.trace("bridge READY key=%s rdp=%s:%s security=%s geom=%s -> vnc=127.0.0.1:%s "
                   "vncpass=%s", key, host, port, security, geom, info.get("VNCPORT"),
                   "<redacted:%d>" % len(info.get("VNCPASS", "")) if info.get("VNCPASS") else "(none)")
        out = self._inject_vnc_target(elements, info)
        self.trace("up connect -> guacd(vnc): %s", redacted_params(self.arg_names, out[1:]))
        return out

    def _grd_target(self, scenario):
        """(host, port, security, relay_cred_or_None, desktop_id, desktop_created).
        relay_cred set => the RELAY supplies the RDP credential (managed isolated,
        from SO_PEERCRED); None => the browser supplies it (console/virtual/greeter
        gate key). desktop_id is the PRIMARY KEY of the virtual desktop this
        connection attaches to; the SAME id is reissued on reconnect to the same
        desktop, and it is the single-slot key."""
        if scenario == "console":
            # the single physical seat: one stable console desktop
            return ("127.0.0.1", "3389", "nla", None, "console:seat", None)
        if scenario == "virtual":
            # a per-user virtual monitor inside the user's 3389 session
            return ("127.0.0.1", "3389", "nla", None, "virtual:%d" % self.uid, None)
        if scenario == "greeter":
            # each GDM greeter is ephemeral -> a fresh id per connection
            return ("127.0.0.1", "3390", "rdstls", None,
                    "greeter:%s" % uuidlib.uuid4().hex[:12], None)
        if scenario == "isolated":
            info = ensure_headless_session(self.uid)
            did = info.get("DESKTOP_ID") or ("isolated:%d" % self.uid)
            created = info.get("CREATED")
            try:
                created = int(created) if created else None
            except (TypeError, ValueError):
                created = None
            return ("127.0.0.1", str(info["PORT"]), "nla",
                    (info["USER"], info["CRED"]), did, created)
        if scenario == "remote":
            # RDP into another host on the network. The target is BROWSER-supplied,
            # so this is the one path that can dial off-box -> it is fail-closed
            # against the admin-configured allow-list, and validated to an IPv4
            # literal (no hostnames -> no DNS rebinding of the CIDR check; no
            # metacharacters -> no bridge .req injection). relay_cred is None so the
            # user's OWN credential is used and NO relay-managed credential is ever
            # handed to a foreign host. This gate runs here, before DESKTOP_SLOTS
            # and start_bridge, so a denied target never dials out.
            host, port = self._parse_remote_target(self.remote_target)
            if not remote_target_allowed(host, port):
                self.trace("REFUSE remote target %s:%d not in allow-list", host, port)
                # Name the file this host actually reads, not the one a past
                # version read: an error that sends an administrator to edit a
                # file nothing loads is worse than one that names no file at all.
                raise Refuse("remote host %s:%d is not permitted; an administrator "
                             "must add it to EDY_RDP_REMOTE_ALLOW in %s"
                             % (host, port, _env_file_hint()))
            self.trace("remote target %s:%d permitted", host, port)
            # "negotiate": the bridge offers NLA+TLS (plain RDP-standard security
            # disabled) so the credential is never sent under weak RDP encryption --
            # Windows selects NLA, other RDP servers (e.g. xrdp) select TLS.
            return (host, str(port), "negotiate", None,
                    "remote:%s:%d:%d" % (host, port, self.uid), None)
        raise Refuse("unknown scenario %r" % scenario)

    def _parse_remote_target(self, spec):
        """Validate a browser-supplied remote target to a strict IPv4:port. Rejects
        hostnames (DNS-rebinding), IPv6/ambiguous colons, and any metacharacter or
        newline (the value is written as a KEY=VALUE line into the bridge .req file,
        so a newline could forge PASSWORD/SECURITY keys). Raises Refuse on anything off."""
        if not spec:
            raise Refuse("remote scenario needs a host (ip:port)")
        if any(c not in "0123456789.:" for c in spec):
            raise Refuse("invalid remote host: only an IPv4 address and port are allowed")
        host, sep, port = spec.rpartition(":")
        if not sep or not host or not port:
            raise Refuse("remote host must be in the form ip:port")
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            raise Refuse("remote host must be an IPv4 address")
        if ip.version != 4:
            raise Refuse("remote host must be IPv4")
        try:
            p = int(port)
        except ValueError:
            raise Refuse("remote port must be numeric")
        if not (1 <= p <= 65535):
            raise Refuse("remote port out of range")
        return str(ip), p

    def _inject_vnc_target(self, connect_elements, info):
        """Rewrite guacd's VNC `connect` to dial the bridge's loopback VNC endpoint.
        guacd advertised the VNC arg names in `args` (self.arg_names)."""
        if not self.arg_names:
            raise Refuse("guacd VNC args not seen")
        values = list(connect_elements[1:])
        if len(values) < len(self.arg_names):
            values += [""] * (len(self.arg_names) - len(values))
        params = dict(zip(self.arg_names, values))
        params["hostname"] = info["VNCHOST"]
        params["port"] = str(info["VNCPORT"])
        params["password"] = info.get("VNCPASS", "")
        return ["connect"] + [params.get(n, "") for n in self.arg_names]

    def _enforce_target(self, connect_elements):
        """Refuse a connect that would dial an RDP target outside the allow-list.
        Closes the arbitrary-target / SSRF-flavoured class (see docs/CVE.md): guacd
        connects to whatever host:port it is told, so the relay must constrain it.
        Maps connect values to the arg names guacd advertised, then checks
        hostname:port. If arg names are unknown or no allow-list is set, allow."""
        if not self.allow_targets or not self.arg_names:
            return
        # connect payload after the opcode lines up with arg_names positionally
        values = connect_elements[1:]
        params = dict(zip(self.arg_names, values))
        host = params.get("hostname", "")
        port = params.get("port", "")
        target = "%s:%s" % (host, port)
        if target not in self.allow_targets:
            raise Refuse("target %s not permitted" % target)

    # -- guacd -> client -----------------------------------------------------
    def _watch_downstream(self, elements):
        op = elements[0] if elements else ""
        self._count(self.ops_down, op)
        if op in self._TRACE_DOWN:
            if op == "args":
                self.trace("down args: %s", ",".join(elements[1:]))
            elif op == "error":
                self.trace("down ERROR: %s", " ".join(elements[1:]))
            else:
                self.trace("down %s %s", op, " ".join(elements[1:2]))
        if elements and elements[0] == "args":
            self.arg_names = elements[1:]
        if elements and elements[0] == "sync" and len(elements) >= 2:
            self.last_sync = elements[1]
        if elements and elements[0] == "ready" and len(elements) >= 2:
            uuid = elements[1].lstrip("$")   # normalize: joins arrive without the '$'
            self.uuid = uuid
            self.table.open(uuid, self.uid, self.scenario or "unknown", time.time(),
                            desktop_id=self.desktop_id,
                            desktop_created=self.desktop_created)
            self.table.mark_active(uuid, time.time())
            log.info("uid=%d session ready %s scenario=%s desktop=%s",
                     self.uid, uuid[:12], self.scenario, self.desktop_id)


class Refuse(Exception):
    pass


def _send_error_and_close(client, message):
    try:
        client.sendall(encode("error", message, "769").encode("utf-8"))
        client.sendall(encode("disconnect").encode("utf-8"))
    except OSError:
        pass
    try:
        client.close()
    except OSError:
        pass


def handle(client, table, live, guacd_addr, admin_group):
    try:
        _pid, uid, _gid = peer_credentials(client)
    except OSError as exc:
        log.warning("no peer credentials, refusing: %s", exc)
        client.close()
        return
    log.info("accept uid=%d (%s)", uid, _safe_username(uid))

    conn = Connection(client, uid, table, guacd_addr, admin_group)
    conn.allow_targets = ALLOW_TARGETS
    conn.trace("ACCEPT pid=%d user=%s -> guacd %s", _pid, _safe_username(uid), guacd_addr)
    try:
        conn.guacd = _connect_guacd(guacd_addr)
        conn._sockets_for_terminate = (client, conn.guacd)
    except OSError as exc:
        log.error("cannot reach guacd at %s: %s", guacd_addr, exc)
        _send_error_and_close(client, "backend unavailable")
        return

    sel = selectors.DefaultSelector()
    # Sockets stay BLOCKING: select tells us when to read, and blocking sendall
    # guarantees full writes (a non-blocking sendall silently drops on EAGAIN
    # when a greeter's initial frame burst overflows the send buffer, which
    # dropped both frames and sync echoes and killed the session ~29s in).
    sel.register(client, selectors.EVENT_READ, "client")
    sel.register(conn.guacd, selectors.EVENT_READ, "guacd")

    last_keepalive = time.monotonic()
    ready = False

    def on_up(elements):
        guarded = conn._guard_upstream(elements)
        guarded = conn._peek_scenario_from_connect(guarded)
        if guarded is not None:
            conn.guacd.sendall(encode(*guarded).encode("utf-8"))

    def on_down(elements):
        nonlocal ready
        conn._watch_downstream(elements)
        if elements and elements[0] == "sync" and len(elements) >= 2:
            # respond to guacd's liveness sync at once, independent of the browser
            try:
                conn.guacd.sendall(encode("sync", elements[1]).encode("utf-8"))
            except OSError:
                pass
        if elements and elements[0] == "ready":
            ready = True
            if conn.uuid:
                live.register(conn.uuid, conn.terminate)
        conn.client.sendall(encode(*elements).encode("utf-8"))

    try:
        while not conn.closed:
            for key, _mask in sel.select(timeout=1.0):
                who = key.data
                sock = key.fileobj
                try:
                    data = sock.recv(65536)
                except (BlockingIOError, InterruptedError):
                    continue
                if not data:
                    conn.closed = True
                    break
                text = data.decode("utf-8", "replace")
                if who == "client":
                    conn.up_buf = drain(conn.up_buf + text, on_up)
                else:
                    conn.down_buf = drain(conn.down_buf + text, on_down)
            # keepalive (I8): guacd drops a quiet client at ~18s
            now = time.monotonic()
            if ready and now - last_keepalive >= KEEPALIVE_SECONDS:
                try:
                    if conn.last_sync is not None:
                        conn.guacd.sendall(encode("sync", conn.last_sync).encode("utf-8"))
                    else:
                        conn.guacd.sendall(encode("nop").encode("utf-8"))
                except OSError:
                    conn.closed = True
                last_keepalive = now
    except Refuse as exc:
        log.warning("REFUSED uid=%d: %s", uid, exc)
        _send_error_and_close(client, str(exc))
    except OSError as exc:
        log.info("uid=%d connection ended: %s", uid, exc)
    finally:
        if conn.uuid:
            table.mark_disconnected(conn.uuid, time.time())
            live.unregister(conn.uuid)
        # Graceful teardown: tell guacd to disconnect the RDP session cleanly
        # BEFORE we drop the socket, so the backend disposes of its session
        # instead of seeing an abrupt transport close.
        try:
            if conn.guacd:
                conn.guacd.sendall(encode("disconnect").encode("utf-8"))
        except OSError:
            pass
        for s in (client, conn.guacd):
            try:
                if s:
                    s.close()
            except OSError:
                pass
        # Tear down the FreeRDP3 bridge for this connection. The backing desktop
        # (headless GNOME / physical seat) is independent and lives on, so a
        # reconnect re-bridges to the same desktop.
        if conn.bridge_proc:
            bridge.stop_bridge(conn.bridge_proc, conn.bridge_key)
            log.info("uid=%d bridge %s torn down", uid, conn.bridge_key)
        if conn.desktop_id:
            DESKTOP_SLOTS.release(conn.desktop_id, conn)
        if conn._bridge_counted:
            BRIDGE_COUNTER.release(conn.uid)
            conn._bridge_counted = False
        conn.trace("CLOSE after %.1fs session=%s desktop=%s up={%s} down={%s}",
                   time.monotonic() - conn.t_open,
                   (conn.uuid or "-")[:12], conn.desktop_id,
                   ",".join("%s:%d" % kv for kv in sorted(conn.ops_up.items())),
                   ",".join("%s:%d" % kv for kv in sorted(conn.ops_down.items())))
        log.info("close uid=%d", uid)


def _connect_guacd(addr):
    if isinstance(addr, str) and addr.startswith("unix:"):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(addr[len("unix:"):])
        return s
    host, port = addr
    s = socket.create_connection((host, port), timeout=15)
    return s


def _safe_username(uid):
    try:
        return _username(uid)
    except KeyError:
        return "?"


# ---------------------------------------------------------------------------
# Server bootstrap. Prefers systemd socket activation (LISTEN_FDS): systemd
# creates the AF_UNIX socket with the right owner/group/mode, which cleanly
# solves cross-namespace socket ownership. Falls back to binding directly.
# ---------------------------------------------------------------------------

SD_LISTEN_FDS_START = 3


def _peer_is_admin(conn, admin_group):
    try:
        _pid, uid, _gid = peer_credentials(conn)
    except OSError:
        return None, False
    return uid, is_admin(uid, admin_group)


def control_server(srv, table, live, admin_group, path_label=""):
    """Serve the management API (list/terminate) on an already-bound listener
    (systemd-activated so ownership/mode are handled by the socket unit)."""
    srv.setblocking(True)
    log.info("control API listening%s", (" on " + path_label) if path_label else "")

    def serve(conn):
        try:
            uid, admin = _peer_is_admin(conn, admin_group)
            if uid is None:
                conn.close(); return
            buf = b""
            conn.settimeout(10)
            while b"\n" not in buf:
                chunk = conn.recv(65536)
                if not chunk:
                    conn.close(); return
                buf += chunk
                if len(buf) > 65536:
                    break
            line = buf.split(b"\n", 1)[0].decode("utf-8", "replace")
            try:
                req = json.loads(line)
            except ValueError:
                resp = {"ok": False, "error": "invalid JSON"}
            else:
                resp = handle_control(req, uid, table, live, admin, SESSION_TOKENS)
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    while True:
        try:
            c, _ = srv.accept()
        except (InterruptedError, BlockingIOError):
            continue
        threading.Thread(target=serve, args=(c,), daemon=True).start()


def _systemd_sockets():
    """Return {name: socket} for systemd-activated fds (LISTEN_FDNAMES), or {}."""
    if os.environ.get("LISTEN_PID") != str(os.getpid()):
        return {}
    n = int(os.environ.get("LISTEN_FDS", "0"))
    if n < 1:
        return {}
    names = (os.environ.get("LISTEN_FDNAMES", "") or "").split(":")
    out = {}
    for i in range(n):
        fd = SD_LISTEN_FDS_START + i
        name = names[i] if i < len(names) and names[i] else ("fd%d" % i)
        sk = socket.fromfd(fd, socket.AF_UNIX, socket.SOCK_STREAM)
        sk.setblocking(True)
        out[name] = sk
    return out


def _bind_socket(path, group, mode):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    if group:
        if str(group).isdigit():
            gid = int(group)
        else:
            try:
                gid = grp.getgrnam(group).gr_gid
            except KeyError:
                log.warning("group %r not found; leaving socket group unchanged", group)
                gid = -1
        if gid != -1:
            # Only root can set the owner uid. When running unprivileged (e.g. a
            # --user deployment) keep our own uid and just fix the group if we can.
            owner = 0 if os.geteuid() == 0 else -1
            try:
                os.chown(path, owner, gid)
            except PermissionError:
                log.warning("cannot chgrp socket to %r as uid %d; relying on "
                            "directory perms for access control", group, os.geteuid())
    os.chmod(path, mode)
    s.listen(64)
    return s


def parse_guacd(spec):
    if spec.startswith("unix:"):
        return spec
    host, _, port = spec.rpartition(":")
    return (host or "127.0.0.1", int(port))


def main(argv=None):
    ap = argparse.ArgumentParser(description="edy-rdp guacd relay")
    ap.add_argument("--listen", default="/run/edy-rdp/guacd.sock",
                    help="AF_UNIX path (ignored under systemd socket activation)")
    ap.add_argument("--group", default="edy-rdp", help="socket group when self-binding")
    ap.add_argument("--mode", default="0660", help="socket mode when self-binding")
    ap.add_argument("--guacd", default="127.0.0.1:4822",
                    help="guacd endpoint: host:port or unix:/path (pod-internal)")
    ap.add_argument("--admin-group", default="sudo", help="group granting console access")
    ap.add_argument("--state-file", default="/run/edy-rdp/sessions.json",
                    help="persistent session registry (pruned by the reaper)")
    ap.add_argument("--control", default="/run/edy-rdp/control.sock",
                    help="management API AF_UNIX socket (list/terminate)")
    ap.add_argument("--allow-target", action="append", default=[],
                    help="host:port guacd may dial (repeatable). Empty = unrestricted. "
                         "Recommended: --allow-target host.containers.internal:3389 "
                         "--allow-target host.containers.internal:3390 ...:3391")
    ap.add_argument("--remote-allow", default="",
                    help="comma/space list of IPv4/CIDR[:port] hosts permitted for the "
                         "'remote' scenario (RDP into another host). Empty = deny all "
                         "(fail closed); 'any' = allow all; default port 3389, ':*' = any port.")
    ap.add_argument("--remote-admin-only", default="0",
                    help="1/true/yes/on => require proven Cockpit admin for the 'remote' scenario")
    ap.add_argument("--log-level", default="INFO")
    args = ap.parse_args(argv)

    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.INFO),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    guacd_addr = parse_guacd(args.guacd)
    global ALLOW_TARGETS, REMOTE_ALLOW, REMOTE_ADMIN_ONLY
    ALLOW_TARGETS = set(args.allow_target) or None
    REMOTE_ALLOW = parse_remote_allow(args.remote_allow)
    REMOTE_ADMIN_ONLY = str(args.remote_admin_only).strip().lower() in ("1", "true", "yes", "on")
    if REMOTE_ALLOW:
        log.info("remote scenario ENABLED: %d allow-list entr%s, admin_only=%s",
                 len(REMOTE_ALLOW), "y" if len(REMOTE_ALLOW) == 1 else "ies",
                 REMOTE_ADMIN_ONLY)
    else:
        log.info("remote scenario disabled (EDY_RDP_REMOTE_ALLOW empty = deny all)")
    table = SessionRegistry(args.state_file)
    live = LiveConnections()

    activated = _systemd_sockets()
    if activated:
        listener = activated.get("data") or next(iter(activated.values()))
        log.info("listening on systemd-activated data socket")
        ctl = activated.get("control")
        if ctl is not None:
            threading.Thread(target=control_server,
                             args=(ctl, table, live, args.admin_group, "control.sock"),
                             daemon=True).start()
        else:
            log.warning("no activated control socket; management API disabled")
    else:
        listener = _bind_socket(args.listen, args.group, int(args.mode, 8))
        log.info("listening on %s (group=%s mode=%s)", args.listen, args.group, args.mode)
        # self-bind control too (dev/--user path)
        try:
            cs = _bind_socket(args.control, args.group, int(args.mode, 8))
            threading.Thread(target=control_server,
                             args=(cs, table, live, args.admin_group, args.control),
                             daemon=True).start()
        except OSError as exc:
            log.warning("could not self-bind control socket %s: %s", args.control, exc)
    log.info("guacd endpoint: %s", args.guacd)

    while True:
        try:
            client, _ = listener.accept()
        except (InterruptedError, BlockingIOError):
            continue
        t = threading.Thread(target=handle,
                             args=(client, table, live, guacd_addr, args.admin_group),
                             daemon=True)
        t.start()


if __name__ == "__main__":
    sys.exit(main())
