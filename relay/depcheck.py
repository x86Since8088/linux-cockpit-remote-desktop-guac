# SPDX-License-Identifier: BSD-3-Clause
#
# depcheck.py — dependency tracking and native-rollback-where-available for
# THIS project's own OS prerequisites (requires.txt), plus a full installed-
# package inventory captured alongside them.
#
# Imported by BOTH the unprivileged relay (read-only status/history/list/
# blast-radius, served straight from JSON snapshots already on disk) and
# depcheck/edy-rdp-depsnapshot.py (the ROOT-run script that actually captures a
# snapshot at deploy time and performs the one real rollback primitive dnf/yum
# offers) — the same sys.path.insert + import idiom already used to share
# relay/bridge.py-style modules between the relay and a privileged helper, so
# there is one copy of the version-comparison logic and the requires.txt
# name-to-distro-package mapping, never two that could disagree.
#
# CONTRACT: nothing in this module ever runs a package-manager command (no
# rpm/dpkg-query/pacman/zypper/dnf/yum/apt-cache subprocess of any kind). Every
# function below either reads a file already on disk (a JSON snapshot,
# requires.txt, install.conf) or does pure in-memory computation. The actual
# host inspection — detecting the package manager, enumerating packages,
# walking dependencies, reading/undoing a dnf/yum transaction — happens ONLY in
# depcheck/edy-rdp-depsnapshot.py, run as root, only at deploy time (or at
# rollback time, through the privileged oneshot unit). The one exception is
# DepCheck.rollback(), which — exactly like DesktopUI.control() elsewhere in
# this project — starts that privileged unit via `systemctl start`; that is a
# write TRIGGER, not a package-manager
# query, and is the same mechanism this project already uses everywhere else
# a privilege boundary needs crossing.
#
# Tracking scope, stated plainly (product decision, not an oversight — see
# docs/KNOWN_ISSUES.md I64):
#   * the FULL installed-package inventory (name/version/arch) is captured
#     every snapshot.
#   * a real dependency GRAPH (requires / required-by) is captured ONLY for
#     the requires.txt tracked set — bounded, for cost reasons.
#   * rollback is a REAL, native transaction-undo on dnf/yum only. Every other
#     supported package manager (apt-get, pacman, zypper) gets an
#     informational, exact manual command per changed tracked package —
#     never executed by any part of this project.

import glob
import json
import os
import re
import socket
import subprocess
import time

INSTALL_CONF = "/etc/cockpit-guac-rdp/install.conf"
SNAPSHOT_DIRNAME = "dep-history"
TIMESTAMP_FMT = "%Y%m%dT%H%M%SZ"      # sorts lexically == chronologically
# What now_timestamp() actually produces -- load_snapshot()/list_snapshots()
# validate against this (never accepting a caller-supplied value that merely
# LOOKS like a filename) before ever building a path from it: deps-list's
# control-API op passes an authenticated caller's own request field straight
# through to here, and a "../" or absolute value must never be allowed to
# widen that into an arbitrary read of anything the relay user can see.
# [0-9], not \d (which also matches non-ASCII digit scripts under re.UNICODE,
# Python 3's default) -- and every call site below uses fullmatch(), not
# match()+anchors, since match() with a trailing "$" still accepts one
# trailing newline. Neither quirk is reachable as an actual path escape today
# (no "/" or "." can get through either way, and only root writes to
# dep-history/), but this is the one gate standing in front of an
# authenticated caller's own request field -- tighten it now rather than
# waiting for that to stop being true.
TIMESTAMP_RE = re.compile(r"[0-9]{8}T[0-9]{6}Z")
# The small companion file write_snapshot() writes beside each full snapshot,
# holding ONLY its "summary" dict -- named here, once, so the writer
# (depcheck/edy-rdp-depsnapshot.py) and the reader (list_snapshots() below)
# can never disagree on it.
SUMMARY_SUFFIX = ".summary.json"

ROLLBACK_UNIT = "edy-rdp-depcheck-rollback.service"
# The unit itself has no TimeoutStartSec cap any more (depsnapshot.py's own
# run_history_undo() is the single source of truth for how long a dnf/yum
# history undo may run, currently 600s) -- this must stay comfortably ABOVE
# that, never below it, or a slow-but-succeeding rollback gets reported here
# as a failure while the real dnf transaction keeps running to completion.
ROLLBACK_TIMEOUT = 700


def now_timestamp():
    return time.strftime(TIMESTAMP_FMT, time.gmtime())


# --- this host's install ------------------------------------------------------
#
# Read from /etc/cockpit-guac-rdp/install.conf, the same file
# relay/edy_rdp_relay.py (untouched by this feature) reads for the same
# reason — never resolved relative to this file's own __file__, which is a
# symlink into whichever payload happens to be current.


def _read_install_conf(key, path=INSTALL_CONF):
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        return None
    return None


def install_root():
    return _read_install_conf("INSTALL_PATH")


def requires_path():
    """Path to the CURRENTLY installed payload's requires.txt, from
    install.conf's own REQUIRES= field (install.sh writes it at every
    install/upgrade) — never a second, independently-resolved copy."""
    return _read_install_conf("REQUIRES")


def snapshot_dir(root=None):
    root = root if root is not None else install_root()
    return os.path.join(root, SNAPSHOT_DIRNAME) if root else None


# --- requires.txt (the tracked set) -------------------------------------------
#
# Port of lib/edy-rdp-requires.sh's req_load(), the plain "NAME >=MIN" half
# only — a `guacd-image` line is a pinned container reference, not an OS
# package, and is not part of the tracked set this feature watches.


_REQ_NAME_RE = re.compile(r'^[a-z][a-z0-9_.+-]*$')
_REQ_MIN_RE = re.compile(r'^[0-9][0-9.]*$')


def parse_requires(path):
    """[(name, minimum), ...] in file order, or [] if the file is missing or
    unreadable — this is a read-side convenience, not the authoritative parse
    (lib/edy-rdp-requires.sh's req_load() is, and it fails loudly on a
    malformed file elsewhere in this project; this one degrades quietly)."""
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                parts = line.split()
                if not parts or parts[0] == "guacd-image":
                    continue
                if len(parts) >= 2 and parts[1].startswith(">="):
                    name, minimum = parts[0], parts[1][2:]
                    if _REQ_NAME_RE.match(name) and _REQ_MIN_RE.match(minimum):
                        out.append((name, minimum))
    except OSError:
        return []
    return out


# --- versions ------------------------------------------------------------------
#
# Port of lib/edy-rdp-requires.sh's req_norm()/req_version_ge() comparison
# logic — reused rather than reimplemented, per the product decision that
# compliance must use the SAME "is this version new enough" rule the shell
# bootstrap already enforces, not a second one that could disagree.


_LEADING_EPOCH_RE = re.compile(r'^\d+:(.*)$')
_LEADING_NUMERIC_RE = re.compile(r'^\d+(\.\d+)*')


def norm_version(v):
    """The leading dotted-numeric part of a version string ("21.1.22-1ubuntu1"
    -> "21.1.22"), with a Debian epoch ("2:21.1.22-1ubuntu1") dropped first.
    "" when there is no numeric part at all. Never raises."""
    v = v or ""
    m = _LEADING_EPOCH_RE.match(v)
    if m:
        v = m.group(1)
    m = _LEADING_NUMERIC_RE.match(v)
    return m.group(0) if m else ""


def version_ge(have, minimum):
    """True iff norm(have) >= minimum (both dotted-numeric, minimum already
    bare — no '>=' prefix). Pads the shorter side with zeros first: a
    major-only version ("4") must not fail a minimum ("4.0") it meets."""
    have_n = norm_version(have)
    if not have_n:
        return False
    hc = [int(p) for p in have_n.split(".")]
    mc = [int(p) for p in (minimum or "0").split(".") if p != ""]
    if not mc:
        mc = [0]
    n = max(len(hc), len(mc))
    hc += [0] * (n - len(hc))
    mc += [0] * (n - len(mc))
    return hc >= mc


# --- package-manager detection + the requires.txt name -> distro package map -
#
# Ports of lib/edy-rdp-requires.sh's req_detect_pm() (exact check order:
# apt-get, dnf, yum, pacman, zypper) and req_pkg_for() (the SAME per-distro
# overrides, verified against lib/edy-rdp-requires.sh lines ~176-203 — freerdp
# and xvfb are the two names that actually differ from the canonical
# requires.txt name on at least one package manager). detect_pm() only checks
# PATH for the manager's OWN binary — it never invokes it, so it is not a
# "package-manager query" and is safe to share with the relay side too.

_PM_ORDER = ("apt-get", "dnf", "yum", "pacman", "zypper")

_PKG_FOR = {
    ("apt-get", "cockpit"): "cockpit cockpit-system",
    ("apt-get", "freerdp"): "freerdp3-x11",
    ("apt-get", "xvfb"): "xvfb",
    ("apt-get", "dbus"): "dbus-bin",
    ("dnf", "cockpit"): "cockpit cockpit-system",
    ("yum", "cockpit"): "cockpit cockpit-system",
    ("dnf", "freerdp"): "freerdp",
    ("yum", "freerdp"): "freerdp",
    ("dnf", "xvfb"): "xorg-x11-server-Xvfb",
    ("yum", "xvfb"): "xorg-x11-server-Xvfb",
    ("dnf", "dbus"): "dbus-tools",
    ("yum", "dbus"): "dbus-tools",
    ("pacman", "cockpit"): "cockpit",
    ("pacman", "freerdp"): "freerdp",
    ("pacman", "xvfb"): "xorg-server-xvfb",
    ("pacman", "python3"): "python",
    ("pacman", "dbus"): "dbus",
    ("zypper", "cockpit"): "cockpit cockpit-bridge",
    ("zypper", "freerdp"): "freerdp",
    ("zypper", "xvfb"): "xorg-x11-server-Xvfb",
    ("zypper", "dbus"): "dbus-1-tools",
}


def _which(cmd, path_env=None):
    for d in (path_env if path_env is not None else os.environ.get("PATH", "")).split(os.pathsep):
        if not d:
            continue
        p = os.path.join(d, cmd)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def detect_pm():
    """"" when none of the five is on PATH — same fallback as the shell's
    req_detect_pm(), never raises."""
    for pm in _PM_ORDER:
        if _which(pm):
            return pm
    return ""


def pkg_for(name, pm):
    """The distro package(s) (space-separated; only 'cockpit' is ever more
    than one) behind a canonical requires.txt name, for THIS package manager.
    Falls back to the canonical name unchanged for every name this table does
    not override (podman, x11vnc, nftables, gnome-remote-desktop: identical
    everywhere; python3 on everything but pacman)."""
    return _PKG_FOR.get((pm, name), name).split()


# --- snapshot JSON: read side (list/load) -------------------------------------
#
# One JSON file per snapshot, named <timestamp>.json, NEVER overwritten (the
# append-only history). write_snapshot() also writes a small companion
# <timestamp>.summary.json holding JUST that "summary" dict, so
# list_snapshots() never has to walk the (possibly large) "packages" array of
# every snapshot just to show one line per deploy -- genuinely cheap, not only
# in name (KNOWN_ISSUES I64 F4: json.load() cannot partially parse a single
# JSON document, so reading the full file to reach one small sub-object was no
# cheaper than reading everything in it).


def list_snapshots(directory):
    """[{timestamp, deploy_version, pkg_mgr, total_packages, tracked_count,
    noncompliant_count, changed_since_previous}, ...], NEWEST FIRST. A
    missing directory is an empty history, not an error (a host that has never
    deployed since this feature shipped). A corrupt/unreadable snapshot file
    is skipped, not fatal — one bad file must never hide the rest of a host's
    history."""
    if not directory or not os.path.isdir(directory):
        return []
    out = []
    for path in sorted(glob.glob(os.path.join(directory, "*.json")), reverse=True):
        if path.endswith(SUMMARY_SUFFIX):
            continue
        if not TIMESTAMP_RE.fullmatch(os.path.basename(path)[:-len(".json")]):
            continue  # not one of ours (KNOWN_ISSUES I64 F5) -- e.g. a stray notes.json
        summary_path = path[:-len(".json")] + SUMMARY_SUFFIX
        try:
            if os.path.isfile(summary_path):
                with open(summary_path, encoding="utf-8") as fh:
                    summary = json.load(fh)
            else:
                # A snapshot written before this companion file existed (or by
                # an older depsnapshot.py): fall back to the one slow read for
                # THIS entry only, rather than losing it from the history.
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
                summary = data.get("summary") if isinstance(data, dict) else None
        except (OSError, ValueError):
            continue
        if isinstance(summary, dict):
            out.append(dict(summary))
    return out


def _snapshot_path(directory, timestamp):
    # Callers MUST validate `timestamp` against TIMESTAMP_RE first (see
    # load_snapshot() below) -- this function does not, and deps-list's
    # control-API op passes an authenticated caller's own request field all
    # the way down to here.
    return os.path.join(directory, "%s.json" % timestamp)


def load_snapshot(directory, timestamp_or_latest="latest"):
    """The full parsed snapshot dict, or None when the directory, the file or
    its JSON is missing/unreadable, or `timestamp_or_latest` is neither
    "latest" nor a genuine now_timestamp()-shaped value. "latest" resolves to
    the lexically-greatest (== chronologically newest) filename on disk.
    KNOWN_ISSUES I64 F5/path-traversal: `deps-list` threads an authenticated
    caller's own request field straight through to here as
    `timestamp_or_latest` -- rejecting anything that doesn't match
    TIMESTAMP_RE before it ever reaches a path join is load-bearing, not
    cosmetic."""
    if not directory or not os.path.isdir(directory):
        return None
    if timestamp_or_latest == "latest":
        files = sorted(
            p for p in glob.glob(os.path.join(directory, "*.json"))
            if not p.endswith(SUMMARY_SUFFIX)
            and TIMESTAMP_RE.fullmatch(os.path.basename(p)[:-len(".json")])
        )
        if not files:
            return None
        path = files[-1]
    else:
        if not TIMESTAMP_RE.fullmatch(timestamp_or_latest or ""):
            return None
        path = _snapshot_path(directory, timestamp_or_latest)
        if not os.path.isfile(path):
            return None
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


# --- pure diff / blast-radius / rollback-hint ---------------------------------


def _pkg_key(p):
    # (name, arch) — NOT name alone. A multi-arch host (Debian/Ubuntu commonly
    # has both libfoo:amd64 and libfoo:i386 installed) has two genuinely
    # different packages sharing one name; keying by name alone silently
    # shadowed one of them (found while smoke-testing against this host's own
    # apt inventory: 2656 raw entries collapsed to ~2614 "unique" ones).
    return (p.get("name"), p.get("arch") or "")


def diff_snapshots(older, newer):
    """{"added":[pkg,...], "removed":[pkg,...],
    "changed":[{"name","arch","old_version","new_version","tracked"}],
    "unchanged_count": N} for two full snapshot dicts (their "packages"
    arrays). Pure — no I/O, no subprocess; independently unit-testable with
    two literal snapshot dicts. A missing "packages" list on either side reads
    as empty (an old or hand-built fixture), not an error."""
    older_pkgs = {_pkg_key(p): p for p in (older or {}).get("packages", []) if p.get("name")}
    newer_pkgs = {_pkg_key(p): p for p in (newer or {}).get("packages", []) if p.get("name")}
    added, removed, changed = [], [], []
    unchanged = 0
    for key, np in newer_pkgs.items():
        op = older_pkgs.get(key)
        if op is None:
            added.append(np)
        elif op.get("version") != np.get("version"):
            changed.append({"name": np.get("name"), "arch": np.get("arch"),
                            "old_version": op.get("version"), "new_version": np.get("version"),
                            "tracked": bool(np.get("tracked") or op.get("tracked"))})
        else:
            unchanged += 1
    for key, op in older_pkgs.items():
        if key not in newer_pkgs:
            removed.append(op)
    return {"added": added, "removed": removed, "changed": changed, "unchanged_count": unchanged}


def blast_radius(snapshot, package_name):
    """{"found": bool, "requires":[...], "required_by":[...],
    "required_by_unavailable": bool} from the snapshot's OWN captured
    tracked-dependency graph. Pure lookup, no I/O. Scoped to the tracked set
    (see module docstring) — a package_name outside it has nothing captured,
    and this reports that plainly rather than guessing at a full-system graph
    this project deliberately does not build.

    required_by_unavailable distinguishes "genuinely zero reverse dependents"
    from "the reverse-dependency check itself could not run" (no pactree on a
    pacman host, or a broken rpm/apt-cache query — see
    depcheck/edy-rdp-depsnapshot.py's own required_by_unavailable field on the
    tracked entry, KNOWN_ISSUES I64 F5/F7); without this, a failed check and a
    real "nothing depends on this" looked identical here and to callers."""
    tracked = (snapshot or {}).get("tracked", {})
    entry = tracked.get(package_name)
    if not isinstance(entry, dict):
        return {"found": False, "requires": [], "required_by": [],
                "required_by_unavailable": False}
    return {"found": True,
            "requires": list(entry.get("requires") or []),
            "required_by": list(entry.get("required_by") or []),
            "required_by_unavailable": bool(entry.get("required_by_unavailable"))}


def rollback_command_hint(pkg_mgr, package_name, old_version):
    """The exact, informational-only command an operator would type to revert
    ONE tracked package by hand — for a package manager with no native
    transaction-undo. NEVER executed by any part of this project (display
    only). None for dnf/yum, which get the real rollback path instead
    (DepCheck.rollback() / edy-rdp-depsnapshot.py's "rollback" subcommand)."""
    if pkg_mgr == "apt-get":
        return "apt-get install %s=%s" % (package_name, old_version)
    if pkg_mgr == "pacman":
        return ("pacman -U /var/cache/pacman/pkg/%s-%s-*.pkg.tar.zst"
                " # only if still cached; pacman keeps no other local downgrade path"
                % (package_name, old_version))
    if pkg_mgr == "zypper":
        return "zypper install %s=%s" % (package_name, old_version)
    return None


# --- systemctl exit-code plumbing (mirrors DesktopUI.control()'s idiom) -------


def _exec_main_status(unit, timeout=8):
    try:
        p = subprocess.run(["systemctl", "show", "-p", "ExecMainStatus", "--value", unit],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        return p.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


# --- the object the relay injects into handle_control() ----------------------
#
# Mirrors DesktopUI's shape: handle_control() keeps ALL the policy
# (any-authenticated-caller for the four reads, admin + typed-hostname confirm
# for the one write — the SAME confirmation pattern deskui's stop/disable
# already use) and calls through this object only for the data and the one
# write mechanism. Every method here is either a disk read or (rollback only)
# a `systemctl start` of the privileged unit — never a package-manager query.


class DepCheck:
    def __init__(self, root=None):
        self._root_override = root
        try:
            self.hostname = socket.gethostname() or os.uname().nodename
        except OSError:
            self.hostname = "this-host"

    def _dir(self):
        root = self._root_override if self._root_override is not None else install_root()
        return snapshot_dir(root) if root else None

    # -- read-only -------------------------------------------------------------
    def status(self):
        """Never fails — an empty/never-snapshotted host is a valid state, not
        an error, so this never raises and never needs an "ok" of its own."""
        hist = list_snapshots(self._dir())
        latest = hist[0] if hist else None
        pm = (latest or {}).get("pkg_mgr") or ""
        return {
            "tracking_available": bool(latest),
            "pkg_mgr": pm,
            "native_rollback_available": pm in ("dnf", "yum"),
            "total_packages": (latest or {}).get("total_packages"),
            "tracked_count": (latest or {}).get("tracked_count"),
            "noncompliant_count": (latest or {}).get("noncompliant_count"),
            "latest_timestamp": (latest or {}).get("timestamp"),
            "deploy_version": (latest or {}).get("deploy_version"),
            "snapshot_count": len(hist),
        }

    def history(self):
        return list_snapshots(self._dir())

    def list(self, snapshot="latest", tracked_only=False):
        """None when there is no install root or no such snapshot (handle_control
        turns that into a plain error response); a dict otherwise."""
        d = self._dir()
        if not d:
            return None
        snap = load_snapshot(d, snapshot)
        if snap is None:
            return None
        pkgs = snap.get("packages", [])
        if tracked_only:
            pkgs = [p for p in pkgs if p.get("tracked")]
        return {"timestamp": snap.get("timestamp"), "pkg_mgr": snap.get("pkg_mgr"),
                "deploy_version": snap.get("deploy_version"),
                "packages": pkgs, "tracked": snap.get("tracked", {})}

    def diff(self, a="previous", b="latest"):
        """Not wired to a control-API op in this pass (the product decision
        capped this feature at four read ops + one write op — see
        docs/KNOWN_ISSUES.md I64); kept as a real, independently-tested method
        because edy-rdp-depsnapshot.py's own "snapshot" subcommand calls
        diff_snapshots() directly (in-memory, before anything is written) to
        compute each new snapshot's own "changed_since_previous" summary
        field, and a future control op can reuse this exact method rather
        than a second copy of the lookup-and-diff plumbing."""
        d = self._dir()
        if not d:
            return None
        newer = load_snapshot(d, b)
        if newer is None:
            return None
        if a == "previous":
            hist = list_snapshots(d)
            idx = next((i for i, s in enumerate(hist) if s.get("timestamp") == newer.get("timestamp")), None)
            older = (load_snapshot(d, hist[idx + 1]["timestamp"])
                    if idx is not None and idx + 1 < len(hist) else None)
        else:
            older = load_snapshot(d, a)
        if older is None:
            return {"added": [], "removed": [], "changed": [], "unchanged_count": 0,
                    "note": "no earlier snapshot to compare against"}
        result = diff_snapshots(older, newer)
        result["pkg_mgr"] = newer.get("pkg_mgr")
        return result

    def blast_radius(self, package_name):
        d = self._dir()
        if not d:
            return None
        snap = load_snapshot(d, "latest")
        if snap is None:
            return None
        return blast_radius(snap, package_name)

    # -- write: gated by handle_control() (admin + typed-confirm live there,
    # same split as DesktopUI.control()); this method is the mechanism only.
    _ROLLBACK_EXIT_MESSAGES = {
        "2": "this host's package manager has no native rollback (only dnf/yum "
             "do) — see the manual command hint recorded for each changed "
             "tracked package instead",
        "3": "the latest dependency snapshot recorded no transaction to roll back — "
             "either nothing has been snapshotted yet, install_deps() made no dnf/yum "
             "change, or the latest snapshot is not a completed post-deploy one (a "
             "deploy may have aborted before it ran) — let a deploy finish, which "
             "records a proper post-deploy snapshot",
        "4": "a newer dnf/yum transaction exists on this host than the one "
             "recorded in the snapshot; refusing to guess which one to undo — "
             "take a fresh snapshot and see what changed",
        "5": "the dnf/yum history undo itself failed; this host needs a human",
    }

    def rollback(self):
        """(ok, detail). Starts the privileged, parameterless oneshot unit;
        the unit's own script re-detects the package manager and re-reads the
        latest snapshot itself (zero caller-influenced data crosses that
        boundary — same principle as DesktopUI.control() starting its own
        privileged unit)."""
        if not list_snapshots(self._dir()):
            return (False, "no dependency-snapshot history on this host yet; "
                           "nothing to roll back")
        try:
            subprocess.run(["systemctl", "start", ROLLBACK_UNIT], check=True,
                           timeout=ROLLBACK_TIMEOUT, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as exc:
            code = _exec_main_status(ROLLBACK_UNIT)
            detail = (exc.stderr or b"").decode("utf-8", "replace").strip()[:300]
            msg = self._ROLLBACK_EXIT_MESSAGES.get(code)
            return (False, msg or detail or ("dependency rollback failed (exit status %r)" % code))
        except (OSError, subprocess.TimeoutExpired) as exc:
            return (False, "dependency rollback failed: %s" % exc)
        return (True, "rolled back the most recent tracked-dependency change")
