#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
#
# edy-rdp-reaper — enforces the session-lifecycle policy on the host.
#
#   * Prunes the relay's session registry (removes stale/closed entries).
#   * Terminates GDM greeter logind sessions that have been disconnected for
#     >60s WITHOUT a logon (KNOWN_ISSUES I13; the "greeters closed after 60s
#     unless a logon occurred" requirement). A greeter that became a real user
#     session (logged_on) is left alone until the longer session TTL.
#
# Run periodically by edy-rdp-reaper.timer. Root is required to terminate
# other users' logind sessions. stdlib only.


# The payload is IMMUTABLE once deployed: nothing at runtime writes inside it,
# not a log, not a cache, not a __pycache__ (DEPLOY-CONTRACT section 1.3). This
# script is reached through a symlink in /usr/libexec/edy-rdp, and Python
# resolves that symlink for sys.path[0] - so without this line, importing the
# sibling modules writes bytecode into the deployed payload and into the libexec
# directory. Set BEFORE any project import, or the first one is already cached.
import sys
sys.dont_write_bytecode = True

import json
import os
import re
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from session_registry import GREETER_DISCONNECT_TTL


def _run(cmd, timeout=15):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=True).stdout
    except (subprocess.CalledProcessError, OSError):
        return ""


def greeter_sessions():
    """Return [(session_id, uid, user)] for gdm-greeter* sessions, parsed from the
    plain `loginctl list-sessions` table (this host's `-o json` returns nothing)."""
    out = _run(["loginctl", "list-sessions", "--no-pager"])
    rows = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[2].startswith("gdm-greeter"):
            rows.append((parts[0], parts[1], parts[2]))
    return rows


def session_age_seconds(sid):
    """Seconds since the session started, via its Timestamp property. Large on error
    so an unreadable session is treated as old (reapable) rather than immortal."""
    val = _run(["loginctl", "show-session", sid, "-p", "Timestamp", "--value"]).strip()
    # Timestamp is like 'Sat 2026-08-30 15:20:01 CDT'; fall back to monotonic if absent.
    mono = _run(["loginctl", "show-session", sid, "-p", "TimestampMonotonic", "--value"]).strip()
    if mono.isdigit():
        up = _run(["cat", "/proc/uptime"]).split()
        if up:
            try:
                now_mono_us = float(up[0]) * 1_000_000
                return max(0.0, (now_mono_us - int(mono)) / 1_000_000)
            except ValueError:
                pass
    return 1e9


def session_prop(sid, prop):
    return _run(["loginctl", "show-session", sid, "-p", prop, "--value"]).strip()


def reap_greeters(ttl=GREETER_DISCONNECT_TTL, dry_run=False):
    """Terminate seatless Class=greeter gdm-greeter* sessions older than ttl
    (RDP Remote-Login leftovers). NEVER reap:
      * a greeter that owns a Seat (physical GDM login screen on seat0)
      * manager / manager-early sessions (the greeter uid's user manager)
    Killing either blanks the local Ubuntu display."""
    reaped = 0
    seen_uids = set()
    for sid, uid, user in greeter_sessions():
        if session_prop(sid, "Seat"):
            continue
        if session_prop(sid, "Class") != "greeter":
            continue
        age = session_age_seconds(sid)
        if age < ttl:
            continue
        if dry_run:
            print("  DRY-RUN would reap greeter session %s (%s, age %.0fs)" % (sid, user, age))
        else:
            _run(["loginctl", "terminate-session", sid])
            print("  reaped greeter session %s (%s, age %.0fs)" % (sid, user, age))
        seen_uids.add(uid)
        reaped += 1
    # also stop the lingering user managers for those greeter uids
    for uid in seen_uids:
        if not dry_run:
            _run(["systemctl", "stop", "user@%s.service" % uid])
    return reaped


def _control_call(control_path, req):
    """Send one JSON request to the relay control socket; return the parsed reply
    dict, or None if the socket is unavailable or the reply is malformed. The
    relay is the SOLE writer of the registry, so all reaper actions on it go
    through here rather than editing the state file behind the relay's back."""
    buf = b""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(control_path)
        s.sendall((json.dumps(req) + "\n").encode())
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        s.close()
    except OSError as exc:
        print("  control socket unavailable (%s)" % exc)
        return None
    try:
        return json.loads(buf.decode("utf-8", "replace").splitlines()[0])
    except (ValueError, IndexError):
        return None


def prune_via_control(control_path, now, greeter_ttl):
    """Ask the relay to prune stale registry sessions. Returns the reaped entries,
    or [] if the control socket is unavailable (greeter reap still runs)."""
    resp = _control_call(control_path, {"op": "prune", "now": now, "greeter_ttl": greeter_ttl})
    if resp is None:
        print("  registry prune skipped: control socket unavailable")
        return []
    if not resp.get("ok"):
        print("  registry prune error: %s" % resp.get("error"))
        return []
    return resp.get("reaped", [])


# ---- per-user isolated headless sessions (I29) --------------------------------
HEADLESS_PORT_BASE = 33000
HEADLESS_UID_BASE = 1000


def _running_headless_uids():
    out = _run(["systemctl", "list-units", "edy-rdp-headless@*",
                "--no-legend", "--plain", "--state=active"])
    return [int(m.group(1)) for m in
            re.finditer(r"edy-rdp-headless@(\d+)\.service", out)]


def _port_has_connection(port):
    return (":%d " % port) in _run(["ss", "-tnH", "state", "established"])


def reap_idle_headless(control_path, dry_run=False):
    """Stop a user's headless GNOME session once it is idle: no live connection to
    its port AND no isolated session left in the registry. prune() has already
    removed entries idle > SESSION_DISCONNECT_TTL, so a recently-disconnected
    desktop is KEPT (reconnectable) while a long-idle one is torn down. Each
    gnome-shell is ~130 MB, so this reclaims real memory on a multi-user host."""
    resp = _control_call(control_path, {"op": "list"})
    if not resp or not resp.get("ok"):
        # FAIL-SAFE: with no registry view we cannot tell an idle desktop from a
        # reconnectable one. Reaping on ignorance would tear down desktops users
        # expect to resume — do nothing and let the next tick retry.
        print("  headless reap skipped: control list unavailable")
        return 0
    keep = set()
    for s in resp.get("sessions", []):
        if s.get("scenario") == "isolated":   # active OR recently disconnected
            keep.add(s.get("uid"))
    stopped = 0
    for uid in _running_headless_uids():
        if uid in keep:
            continue
        port = HEADLESS_PORT_BASE + uid - HEADLESS_UID_BASE
        if _port_has_connection(port):
            continue                              # a client is connected right now
        if dry_run:
            print("  DRY-RUN would stop idle headless session uid=%d" % uid)
        else:
            _run(["systemctl", "stop", "edy-rdp-headless@%d.service" % uid])
            print("  stopped idle isolated headless session uid=%d" % uid)
        stopped += 1
    return stopped


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="edy-rdp session reaper")
    ap.add_argument("--control", default="/run/edy-rdp/control.sock",
                    help="relay management socket; the registry is pruned via the "
                         "relay (the sole writer), not by editing the state file")
    ap.add_argument("--state-file", default=None,
                    help="deprecated/ignored: the relay owns the registry now")
    ap.add_argument("--greeter-ttl", type=int, default=GREETER_DISCONNECT_TTL)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    now = time.time()
    reaped = [] if args.dry_run else prune_via_control(args.control, now, args.greeter_ttl)
    for r in reaped:
        print("  registry prune: %s uid=%s scenario=%s (%s)" %
              (str(r.get("uuid"))[:12], r.get("uid"), r.get("scenario"), r.get("reason")))

    g = reap_greeters(ttl=args.greeter_ttl, dry_run=args.dry_run)
    h = reap_idle_headless(args.control, dry_run=args.dry_run)
    print("reaper: pruned %d registry entries, terminated %d greeters, "
          "stopped %d idle headless sessions" % (len(reaped), g, h))
    return 0


if __name__ == "__main__":
    sys.exit(main())
