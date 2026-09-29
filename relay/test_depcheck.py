# SPDX-License-Identifier: BSD-3-Clause
#
# Pure-function unit tests for depcheck.py and the five new control.py ops.
# No real subprocess/systemctl (mocked throughout), per this project's existing
# test philosophy (relay/test_control.py, in particular its FakeDeskUI
# injection pattern, mirrored below by FakeDepCheck). Real package-manager
# inspection (rpm/dpkg-query/pacman/zypper/dnf/yum) lives only in
# depcheck/edy-rdp-depsnapshot.py; that script was smoke-tested by hand against
# this dev host's own apt-get/dpkg (see the task report), and its pure
# transaction-attribution/timeout logic is exercised below (loaded via
# importlib, since its filename is not a valid module name) with every real
# subprocess call mocked out the same way.
import argparse
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import depcheck as DC
import control as C

# depcheck/edy-rdp-depsnapshot.py's filename is not a valid module name (and,
# unflattened, its own sys.path.insert would resolve "depcheck" to the
# depcheck/ SOURCE DIRECTORY rather than this file's relay/depcheck.py module)
# -- loaded by path instead, with "depcheck" already in sys.modules (the
# `import depcheck as DC` above) so its own `import depcheck as DC` reuses
# that cached module rather than mis-resolving one.
_DEPSNAPSHOT_PATH = os.path.join(os.path.dirname(__file__), "..", "depcheck",
                                 "edy-rdp-depsnapshot.py")


def _load_depsnapshot():
    spec = importlib.util.spec_from_file_location("edy_rdp_depsnapshot", _DEPSNAPSHOT_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- version comparison (ported from lib/edy-rdp-requires.sh) ----------------


class NormVersion(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(DC.norm_version("21.1.22"), "21.1.22")

    def test_drops_debian_epoch(self):
        self.assertEqual(DC.norm_version("2:21.1.22-1ubuntu1"), "21.1.22")

    def test_drops_trailing_release(self):
        self.assertEqual(DC.norm_version("360-1"), "360")

    def test_no_numeric_part(self):
        self.assertEqual(DC.norm_version("unknown"), "")

    def test_empty_and_none(self):
        self.assertEqual(DC.norm_version(""), "")
        self.assertEqual(DC.norm_version(None), "")


class VersionGe(unittest.TestCase):
    def test_below_minimum_is_not_compliant(self):
        self.assertFalse(DC.version_ge("2.31.0", "3.0"))

    def test_at_minimum_is_compliant(self):
        self.assertTrue(DC.version_ge("3.0", "3.0"))

    def test_above_minimum_is_compliant(self):
        self.assertTrue(DC.version_ge("3.31.0", "3.0"))

    def test_major_only_meets_dotted_minimum(self):
        # sort -V ranks '4' BELOW '4.0' with a naive compare; padding fixes it.
        self.assertTrue(DC.version_ge("4", "4.0"))

    def test_epoch_and_release_suffix_handled(self):
        self.assertTrue(DC.version_ge("2:21.1.22-1ubuntu1", "1.20"))

    def test_missing_version_is_not_compliant(self):
        self.assertFalse(DC.version_ge("", "1.0"))
        self.assertFalse(DC.version_ge(None, "1.0"))


# --- requires.txt parsing ------------------------------------------------------


class ParseRequires(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "requires.txt")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write(self, text):
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def test_plain_lines(self):
        self._write("cockpit  >=266  360-1  # note\nfreerdp  >=3.0  3.31.0\n")
        self.assertEqual(DC.parse_requires(self.path),
                         [("cockpit", "266"), ("freerdp", "3.0")])

    def test_guacd_image_line_excluded(self):
        self._write("podman  >=4.0  5.7.0\n"
                    "guacd-image  ghcr.io/x/y@sha256:aa  sha256:aa\n")
        self.assertEqual(DC.parse_requires(self.path), [("podman", "4.0")])

    def test_comments_and_blank_lines_skipped(self):
        self._write("# a comment\n\n   \nxvfb  >=1.20  21.1.22\n")
        self.assertEqual(DC.parse_requires(self.path), [("xvfb", "1.20")])

    def test_missing_file_returns_empty(self):
        self.assertEqual(DC.parse_requires(os.path.join(self.tmp, "nope.txt")), [])


# --- package-manager detection order ------------------------------------------


class DetectPm(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self._old_path = os.environ.get("PATH", "")

    def tearDown(self):
        os.environ["PATH"] = self._old_path
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _fake_bin(self, name):
        p = os.path.join(self.tmp, name)
        with open(p, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def test_none_present(self):
        os.environ["PATH"] = self.tmp
        self.assertEqual(DC.detect_pm(), "")

    def test_order_apt_get_before_dnf(self):
        self._fake_bin("dnf")
        self._fake_bin("apt-get")
        os.environ["PATH"] = self.tmp
        self.assertEqual(DC.detect_pm(), "apt-get")

    def test_order_dnf_before_yum_and_pacman(self):
        self._fake_bin("yum")
        self._fake_bin("pacman")
        self._fake_bin("dnf")
        os.environ["PATH"] = self.tmp
        self.assertEqual(DC.detect_pm(), "dnf")

    def test_order_yum_before_pacman_and_zypper(self):
        self._fake_bin("zypper")
        self._fake_bin("pacman")
        self._fake_bin("yum")
        os.environ["PATH"] = self.tmp
        self.assertEqual(DC.detect_pm(), "yum")

    def test_zypper_alone(self):
        self._fake_bin("zypper")
        os.environ["PATH"] = self.tmp
        self.assertEqual(DC.detect_pm(), "zypper")


# --- requires.txt name -> distro package mapping (the two names that ACTUALLY
# differ per lib/edy-rdp-requires.sh's req_pkg_for(), verified against the
# shell source: freerdp and xvfb) --------------------------------------------


class PkgForMapping(unittest.TestCase):
    def test_freerdp_per_distro(self):
        self.assertEqual(DC.pkg_for("freerdp", "apt-get"), ["freerdp3-x11"])
        self.assertEqual(DC.pkg_for("freerdp", "dnf"), ["freerdp"])
        self.assertEqual(DC.pkg_for("freerdp", "yum"), ["freerdp"])
        self.assertEqual(DC.pkg_for("freerdp", "pacman"), ["freerdp"])
        self.assertEqual(DC.pkg_for("freerdp", "zypper"), ["freerdp"])

    def test_xvfb_per_distro(self):
        self.assertEqual(DC.pkg_for("xvfb", "apt-get"), ["xvfb"])
        self.assertEqual(DC.pkg_for("xvfb", "dnf"), ["xorg-x11-server-Xvfb"])
        self.assertEqual(DC.pkg_for("xvfb", "yum"), ["xorg-x11-server-Xvfb"])
        self.assertEqual(DC.pkg_for("xvfb", "pacman"), ["xorg-server-xvfb"])
        self.assertEqual(DC.pkg_for("xvfb", "zypper"), ["xorg-x11-server-Xvfb"])

    def test_cockpit_is_the_one_multi_package_name(self):
        self.assertEqual(DC.pkg_for("cockpit", "apt-get"), ["cockpit", "cockpit-system"])
        self.assertEqual(DC.pkg_for("cockpit", "zypper"), ["cockpit", "cockpit-bridge"])

    def test_unmapped_name_falls_back_to_canonical_everywhere(self):
        for pm in ("apt-get", "dnf", "yum", "pacman", "zypper"):
            self.assertEqual(DC.pkg_for("nftables", pm), ["nftables"])
            self.assertEqual(DC.pkg_for("x11vnc", pm), ["x11vnc"])
            self.assertEqual(DC.pkg_for("gnome-remote-desktop", pm), ["gnome-remote-desktop"])


# --- diff_snapshots: pure, literal-dict fixtures ------------------------------


def _pkg(name, version, arch="x86_64", tracked=False):
    return {"name": name, "version": version, "arch": arch, "tracked": tracked}


class DiffSnapshots(unittest.TestCase):
    def test_added_removed_changed_unchanged(self):
        older = {"packages": [_pkg("a", "1.0"), _pkg("b", "2.0"), _pkg("c", "3.0")]}
        newer = {"packages": [_pkg("a", "1.0"), _pkg("b", "2.1"), _pkg("d", "9.0")]}
        d = DC.diff_snapshots(older, newer)
        self.assertEqual([p["name"] for p in d["added"]], ["d"])
        self.assertEqual([p["name"] for p in d["removed"]], ["c"])
        self.assertEqual(d["changed"], [{"name": "b", "arch": "x86_64",
                                         "old_version": "2.0", "new_version": "2.1",
                                         "tracked": False}])
        self.assertEqual(d["unchanged_count"], 1)

    def test_changed_tracked_flag_true_if_either_side_tracked(self):
        older = {"packages": [_pkg("freerdp3-x11", "3.30.0", tracked=True)]}
        newer = {"packages": [_pkg("freerdp3-x11", "3.31.0", tracked=True)]}
        d = DC.diff_snapshots(older, newer)
        self.assertTrue(d["changed"][0]["tracked"])

    def test_multi_arch_packages_are_not_collapsed_by_name(self):
        # Found while smoke-testing against this dev host's own apt inventory:
        # keying by name alone silently shadowed one arch's entry.
        older = {"packages": [_pkg("libc6", "2.39", arch="amd64"),
                              _pkg("libc6", "2.39", arch="i386")]}
        newer = {"packages": [_pkg("libc6", "2.39", arch="amd64"),
                              _pkg("libc6", "2.40", arch="i386")]}
        d = DC.diff_snapshots(older, newer)
        self.assertEqual(len(d["changed"]), 1)
        self.assertEqual(d["changed"][0]["arch"], "i386")
        self.assertEqual(d["unchanged_count"], 1)

    def test_empty_inputs(self):
        self.assertEqual(DC.diff_snapshots({}, {}),
                         {"added": [], "removed": [], "changed": [], "unchanged_count": 0})

    def test_none_inputs_do_not_raise(self):
        d = DC.diff_snapshots(None, None)
        self.assertEqual(d["unchanged_count"], 0)


# --- blast_radius: pure lookup -------------------------------------------------


class BlastRadius(unittest.TestCase):
    def test_found(self):
        snap = {"tracked": {"freerdp": {"requires": ["libssl3"], "required_by": ["a", "b"]}}}
        self.assertEqual(DC.blast_radius(snap, "freerdp"),
                         {"found": True, "requires": ["libssl3"], "required_by": ["a", "b"],
                          "required_by_unavailable": False})

    def test_not_tracked(self):
        snap = {"tracked": {"freerdp": {"requires": [], "required_by": []}}}
        self.assertEqual(DC.blast_radius(snap, "some-untracked-pkg"),
                         {"found": False, "requires": [], "required_by": [],
                          "required_by_unavailable": False})

    def test_missing_tracked_section(self):
        self.assertEqual(DC.blast_radius({}, "freerdp"),
                         {"found": False, "requires": [], "required_by": [],
                          "required_by_unavailable": False})

    def test_required_by_unavailable_flag_is_threaded_through(self):
        # KNOWN_ISSUES I51 F5: a failed reverse-dependency check (no pactree,
        # or a broken rpm/apt-cache query) must not render identically to a
        # real "nothing depends on this" -- the flag must survive the lookup.
        snap = {"tracked": {"freerdp": {"requires": ["libssl3"], "required_by": [],
                                        "required_by_unavailable": True}}}
        r = DC.blast_radius(snap, "freerdp")
        self.assertTrue(r["required_by_unavailable"])
        self.assertEqual(r["required_by"], [])


# --- rollback_command_hint -----------------------------------------------------


class RollbackCommandHint(unittest.TestCase):
    def test_apt_get(self):
        self.assertEqual(DC.rollback_command_hint("apt-get", "freerdp3-x11", "3.30.0"),
                         "apt-get install freerdp3-x11=3.30.0")

    def test_zypper(self):
        self.assertEqual(DC.rollback_command_hint("zypper", "freerdp", "3.30.0"),
                         "zypper install freerdp=3.30.0")

    def test_pacman_names_the_cached_package_file(self):
        hint = DC.rollback_command_hint("pacman", "freerdp", "3.30.0")
        self.assertIn("pacman -U", hint)
        self.assertIn("freerdp-3.30.0", hint)

    def test_dnf_and_yum_get_no_hint_native_rollback_instead(self):
        self.assertIsNone(DC.rollback_command_hint("dnf", "freerdp", "3.30.0"))
        self.assertIsNone(DC.rollback_command_hint("yum", "freerdp", "3.30.0"))


# --- list_snapshots / load_snapshot: real filesystem, no subprocess ----------


class SnapshotDirRoundTrip(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write(self, timestamp, summary_extra=None):
        import json
        summary = {"timestamp": timestamp, "deploy_version": "1.7.0.20260929",
                   "pkg_mgr": "dnf", "total_packages": 100, "tracked_count": 9,
                   "noncompliant_count": 0, "changed_since_previous": True}
        summary.update(summary_extra or {})
        data = {"schema_version": 1, "timestamp": timestamp, "summary": summary,
               "packages": [], "tracked": {}}
        with open(os.path.join(self.tmp, "%s.json" % timestamp), "w") as fh:
            json.dump(data, fh)

    def test_empty_directory(self):
        self.assertEqual(DC.list_snapshots(self.tmp), [])
        self.assertIsNone(DC.load_snapshot(self.tmp, "latest"))

    def test_missing_directory(self):
        self.assertEqual(DC.list_snapshots(os.path.join(self.tmp, "nope")), [])
        self.assertIsNone(DC.load_snapshot(os.path.join(self.tmp, "nope"), "latest"))

    def test_newest_first(self):
        self._write("20260101T000000Z")
        self._write("20260201T000000Z")
        hist = DC.list_snapshots(self.tmp)
        self.assertEqual([h["timestamp"] for h in hist],
                         ["20260201T000000Z", "20260101T000000Z"])

    def test_load_latest(self):
        self._write("20260101T000000Z")
        self._write("20260201T000000Z")
        snap = DC.load_snapshot(self.tmp, "latest")
        self.assertEqual(snap["timestamp"], "20260201T000000Z")

    def test_load_by_exact_timestamp(self):
        self._write("20260101T000000Z")
        snap = DC.load_snapshot(self.tmp, "20260101T000000Z")
        self.assertEqual(snap["timestamp"], "20260101T000000Z")

    def test_load_unknown_timestamp_is_none(self):
        self._write("20260101T000000Z")
        self.assertIsNone(DC.load_snapshot(self.tmp, "20991231T000000Z"))

    def test_load_latest_skips_the_summary_companion_file(self):
        # KNOWN_ISSUES I51 F4 regression: write_snapshot() (depcheck/edy-rdp-
        # depsnapshot.py) writes <ts>.summary.json alongside <ts>.json for
        # list_snapshots()'s cheap reads. ".summary.json" sorts lexically
        # AFTER ".json" for the same timestamp, so a naive `sorted(glob(...))
        # [-1]` picks the summary file instead of the full snapshot -- and
        # since write_snapshot() always writes both, this is not a rare edge
        # case, it is what every real "latest" lookup sees.
        self._write("20260101T000000Z")
        self._write("20260201T000000Z")
        with open(os.path.join(self.tmp, "20260201T000000Z.summary.json"), "w") as fh:
            json.dump({"timestamp": "20260201T000000Z"}, fh)
        snap = DC.load_snapshot(self.tmp, "latest")
        self.assertEqual(snap["timestamp"], "20260201T000000Z")
        self.assertIn("packages", snap)
        self.assertIn("tracked", snap)

    def test_corrupt_file_skipped_not_fatal(self):
        self._write("20260101T000000Z")
        with open(os.path.join(self.tmp, "20260201T000000Z.json"), "w") as fh:
            fh.write("{not json")
        hist = DC.list_snapshots(self.tmp)
        self.assertEqual([h["timestamp"] for h in hist], ["20260101T000000Z"])


# --- DepCheck: status/history/list/blast_radius over real snapshot files ------


class DepCheckReads(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dep_dir = os.path.join(self.tmp, "dep-history")
        os.makedirs(self.dep_dir)
        self.dc = DC.DepCheck(root=self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write(self, timestamp, pkg_mgr="dnf", packages=None, tracked=None, noncompliant=0):
        import json
        packages = packages if packages is not None else []
        tracked = tracked if tracked is not None else {}
        data = {"schema_version": 1, "timestamp": timestamp, "pkg_mgr": pkg_mgr,
               "dnf_transaction_id": "42", "packages": packages, "tracked": tracked,
               "summary": {"timestamp": timestamp, "deploy_version": "1.7.0.20260929",
                          "pkg_mgr": pkg_mgr, "total_packages": len(packages),
                          "tracked_count": len(tracked), "noncompliant_count": noncompliant,
                          "changed_since_previous": True}}
        with open(os.path.join(self.dep_dir, "%s.json" % timestamp), "w") as fh:
            json.dump(data, fh)

    def test_status_with_no_history_yet(self):
        st = self.dc.status()
        self.assertFalse(st["tracking_available"])
        self.assertEqual(st["snapshot_count"], 0)
        self.assertFalse(st["native_rollback_available"])

    def test_status_reports_latest_and_native_rollback_flag_on_dnf(self):
        self._write("20260101T000000Z", pkg_mgr="dnf")
        st = self.dc.status()
        self.assertTrue(st["tracking_available"])
        self.assertTrue(st["native_rollback_available"])
        self.assertEqual(st["pkg_mgr"], "dnf")

    def test_status_native_rollback_false_on_apt(self):
        self._write("20260101T000000Z", pkg_mgr="apt-get")
        self.assertFalse(self.dc.status()["native_rollback_available"])

    def test_history_newest_first(self):
        self._write("20260101T000000Z")
        self._write("20260201T000000Z")
        hist = self.dc.history()
        self.assertEqual([h["timestamp"] for h in hist],
                         ["20260201T000000Z", "20260101T000000Z"])

    def test_list_tracked_only_filter(self):
        self._write("20260101T000000Z",
                    packages=[_pkg("freerdp3-x11", "3.31.0", tracked=True),
                             _pkg("vim", "9.0", tracked=False)])
        out = self.dc.list("latest", tracked_only=True)
        self.assertEqual([p["name"] for p in out["packages"]], ["freerdp3-x11"])
        out_all = self.dc.list("latest", tracked_only=False)
        self.assertEqual(len(out_all["packages"]), 2)

    def test_list_no_history_is_none(self):
        self.assertIsNone(self.dc.list("latest"))

    def test_blast_radius_from_latest(self):
        self._write("20260101T000000Z",
                    tracked={"freerdp": {"requires": ["libssl3"], "required_by": []}})
        self.assertEqual(self.dc.blast_radius("freerdp"),
                         {"found": True, "requires": ["libssl3"], "required_by": [],
                          "required_by_unavailable": False})

    def test_blast_radius_no_history_is_none(self):
        self.assertIsNone(self.dc.blast_radius("freerdp"))


# --- DepCheck.rollback(): subprocess/systemctl fully mocked -------------------


class DepCheckRollback(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dep_dir = os.path.join(self.tmp, "dep-history")
        os.makedirs(self.dep_dir)
        self.dc = DC.DepCheck(root=self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _seed_one_snapshot(self):
        import json
        with open(os.path.join(self.dep_dir, "20260101T000000Z.json"), "w") as fh:
            json.dump({"timestamp": "20260101T000000Z",
                      "summary": {"timestamp": "20260101T000000Z"}}, fh)

    def test_refuses_with_no_history_at_all(self):
        ok, detail = self.dc.rollback()
        self.assertFalse(ok)
        self.assertIn("nothing to roll back", detail)

    @mock.patch("depcheck.subprocess.run")
    def test_success(self, run):
        self._seed_one_snapshot()
        run.return_value = mock.Mock(returncode=0)
        ok, detail = self.dc.rollback()
        self.assertTrue(ok)
        run.assert_called_once()
        self.assertEqual(run.call_args[0][0], ["systemctl", "start", DC.ROLLBACK_UNIT])

    def _failure(self, exec_main_status_code):
        self._seed_one_snapshot()
        exc = subprocess.CalledProcessError(1, ["systemctl"], stderr=b"boom")
        with mock.patch("depcheck.subprocess.run", side_effect=exc), \
             mock.patch("depcheck._exec_main_status", return_value=exec_main_status_code):
            return self.dc.rollback()

    def test_not_dnf_yum_host_refusal(self):
        ok, detail = self._failure("2")
        self.assertFalse(ok)
        self.assertIn("no native rollback", detail)

    def test_no_transaction_on_record_refusal(self):
        ok, detail = self._failure("3")
        self.assertFalse(ok)
        self.assertIn("no dnf/yum transaction", detail)

    def test_stale_transaction_refusal(self):
        ok, detail = self._failure("4")
        self.assertFalse(ok)
        self.assertIn("newer", detail.lower())

    def test_undo_itself_failed(self):
        ok, detail = self._failure("5")
        self.assertFalse(ok)
        self.assertIn("needs a human", detail)

    @mock.patch("depcheck.subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="x", timeout=1))
    def test_timeout(self, run):
        self._seed_one_snapshot()
        ok, detail = self.dc.rollback()
        self.assertFalse(ok)


# --- control.py op dispatch: the five new ops ---------------------------------


class FakeDepCheck:
    """Stand-in for the relay's DepCheck: handle_control's POLICY (any-caller
    reads, admin + typed-confirm write) is tested with no disk/systemctl I/O —
    same injection contract as FakeDeskUI in test_control.py."""

    def __init__(self, hostname="testhost", rollback_result=(True, "rolled back")):
        self.hostname = hostname
        self._rollback_result = rollback_result
        self.rollback_calls = 0

    def status(self):
        return {"tracking_available": True, "pkg_mgr": "dnf",
               "native_rollback_available": True, "total_packages": 500,
               "tracked_count": 9, "noncompliant_count": 1}

    def history(self):
        return [{"timestamp": "20260101T000000Z"}]

    def list(self, snapshot="latest", tracked_only=False):
        if snapshot == "missing":
            return None
        return {"timestamp": "20260101T000000Z", "packages": [], "tracked": {}}

    def blast_radius(self, name):
        if name == "missing":
            return None
        return {"found": True, "requires": [], "required_by": []}

    def rollback(self):
        self.rollback_calls += 1
        return self._rollback_result


class DepsStatusOp(unittest.TestCase):
    def test_unavailable_without_controller(self):
        r = C.handle_control({"op": "deps-status"}, 1000, None, None, False)
        self.assertFalse(r["ok"])
        self.assertIn("not available", r["error"])

    def test_reports_state_and_admin_flag(self):
        d = FakeDepCheck()
        r = C.handle_control({"op": "deps-status"}, 1000, None, None,
                             is_admin=True, depcheck=d)
        self.assertTrue(r["ok"])
        self.assertTrue(r["admin"])
        self.assertEqual(r["pkg_mgr"], "dnf")
        self.assertTrue(r["native_rollback_available"])


class DepsHistoryOp(unittest.TestCase):
    def test_unavailable_without_controller(self):
        r = C.handle_control({"op": "deps-history"}, 1000, None, None, False)
        self.assertFalse(r["ok"])

    def test_returns_snapshots(self):
        d = FakeDepCheck()
        r = C.handle_control({"op": "deps-history"}, 1000, None, None, False, depcheck=d)
        self.assertTrue(r["ok"])
        self.assertEqual(r["snapshots"], [{"timestamp": "20260101T000000Z"}])


class DepsListOp(unittest.TestCase):
    def test_no_such_snapshot_is_a_clean_error(self):
        d = FakeDepCheck()
        r = C.handle_control({"op": "deps-list", "snapshot": "missing"}, 1000,
                             None, None, False, depcheck=d)
        self.assertFalse(r["ok"])

    def test_defaults_to_latest_full_list(self):
        d = FakeDepCheck()
        r = C.handle_control({"op": "deps-list"}, 1000, None, None, False, depcheck=d)
        self.assertTrue(r["ok"])
        self.assertEqual(r["timestamp"], "20260101T000000Z")


class DepsBlastRadiusOp(unittest.TestCase):
    def test_requires_name(self):
        d = FakeDepCheck()
        r = C.handle_control({"op": "deps-blast-radius"}, 1000, None, None, False, depcheck=d)
        self.assertFalse(r["ok"])

    def test_not_found_is_a_clean_error(self):
        d = FakeDepCheck()
        r = C.handle_control({"op": "deps-blast-radius", "package": "missing"}, 1000,
                             None, None, False, depcheck=d)
        self.assertFalse(r["ok"])

    def test_found(self):
        d = FakeDepCheck()
        r = C.handle_control({"op": "deps-blast-radius", "package": "freerdp"}, 1000,
                             None, None, False, depcheck=d)
        self.assertTrue(r["ok"])
        self.assertTrue(r["found"])


class DepsRollbackOp(unittest.TestCase):
    def _ctl(self, req, admin, d):
        return C.handle_control(req, 1000, None, None, admin, depcheck=d)

    def test_unavailable_without_controller(self):
        r = self._ctl({"op": "deps-rollback"}, True, None)
        self.assertFalse(r["ok"])
        self.assertIn("not available", r["error"])

    def test_write_needs_admin(self):
        d = FakeDepCheck()
        r = self._ctl({"op": "deps-rollback"}, False, d)
        self.assertFalse(r["ok"])
        self.assertIn("administrative access", r["error"])
        self.assertEqual(d.rollback_calls, 0)

    def test_requires_typed_hostname_confirmation(self):
        d = FakeDepCheck(hostname="testhost")
        r = self._ctl({"op": "deps-rollback"}, True, d)
        self.assertFalse(r["ok"])
        self.assertTrue(r["need_confirm"])
        self.assertEqual(r["hostname"], "testhost")
        self.assertEqual(d.rollback_calls, 0)

    def test_wrong_confirmation_refused(self):
        d = FakeDepCheck(hostname="testhost")
        r = self._ctl({"op": "deps-rollback", "confirm": "nope"}, True, d)
        self.assertFalse(r["ok"])
        self.assertTrue(r["need_confirm"])
        self.assertEqual(d.rollback_calls, 0)

    def test_confirmed_success(self):
        d = FakeDepCheck(hostname="testhost", rollback_result=(True, "rolled back"))
        r = self._ctl({"op": "deps-rollback", "confirm": "testhost"}, True, d)
        self.assertTrue(r["ok"])
        self.assertEqual(d.rollback_calls, 1)

    def test_confirmed_but_not_a_dnf_yum_host(self):
        d = FakeDepCheck(hostname="testhost",
                         rollback_result=(False, "this host's package manager has no native rollback"))
        r = self._ctl({"op": "deps-rollback", "confirm": "testhost"}, True, d)
        self.assertFalse(r["ok"])
        self.assertIn("no native rollback", r["detail"])

    def test_confirmed_but_stale_transaction(self):
        d = FakeDepCheck(hostname="testhost",
                         rollback_result=(False, "a newer dnf transaction exists on this host"))
        r = self._ctl({"op": "deps-rollback", "confirm": "testhost"}, True, d)
        self.assertFalse(r["ok"])
        self.assertIn("newer dnf transaction", r["detail"])


# --- KNOWN_ISSUES I51 F1: relay timeout vs. the rollback unit's own limit ----


class RollbackTimeoutAgreement(unittest.TestCase):
    """The relay's own wait on the rollback unit must never be SHORTER than
    either the unit's own TimeoutStartSec or the dnf/yum-undo timeout the
    script itself allows -- that mismatch (150s unit / 120s relay / 600s
    script) is exactly how F1 let the relay report a timeout while the real
    dnf transaction kept running. Reads both real values instead of
    hardcoding a duplicate literal, so they can never silently drift apart
    again."""

    _UNIT_PATH = os.path.join(os.path.dirname(__file__), "..", "systemd",
                              "edy-rdp-depcheck-rollback.service.in")

    def _unit_timeout_start_sec(self):
        with open(self._UNIT_PATH, encoding="utf-8") as fh:
            for line in fh:
                if line.strip().startswith("TimeoutStartSec="):
                    return line.strip().split("=", 1)[1]
        self.fail("TimeoutStartSec= not found in %s" % self._UNIT_PATH)

    def test_relay_timeout_not_shorter_than_unit(self):
        unit_timeout = self._unit_timeout_start_sec()
        if unit_timeout == "infinity":
            return  # no cap on that side -- the relay's own timeout is the only bound
        self.assertGreaterEqual(DC.ROLLBACK_TIMEOUT, int(unit_timeout))

    def test_relay_timeout_not_shorter_than_script_dnf_undo_timeout(self):
        mod = _load_depsnapshot()
        script_timeout = mod.run_history_undo.__defaults__[0]
        self.assertGreaterEqual(DC.ROLLBACK_TIMEOUT, script_timeout)


# --- KNOWN_ISSUES I51 F2/F3: a rollback tx id must be attributable to THIS
# run's own install_deps(), precisely -- never inferred from any snapshot's
# own "current" transaction reading. --------------------------------------


class AttributableTransactionId(unittest.TestCase):
    def setUp(self):
        self.mod = _load_depsnapshot()

    def test_non_after_label_is_always_none(self):
        # "before" and unlabeled snapshots never get an attributed value at
        # all, regardless of install_tx -- only cmd_rollback()'s own
        # label == "after" check matters, and this is the first line of
        # defense for it (KNOWN_ISSUES I51 F1: rollback must never trust a
        # non-"after" snapshot's dnf_transaction_id).
        self.assertIsNone(self.mod.attributable_transaction_id("dnf", "7", "before"))
        self.assertIsNone(self.mod.attributable_transaction_id("dnf", "7", ""))

    def test_after_label_records_the_given_install_tx(self):
        # install_tx is THIS SAME run's own install_deps() bracketing its one
        # package-manager invocation tightly and observing a new transaction
        # id -- passed through explicitly via deploy.sh's --install-tx, never
        # inferred by comparing against any snapshot's own reading (that
        # comparison-based design was KNOWN_ISSUES I51 F3: it misattributed
        # unrelated dnf/yum activity happening anywhere in the wider window
        # between install_deps() finishing and the "after" snapshot actually
        # running, at the very end of deploy.sh).
        self.assertEqual(self.mod.attributable_transaction_id("dnf", "7", "after"), "7")

    def test_after_label_with_no_install_tx_refuses_rather_than_guessing(self):
        # install_deps() never ran, or ran and created no new transaction --
        # either way, nothing to attribute. Refusing here just means rollback
        # has nothing to undo yet (safe); guessing would not be.
        self.assertIsNone(self.mod.attributable_transaction_id("dnf", None, "after"))
        self.assertIsNone(self.mod.attributable_transaction_id("dnf", "", "after"))

    def test_non_dnf_yum_is_always_none(self):
        self.assertIsNone(self.mod.attributable_transaction_id("apt-get", "7", "after"))


class CmdSnapshotAttribution(unittest.TestCase):
    """cmd_snapshot() end to end (mocked inventory/requires/pm-detection,
    real write_snapshot()/load_snapshot() against a real temp directory) --
    the exact wiring a mutation test showed had ZERO coverage before this
    (KNOWN_ISSUES I51 F4): flipping --install-tx to a no-op, or reverting to
    the old "compare against whatever snapshot is newest on disk" design,
    left every other test in this file green."""

    def setUp(self):
        self.mod = _load_depsnapshot()
        self.tmp = tempfile.mkdtemp()
        self.requires_path = os.path.join(self.tmp, "requires.txt")
        with open(self.requires_path, "w") as fh:
            fh.write("cockpit\t>=1\n")
        self._patches = [
            mock.patch.object(self.mod.DC, "detect_pm", return_value="dnf"),
            mock.patch.object(self.mod, "gather_inventory", return_value=([], {})),
            mock.patch.object(self.mod.DC, "parse_requires", return_value=[]),
            mock.patch.object(self.mod, "build_tracked", return_value=({}, set())),
        ]
        for p in self._patches:
            p.start()
            self.addCleanup(p.stop)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _snapshot(self, label, install_tx=None):
        args = argparse.Namespace(root=self.tmp, requires=self.requires_path,
                                  deploy_version="1.9.3.test", label=label,
                                  install_tx=install_tx)
        self.assertEqual(self.mod.cmd_snapshot(args), 0)
        return self.mod.DC.load_snapshot(self.mod.DC.snapshot_dir(self.tmp), "latest")

    def test_before_snapshot_never_gets_a_dnf_transaction_id(self):
        with mock.patch.object(self.mod, "get_latest_transaction_id", return_value="41"):
            snap = self._snapshot("before")
        self.assertIsNone(snap["dnf_transaction_id"])
        self.assertEqual(snap["baseline_transaction_id"], "41")  # informational only

    def test_after_snapshot_with_install_tx_records_exactly_that_value(self):
        with mock.patch.object(self.mod, "get_latest_transaction_id", return_value="99"):
            snap = self._snapshot("after", install_tx="42")
        self.assertEqual(snap["dnf_transaction_id"], "42")
        # baseline_transaction_id is independent -- "whatever is newest right
        # now" (99, from an unrelated concurrent transaction in this
        # fixture), never conflated with the attributed value (42).
        self.assertEqual(snap["baseline_transaction_id"], "99")

    def test_after_snapshot_with_no_install_tx_records_nothing_attributable(self):
        with mock.patch.object(self.mod, "get_latest_transaction_id", return_value="99"):
            snap = self._snapshot("after", install_tx=None)
        self.assertIsNone(snap["dnf_transaction_id"])


class RollbackRefusesUnattributedSnapshots(unittest.TestCase):
    def setUp(self):
        self.mod = _load_depsnapshot()

    def test_no_attributable_transaction_produces_a_rollback_refusal(self):
        # End-to-end through cmd_rollback()'s own exit-3 path: an "after"
        # snapshot with no dnf_transaction_id (install_deps() caused no new
        # transaction) refuses cleanly rather than falling back to some
        # unrelated tx.
        tmp = tempfile.mkdtemp()
        try:
            dep_dir = os.path.join(tmp, "dep-history")
            os.makedirs(dep_dir)
            self.mod.write_snapshot(dep_dir, "20260101T000000Z",
                                    {"timestamp": "20260101T000000Z", "label": "after",
                                     "dnf_transaction_id": None,
                                     "packages": [], "tracked": {},
                                     "summary": {"timestamp": "20260101T000000Z"}})
            with mock.patch.object(self.mod.DC, "install_root", return_value=tmp), \
                 mock.patch.object(self.mod.DC, "detect_pm", return_value="dnf"), \
                 mock.patch.object(self.mod, "get_latest_transaction_id", return_value="6"), \
                 self.assertRaises(SystemExit) as ctx:
                self.mod.cmd_rollback()
            self.assertEqual(ctx.exception.code, 3)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_rollback_refuses_a_non_after_snapshot_even_with_a_tx_id_on_it(self):
        # KNOWN_ISSUES I51 F1 (found by adversarial review of an earlier fix
        # in this same file, reproduced live): if a deploy aborts, or its own
        # "after" snapshot fails to write (best-effort/non-fatal), the newest
        # snapshot on disk can be a "before" baseline instead. cmd_rollback()
        # must refuse based on the snapshot's OWN label, not merely on
        # whether dnf_transaction_id happens to be present -- defense in
        # depth on top of attributable_transaction_id() never setting that
        # field for a non-"after" snapshot in real use, in case any future
        # code path ever writes one that does.
        tmp = tempfile.mkdtemp()
        try:
            dep_dir = os.path.join(tmp, "dep-history")
            os.makedirs(dep_dir)
            self.mod.write_snapshot(dep_dir, "20260101T000000Z",
                                    {"timestamp": "20260101T000000Z", "label": "before",
                                     "dnf_transaction_id": "41",
                                     "packages": [], "tracked": {},
                                     "summary": {"timestamp": "20260101T000000Z"}})
            with mock.patch.object(self.mod.DC, "install_root", return_value=tmp), \
                 mock.patch.object(self.mod.DC, "detect_pm", return_value="dnf"), \
                 mock.patch.object(self.mod, "run_history_undo") as undo, \
                 self.assertRaises(SystemExit) as ctx:
                self.mod.cmd_rollback()
            self.assertEqual(ctx.exception.code, 3)
            undo.assert_not_called()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


# --- KNOWN_ISSUES I51 F4: list_snapshots() must stay cheap -------------------


class ListSnapshotsCheap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_does_not_read_the_full_packages_array(self):
        mod = _load_depsnapshot()
        huge_packages = [{"name": "pkg%d" % i, "version": "1.0", "arch": "x86_64"}
                         for i in range(20000)]
        data = {"schema_version": 1, "timestamp": "20260101T000000Z",
               "packages": huge_packages, "tracked": {},
               "summary": {"timestamp": "20260101T000000Z", "pkg_mgr": "dnf",
                          "total_packages": len(huge_packages), "tracked_count": 0,
                          "noncompliant_count": 0, "changed_since_previous": True,
                          "deploy_version": "1.7.0.20260929"}}
        mod.write_snapshot(self.tmp, "20260101T000000Z", data)
        full_path = os.path.abspath(os.path.join(self.tmp, "20260101T000000Z.json"))
        real_open = open

        def spy_open(path, *a, **kw):
            if os.path.abspath(path) == full_path:
                raise AssertionError("list_snapshots() opened the full snapshot file: %s" % path)
            return real_open(path, *a, **kw)

        with mock.patch("depcheck.open", side_effect=spy_open):
            hist = DC.list_snapshots(self.tmp)
        self.assertEqual(len(hist), 1)
        self.assertEqual(hist[0]["total_packages"], 20000)

    def test_falls_back_to_the_full_file_for_a_legacy_snapshot_with_no_companion(self):
        # A snapshot written before this fix (or by an older depsnapshot.py)
        # has no *.summary.json companion -- it must still show up, not vanish.
        import json
        data = {"schema_version": 1, "timestamp": "20260101T000000Z", "packages": [], "tracked": {},
               "summary": {"timestamp": "20260101T000000Z", "pkg_mgr": "dnf", "total_packages": 0,
                          "tracked_count": 0, "noncompliant_count": 0, "changed_since_previous": True}}
        with open(os.path.join(self.tmp, "20260101T000000Z.json"), "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        hist = DC.list_snapshots(self.tmp)
        self.assertEqual([h["timestamp"] for h in hist], ["20260101T000000Z"])


# --- KNOWN_ISSUES I51 F7: rpm/apt whatrequires unavailable-vs-zero ----------


class RpmAptWhatrequiresUnavailable(unittest.TestCase):
    def setUp(self):
        self.mod = _load_depsnapshot()

    def test_rpm_missing_binary_is_unavailable(self):
        with mock.patch.object(self.mod, "_which", return_value=None):
            self.assertIsNone(self.mod._rpm_whatrequires("freerdp"))

    def test_rpm_real_failure_with_stderr_is_unavailable(self):
        with mock.patch.object(self.mod, "_which", return_value="/usr/bin/rpm"), \
             mock.patch.object(self.mod, "_run_with_stderr", return_value=(1, "", "error: rpmdb corrupt")):
            self.assertIsNone(self.mod._rpm_whatrequires("freerdp"))

    def test_rpm_genuinely_zero_dependents_is_an_empty_list(self):
        with mock.patch.object(self.mod, "_which", return_value="/usr/bin/rpm"), \
             mock.patch.object(self.mod, "_run_with_stderr", return_value=(1, "", "")):
            self.assertEqual(self.mod._rpm_whatrequires("freerdp"), [])

    def test_apt_missing_binary_is_unavailable(self):
        with mock.patch.object(self.mod, "_which", return_value=None):
            self.assertIsNone(self.mod._apt_whatrequires("freerdp"))

    def test_apt_real_failure_with_stderr_is_unavailable(self):
        with mock.patch.object(self.mod, "_which", return_value="/usr/bin/apt-cache"), \
             mock.patch.object(self.mod, "_run_with_stderr", return_value=(100, "", "E: No packages found")):
            self.assertIsNone(self.mod._apt_whatrequires("freerdp"))

    def test_apt_genuinely_zero_dependents_is_an_empty_list(self):
        with mock.patch.object(self.mod, "_which", return_value="/usr/bin/apt-cache"), \
             mock.patch.object(self.mod, "_run_with_stderr", return_value=(0, "Reverse Depends:\n", "")):
            self.assertEqual(self.mod._apt_whatrequires("freerdp"), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
