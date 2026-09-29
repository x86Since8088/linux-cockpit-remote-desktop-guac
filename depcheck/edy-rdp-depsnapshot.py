#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
#
# edy-rdp-depsnapshot — the actual, privileged, ROOT-run mechanics behind
# dependency tracking: "snapshot" captures this host's full installed-package
# inventory plus a bounded dependency graph for the requires.txt tracked set;
# "rollback" undoes the most recent dnf/yum transaction, and ONLY on dnf/yum
# (see module docstring in relay/depcheck.py for why every other supported
# package manager gets a manual command hint instead of an automated rollback).
#
# "snapshot" is invoked directly, with arguments, by deploy.sh itself (root,
# already running this script inline — not through a systemd unit, so this is
# the same trust level as deploy.sh calling install.sh with arguments
# elsewhere in this project). "rollback" is invoked with NO arguments at all,
# through the parameterless edy-rdp-depcheck-rollback.service oneshot unit —
# the same parameterless-privileged-unit shape edy-rdp-rotate-rdplogin.service.in
# already establishes elsewhere in this project (see
# systemd/edy-rdp-depcheck-rollback.service.in): it re-detects the package
# manager and re-reads the latest snapshot ITSELF, trusting nothing about
# "which transaction" from any caller. Zero caller-influenced data crosses
# that `systemctl start` boundary.
#
# Exit codes for "rollback" (mirrors DesktopUI.control()'s own ExecMainStatus
# idiom and exit-code convention in relay/edy_rdp_relay.py):
#   0 = rolled back
#   2 = refused: this host's package manager is not dnf/yum (informational-only
#       path — the manual command hints already in the snapshot data are what
#       an operator uses instead)
#   3 = refused: no dnf/yum transaction id on record to undo -- nothing has ever
#       been snapshotted, the latest snapshot on disk is not a completed
#       "after" snapshot (a deploy may have aborted before writing one), or
#       the "after" snapshot's own install_deps() caused no new transaction to
#       attribute one to — see attributable_transaction_id()
#   4 = refused: a NEWER dnf/yum transaction exists on this host than the one
#       recorded in the snapshot (stale snapshot; refusing to guess — it could
#       otherwise undo something unrelated, including a security patch)
#   5 = the `dnf history undo`/`yum history undo` itself failed — a human is
#       needed
# "snapshot" is best-effort from deploy.sh's point of view (a failure here must
# never fail a deploy — see deploy.sh's own run_depsnapshot()), so it just uses
# 0/1.

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import depcheck as DC  # noqa: E402  (see the sys.path.insert above)


def log(msg):
    print("[depsnapshot] %s" % msg, flush=True)


def die(msg, code):
    print("[depsnapshot] %s" % msg, file=sys.stderr, flush=True)
    sys.exit(code)


def _run(argv, timeout=60):
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def _run_with_stderr(argv, timeout=60):
    """Like _run(), but also returns stderr text -- needed only where a
    non-zero exit is ambiguous (see _rpm_whatrequires()/_apt_whatrequires())
    and telling "genuinely nothing" from "the query itself failed" needs more
    than the return code alone."""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return 1, "", ""


def _which(cmd):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if not d:
            continue
        p = os.path.join(d, cmd)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


# --- full inventory, per package manager --------------------------------------
#
# dnf/yum/zypper are all rpm-based (verified: zypper's own package database IS
# rpm's — see docs/COMPATIBILITY.md), so all three share ONE inventory query.


def _inventory_rpm():
    rc, out = _run(["rpm", "-qa", "--qf", "%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n"])
    pkgs = []
    if rc == 0:
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) == 3 and parts[0]:
                pkgs.append({"name": parts[0], "version": parts[1], "arch": parts[2]})
    return pkgs


def _inventory_dpkg():
    rc, out = _run(["dpkg-query", "-W", "-f=${Package}\t${Version}\t${Architecture}\n"])
    pkgs = []
    if rc == 0:
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) == 3 and parts[0]:
                pkgs.append({"name": parts[0], "version": parts[1], "arch": parts[2]})
    return pkgs


_PACMAN_KEY_RE = re.compile(r'^([A-Za-z][A-Za-z ]*?)\s*:\s?(.*)$')


def _inventory_pacman_and_deps():
    """pacman -Qi lists an info block for EVERY installed package in one call —
    cheaper than one `pacman -Qi <pkg>` per tracked package — so the "Depends
    On" field for the (bounded) tracked set is captured here, once, alongside
    the inventory, rather than re-querying pacman later."""
    rc, out = _run(["pacman", "-Qi"])
    pkgs, depends_on = [], {}
    if rc != 0:
        return pkgs, depends_on
    block, cur_key = {}, None

    def flush():
        name = block.get("Name")
        if not name:
            return
        pkgs.append({"name": name, "version": block.get("Version", ""),
                    "arch": block.get("Architecture", "")})
        raw = block.get("Depends On", "")
        depends_on[name] = [] if raw in ("", "None") else [
            re.split(r'[<>=]', tok)[0].strip() for tok in raw.split() if tok.strip()
        ]

    for line in out.splitlines():
        if not line.strip():
            flush()
            block, cur_key = {}, None
            continue
        m = _PACMAN_KEY_RE.match(line) if not line.startswith(" ") else None
        if m:
            cur_key = m.group(1).strip()
            block[cur_key] = m.group(2).strip()
        elif cur_key:
            block[cur_key] += " " + line.strip()
    flush()
    return pkgs, depends_on


def gather_inventory(pm):
    """(packages, ctx) — ctx carries package-manager-specific data the
    dependency-lookup functions below need without re-querying (pacman's
    already-parsed "Depends On" map)."""
    if pm in ("dnf", "yum", "zypper"):
        return _inventory_rpm(), {}
    if pm == "apt-get":
        return _inventory_dpkg(), {}
    if pm == "pacman":
        pkgs, deps_on = _inventory_pacman_and_deps()
        return pkgs, {"depends_on": deps_on}
    return [], {}


# --- direct dependencies (tracked set only) -----------------------------------


def _rpm_requires(pkg):
    rc, out = _run(["rpm", "-q", "--requires", pkg])
    if rc != 0:
        return []
    names = []
    for line in out.splitlines():
        tok = line.strip().split()[0] if line.strip() else ""
        # rpmlib(...)/config(...) are internal rpm pseudo-capabilities, not
        # real packages -- everything else (including a libfoo.so() soname
        # capability) is genuinely what rpm records as this package's
        # dependency and is kept as-is.
        if tok and not tok.startswith("rpmlib(") and not tok.startswith("config("):
            names.append(tok)
    return sorted(set(names))


def _rpm_whatrequires(pkg):
    """None means "unavailable" -- the same signal _pacman_whatrequires()
    already gives when its tool is missing (KNOWN_ISSUES I51 F7). rpm's exit
    code 1 is BOTH the documented, normal result for "nothing requires this
    package" AND what a missing rpm binary, a corrupt rpmdb or a permission
    error produces; collapsing both to [] would silently report "nothing
    depends on this" when the check actually just failed. A real failure
    prints to stderr; the normal empty-result case does not."""
    if _which("rpm") is None:
        return None
    rc, out, err = _run_with_stderr(["rpm", "-q", "--whatrequires", pkg, "--qf", "%{NAME}\n"])
    if rc != 0:
        return None if err.strip() else []
    return sorted(set(line.strip() for line in out.splitlines() if line.strip()))


def _dpkg_requires(pkg):
    rc, out = _run(["dpkg", "-s", pkg])
    if rc != 0:
        return []
    deps = []
    for line in out.splitlines():
        if line.startswith("Depends:"):
            for alt in line[len("Depends:"):].split(","):
                first = alt.split("|")[0].strip()
                name = re.sub(r'\(.*?\)', '', first).split()[0] if first.split() else ""
                if name:
                    deps.append(name)
    return sorted(set(deps))


def _apt_whatrequires(pkg):
    """None means "unavailable" -- same distinction as _rpm_whatrequires()
    above (KNOWN_ISSUES I51 F7): apt-cache exits 0 with an empty
    "Reverse Depends:" block for the normal "nothing depends on this"
    case, so a non-zero exit here means the query itself failed (a missing
    binary is already ruled out by the _which() check below), and stderr
    text tells that apart from a same-shaped-but-silent failure."""
    if _which("apt-cache") is None:
        return None
    rc, out, err = _run_with_stderr(["apt-cache", "rdepends", pkg])
    if rc != 0:
        return None if err.strip() else []
    deps, started = [], False
    for line in out.splitlines():
        if line.strip() == "Reverse Depends:":
            started = True
            continue
        if not started:
            continue
        name = line.strip().lstrip("|").split()[0] if line.strip() else ""
        if name:
            deps.append(name)
    return sorted(set(deps))


def _pacman_whatrequires(pkg):
    """None means "unavailable" (no pactree on this host) -- a bounded reverse
    scan is allowed to say so rather than fail the whole snapshot."""
    if _which("pactree") is None:
        return None
    rc, out = _run(["pactree", "-r", "-l", pkg])
    if rc != 0:
        return []
    return sorted(set(line.strip() for line in out.splitlines() if line.strip() and line.strip() != pkg))


_PKGLIST_TOKEN_RE = re.compile(r'[,\s]+')


def _zypper_requires(pkg):
    """zypper's own CLI has no clean machine-readable "just the direct
    dependency names" query (unlike rpm --qf); this parses the human-readable
    `zypper info --requires` block, which is what the product decision named
    explicitly. Best-effort: a parse failure or format change on some zypper
    version yields an empty list, never a crash."""
    rc, out = _run(["zypper", "--non-interactive", "info", "--requires", pkg])
    if rc != 0:
        return []
    deps, in_requires = [], False
    for line in out.splitlines():
        if re.match(r'^Requires\s*:', line):
            in_requires = True
            rest = line.split(":", 1)[1].strip()
            if rest:
                deps.extend(_split_pkg_tokens(rest))
            continue
        if in_requires:
            if not line.strip() or re.match(r'^[A-Za-z][A-Za-z ]*:\s', line):
                in_requires = False
                continue
            deps.extend(_split_pkg_tokens(line))
    return sorted(set(deps))


def _split_pkg_tokens(s):
    out = []
    for tok in _PKGLIST_TOKEN_RE.split(s.strip()):
        tok = tok.strip("-* ")
        name = re.split(r'[<>=]', tok)[0].strip()
        if name:
            out.append(name)
    return out


def make_dep_fns(pm, ctx):
    """(forward_fn, reverse_fn), each package-name -> list[str] (or None from
    the reverse fn to mean "unavailable")."""
    if pm in ("dnf", "yum"):
        return _rpm_requires, _rpm_whatrequires
    if pm == "zypper":
        # zypper's own package database IS rpm's -- the cheap, direct
        # `rpm -q --whatrequires` reverse-lookup applies here exactly as it
        # does on dnf/yum; only the FORWARD query goes through zypper itself.
        return _zypper_requires, _rpm_whatrequires
    if pm == "apt-get":
        return _dpkg_requires, _apt_whatrequires
    if pm == "pacman":
        depends_on = ctx.get("depends_on", {})
        return (lambda pkg: list(depends_on.get(pkg, []))), _pacman_whatrequires
    return (lambda pkg: []), (lambda pkg: [])


# --- dnf/yum transaction history ----------------------------------------------


def get_latest_transaction_id(pm):
    """The newest dnf/yum history transaction id on this host RIGHT NOW, or
    None if it cannot be determined. Tries --json first (modern dnf/yum);
    falls back to the plain table (older versions do not support --json)."""
    rc, out = _run([pm, "history", "list", "--json"])
    if rc == 0 and out.strip():
        try:
            data = json.loads(out)
        except ValueError:
            data = None
        if data is not None:
            entries = data if isinstance(data, list) else (
                data.get("transactions") or data.get("history") or [])
            ids = []
            for e in entries:
                if isinstance(e, dict) and "id" in e:
                    try:
                        ids.append(int(e["id"]))
                    except (TypeError, ValueError):
                        pass
            if ids:
                return str(max(ids))
    rc, out = _run([pm, "history", "list"])
    if rc != 0:
        return None
    ids = [int(m.group(1)) for m in (re.match(r'^\s*(\d+)\s*\|', line) for line in out.splitlines()) if m]
    return str(max(ids)) if ids else None


def run_history_undo(pm, tx_id, timeout=600):
    try:
        p = subprocess.run([pm, "history", "undo", tx_id, "-y"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return p.returncode == 0, p.stdout.decode("utf-8", "replace")[-4000:]
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)


# --- "snapshot" ----------------------------------------------------------------


def build_tracked(pm, req_list, inv_by_name, ctx):
    forward_fn, reverse_fn = make_dep_fns(pm, ctx)
    tracked, tracked_names = {}, set()
    for name, minimum in req_list:
        candidates = DC.pkg_for(name, pm)
        tracked_names.update(candidates)
        distro_pkg, installed_version = None, None
        for cand in candidates:
            hit = inv_by_name.get(cand)
            if hit is not None:
                distro_pkg, installed_version = cand, hit["version"]
                break
        present = installed_version is not None
        compliant = present and DC.version_ge(installed_version, minimum)
        requires = forward_fn(distro_pkg) if distro_pkg else []
        required_by = reverse_fn(distro_pkg) if distro_pkg else []
        tracked[name] = {
            "distro_pkg": distro_pkg,
            "distro_pkg_candidates": candidates,
            "installed_version": installed_version,
            "minimum_version": minimum,
            "present": present,
            "compliant": compliant,
            "requires": requires,
            "required_by": required_by if required_by is not None else [],
            "required_by_unavailable": required_by is None,
        }
    return tracked, tracked_names


def _write_json_atomic(path, data):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=1, sort_keys=True)
            fh.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise RuntimeError("could not write %s: %s" % (path, exc))


def write_snapshot(dep_dir, timestamp, data):
    try:
        os.makedirs(dep_dir, exist_ok=True)
        os.chmod(dep_dir, 0o755)
    except OSError as exc:
        raise RuntimeError("could not create %s: %s" % (dep_dir, exc))
    path = os.path.join(dep_dir, "%s.json" % timestamp)
    _write_json_atomic(path, data)
    # The small companion relay/depcheck.py's list_snapshots() actually reads
    # (KNOWN_ISSUES I51 F4) -- written AFTER the full snapshot so a reader
    # never sees a summary for a snapshot whose full file is not there yet.
    summary_path = os.path.join(dep_dir, "%s%s" % (timestamp, DC.SUMMARY_SUFFIX))
    _write_json_atomic(summary_path, data.get("summary") or {})


def attributable_transaction_id(pm, install_tx, label):
    """The dnf/yum transaction id to record in THIS snapshot's
    dnf_transaction_id field, or None. This is the ONLY field cmd_rollback()
    may ever read (it additionally requires label == "after" itself, as
    defense in depth against exactly this function ever being bypassed) --
    "before" and unlabeled snapshots never get a value here at all, only a
    purely informational baseline_transaction_id (see cmd_snapshot()).

    `install_tx` is THIS SAME deploy.sh run's own install_deps() bracketing
    itself tightly around its one package-manager invocation and observing
    a NEW transaction id appear (--install-tx, see deploy.sh's
    depsnapshot_current_tx()) -- deliberately NOT inferred by comparing this
    snapshot's own "current" transaction reading against some OTHER
    snapshot's (an earlier bdd7c45-era design did exactly that, comparing
    against "whatever 'latest' happens to be on disk"; the window between
    install_deps() finishing and an "after" snapshot actually running, at the
    very end of deploy.sh, can contain unrelated dnf/yum activity -- an
    image pull's own package operations, a concurrent operator command, an
    unattended-upgrades run -- that a coarser comparison would misattribute
    to install_deps() (KNOWN_ISSUES I51 F3)). If install_tx is unknown
    (install_deps() never ran, or created no new transaction), refuse to
    attribute rather than guess: an "after" snapshot with no recorded
    transaction just means rollback has nothing to undo yet (safe);
    misattributing an unrelated transaction is not."""
    if pm not in ("dnf", "yum") or label != "after":
        return None
    return install_tx or None


def cmd_snapshot(args):
    pm = DC.detect_pm()
    dep_dir = DC.snapshot_dir(args.root)
    inv, ctx = gather_inventory(pm)
    inv_by_name = {p["name"]: p for p in inv}
    req_list = DC.parse_requires(args.requires)
    tracked, tracked_names = build_tracked(pm, req_list, inv_by_name, ctx)
    for p in inv:
        p["tracked"] = p["name"] in tracked_names
    prev = DC.load_snapshot(dep_dir, "latest")
    # Purely informational -- "whatever dnf/yum transaction is newest at THIS
    # snapshot's own moment", shown in history/diagnostics. Never used to
    # decide what rollback may undo; see attributable_transaction_id().
    baseline_tx = get_latest_transaction_id(pm) if pm in ("dnf", "yum") else None
    dnf_tx = attributable_transaction_id(pm, args.install_tx, args.label)
    timestamp = DC.now_timestamp()
    noncompliant = sum(1 for t in tracked.values() if not t["compliant"])

    snapshot = {
        "schema_version": 1,
        "timestamp": timestamp,
        "deploy_version": args.deploy_version,
        "label": args.label or None,
        "pkg_mgr": pm,
        "dnf_transaction_id": dnf_tx,
        "baseline_transaction_id": baseline_tx,
        "packages": inv,
        "tracked": tracked,
    }
    changed_since_previous = prev is None
    if prev is not None:
        d = DC.diff_snapshots(prev, snapshot)
        changed_since_previous = bool(d["added"] or d["removed"] or d["changed"])
    snapshot["summary"] = {
        "timestamp": timestamp,
        "deploy_version": args.deploy_version,
        "pkg_mgr": pm,
        "total_packages": len(inv),
        "tracked_count": len(tracked),
        "noncompliant_count": noncompliant,
        "changed_since_previous": changed_since_previous,
    }
    write_snapshot(dep_dir, timestamp, snapshot)
    log("snapshot %s written: %d packages, %d tracked (%d noncompliant), pkg_mgr=%s%s"
        % (timestamp, len(inv), len(tracked), noncompliant, pm or "none detected",
           " (dnf tx=%s)" % dnf_tx if dnf_tx else ""))
    return 0


def cmd_current_tx():
    """Cheap, standalone: pm detection + one history query, no inventory
    scan. deploy.sh's install_deps() calls this twice, bracketing its own
    package-manager invocation tightly, to compute --install-tx precisely
    (see attributable_transaction_id() for why that precision matters)."""
    pm = DC.detect_pm()
    tx = get_latest_transaction_id(pm) if pm in ("dnf", "yum") else None
    print("CURRENT_TX=%s" % (tx or ""), flush=True)
    return 0


# --- "rollback" ------------------------------------------------------------


def cmd_rollback():
    root = DC.install_root()
    if not root:
        die("could not determine this host's install path (%s missing or unreadable)"
            % DC.INSTALL_CONF, 3)
    pm = DC.detect_pm()          # re-detected FRESH -- never trusted from the snapshot
    if pm not in ("dnf", "yum"):
        die("this host's package manager (%s) has no native rollback -- only dnf/yum "
            "do. See the manual command hint recorded for each changed tracked package "
            "in the snapshot data instead." % (pm or "none detected"), 2)
    dep_dir = DC.snapshot_dir(root)
    snap = DC.load_snapshot(dep_dir, "latest")
    if not snap:
        die("no dependency-snapshot history on this host yet; nothing to roll back", 3)
    # Defense in depth, on top of attributable_transaction_id() only ever
    # setting dnf_transaction_id for an "after" snapshot in the first place:
    # if the newest snapshot on disk is anything else (a deploy aborted, or
    # was interrupted, before its own "after" snapshot ran; an admin
    # triggered rollback mid-deploy), its dnf_transaction_id must never be
    # trusted even if somehow present -- it was never verified to have been
    # caused by THIS host's own install_deps().
    if snap.get("label") != "after":
        die("the latest dependency snapshot on this host is labeled %r, not a completed "
            "'after' snapshot -- refusing to guess what to undo (a deploy may have aborted "
            "before its 'after' snapshot ran). Let a deploy finish, or take a fresh snapshot, "
            "before rolling back." % (snap.get("label") or "(none)"), 3)
    tx_id = snap.get("dnf_transaction_id")
    if not tx_id:
        die("the latest snapshot recorded no %s transaction id to undo" % pm, 3)
    current_tx = get_latest_transaction_id(pm)
    if current_tx is None:
        die("could not read this host's current %s transaction history" % pm, 4)
    if str(current_tx) != str(tx_id):
        die("a newer %s transaction (%s) exists on this host than the one recorded in "
            "the latest snapshot (%s) -- refusing to guess which one to undo (this could "
            "otherwise revert something unrelated, including a security patch). Take a "
            "fresh snapshot and see what actually changed." % (pm, current_tx, tx_id), 4)
    ok, output = run_history_undo(pm, tx_id)
    if not ok:
        die("%s history undo %s failed:\n%s" % (pm, tx_id, output), 5)
    log("%s history undo %s completed" % (pm, tx_id))
    return 0


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="edy-rdp dependency snapshot / rollback")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("snapshot", help="capture a dependency/inventory snapshot")
    sp.add_argument("--root", required=True, help="install root (dep-history/ lives under it)")
    sp.add_argument("--requires", required=True, help="path to requires.txt to parse")
    sp.add_argument("--deploy-version", required=True, help="this project's VERSION being deployed")
    sp.add_argument("--label", default="", choices=["", "before", "after"],
                    help="which half of the deploy.sh run took this snapshot (metadata only)")
    sp.add_argument("--install-tx", default=None,
                    help="the exact dnf/yum transaction id THIS SAME deploy.sh run's own "
                         "install_deps() was observed to create, bracketed tightly around "
                         "its own package-manager invocation (see deploy.sh's "
                         "depsnapshot_current_tx()) -- only meaningful with --label after; "
                         "never inferred by comparing against some other snapshot's own "
                         "transaction reading (KNOWN_ISSUES I51 F3)")

    sub.add_parser("current-tx", help="print this host's current dnf/yum transaction id "
                   "(pm detection + one cheap history query, no inventory scan)")

    sub.add_parser("rollback", help="undo the most recent dnf/yum transaction (dnf/yum only)")

    args = ap.parse_args(argv)
    if args.cmd == "snapshot":
        try:
            return cmd_snapshot(args)
        except RuntimeError as exc:
            die(str(exc), 1)
    elif args.cmd == "current-tx":
        return cmd_current_tx()
    elif args.cmd == "rollback":
        return cmd_rollback()
    return 1


if __name__ == "__main__":
    sys.exit(main())
