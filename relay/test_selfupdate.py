# SPDX-License-Identifier: BSD-3-Clause
#
# Pure-function unit tests for selfupdate.py and the four new control.py ops.
# No real network, no real subprocess/systemctl, no real socket: urllib,
# subprocess and socket are mocked throughout, per this project's existing
# test philosophy (relay/test_control.py, relay/test_edy_rdp_relay.py).
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import selfupdate as su
import control as C


# --- version parse / compare -------------------------------------------------


class ParseVersion(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(su.parse_version("1.7.0.20260929"), (1, 7, 0, 20260929))

    def test_v_prefix(self):
        self.assertEqual(su.parse_version("v1.7.0.20260929"), (1, 7, 0, 20260929))
        self.assertEqual(su.parse_version("V1.7.0.20260929"), (1, 7, 0, 20260929))

    def test_none_and_empty(self):
        self.assertIsNone(su.parse_version(None))
        self.assertIsNone(su.parse_version(""))

    def test_wrong_segment_count(self):
        self.assertIsNone(su.parse_version("1.7.0"))
        self.assertIsNone(su.parse_version("1.7.0.1.2"))

    def test_non_numeric_segment(self):
        self.assertIsNone(su.parse_version("1.7.x.20260929"))

    def test_non_string_input(self):
        self.assertIsNone(su.parse_version(170))
        self.assertIsNone(su.parse_version(["1", "7", "0", "20260929"]))


class IsNewer(unittest.TestCase):
    def test_newer_patch(self):
        self.assertTrue(su.is_newer("1.6.1.20260929", "1.7.0.20260929"))

    def test_equal_is_not_newer(self):
        self.assertFalse(su.is_newer("1.7.0.20260929", "1.7.0.20260929"))

    def test_older_is_not_newer(self):
        self.assertFalse(su.is_newer("1.7.0.20260929", "1.6.1.20260929"))

    def test_newer_by_date_only(self):
        self.assertTrue(su.is_newer("1.7.0.20260929", "1.7.0.20261001"))

    def test_malformed_current_never_reports_available(self):
        self.assertFalse(su.is_newer("not-a-version", "1.7.0.20260929"))

    def test_malformed_candidate_never_reports_available(self):
        self.assertFalse(su.is_newer("1.6.1.20260929", "garbage"))

    def test_both_malformed(self):
        self.assertFalse(su.is_newer("nope", "also-nope"))

    def test_none_inputs_never_crash(self):
        self.assertFalse(su.is_newer(None, None))
        self.assertFalse(su.is_newer(None, "1.7.0.20260929"))
        self.assertFalse(su.is_newer("1.7.0.20260929", None))


# --- cache read/write/staleness ----------------------------------------------


class CacheRoundTrip(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "sub", "update-status.json")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_missing_file_reads_none(self):
        self.assertIsNone(su.read_cache(self.path))

    def test_write_then_read(self):
        data = {"latest_version": "1.7.0.20260929", "update_available": True,
                "checked_at": 12345}
        su.write_cache(data, self.path)
        self.assertEqual(su.read_cache(self.path), data)

    def test_write_creates_parent_dir(self):
        self.assertFalse(os.path.isdir(os.path.dirname(self.path)))
        su.write_cache({"x": 1}, self.path)
        self.assertTrue(os.path.isfile(self.path))

    def test_corrupted_file_reads_none_not_raise(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "w") as fh:
            fh.write("{not json")
        self.assertIsNone(su.read_cache(self.path))

    def test_non_dict_json_reads_none(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "w") as fh:
            fh.write("[1, 2, 3]")
        self.assertIsNone(su.read_cache(self.path))

    def test_overwrite_is_atomic_and_clean(self):
        su.write_cache({"a": 1}, self.path)
        su.write_cache({"a": 2}, self.path)
        self.assertEqual(su.read_cache(self.path), {"a": 2})
        # no leftover temp files beside it
        leftovers = [f for f in os.listdir(os.path.dirname(self.path)) if f.startswith(".update-status-")]
        self.assertEqual(leftovers, [])


class CacheStaleness(unittest.TestCase):
    def test_missing_cache_is_stale(self):
        self.assertTrue(su.cache_is_stale(None))

    def test_no_checked_at_is_stale(self):
        self.assertTrue(su.cache_is_stale({"latest_version": "x"}))

    def test_fresh_is_not_stale(self):
        now = 1_000_000
        self.assertFalse(su.cache_is_stale({"checked_at": now - 10}, ttl=3600, now=now))

    def test_old_is_stale(self):
        now = 1_000_000
        self.assertTrue(su.cache_is_stale({"checked_at": now - 7200}, ttl=3600, now=now))

    def test_exactly_at_ttl_boundary_is_not_stale(self):
        now = 1_000_000
        self.assertFalse(su.cache_is_stale({"checked_at": now - 3600}, ttl=3600, now=now))


# --- rollback-candidate selection --------------------------------------------


class RollbackCandidate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _mkpayload(self, version):
        d = os.path.join(self.tmp, "payload-%s" % version)
        os.makedirs(d, exist_ok=True)
        return d

    def _link_current(self, version):
        link = os.path.join(self.tmp, "payload")
        if os.path.lexists(link):
            os.unlink(link)
        os.symlink("payload-%s" % version, link)

    def test_no_root(self):
        self.assertEqual(su.rollback_candidate(None), (False, "no-root"))
        self.assertEqual(su.rollback_candidate(""), (False, "no-root"))

    def test_no_current_symlink(self):
        self._mkpayload("1.6.1.20260929")
        self.assertEqual(su.rollback_candidate(self.tmp), (False, "no-current"))

    def test_none_other_than_current(self):
        self._mkpayload("1.7.0.20260929")
        self._link_current("1.7.0.20260929")
        self.assertEqual(su.rollback_candidate(self.tmp), (False, "none"))

    def test_exactly_one_other(self):
        self._mkpayload("1.6.1.20260929")
        self._mkpayload("1.7.0.20260929")
        self._link_current("1.7.0.20260929")
        ok, val = su.rollback_candidate(self.tmp)
        self.assertTrue(ok)
        self.assertEqual(val, "payload-1.6.1.20260929")

    def test_ambiguous_refuses(self):
        self._mkpayload("1.5.0.20260929")
        self._mkpayload("1.6.1.20260929")
        self._mkpayload("1.7.0.20260929")
        self._link_current("1.7.0.20260929")
        self.assertEqual(su.rollback_candidate(self.tmp), (False, "ambiguous"))

    def test_version_from_payload_name(self):
        self.assertEqual(su.version_from_payload_name("payload-1.6.1.20260929"), "1.6.1.20260929")
        self.assertIsNone(su.version_from_payload_name("not-a-payload-dir"))
        self.assertIsNone(su.version_from_payload_name(None))


# --- check_latest_release (mocked urllib only) -------------------------------


class _FakeResponse:
    def __init__(self, body):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class CheckLatestRelease(unittest.TestCase):
    def test_no_repo_configured(self):
        with self.assertRaises(su.SelfUpdateError):
            su.check_latest_release(None)

    @mock.patch("selfupdate.urllib.request.urlopen")
    def test_success(self, mock_urlopen):
        body = (b'{"tag_name":"v1.7.0.20260929","name":"1.7.0",'
                b'"html_url":"https://github.com/x/y/releases/tag/v1.7.0.20260929",'
                b'"tarball_url":"https://api.github.com/repos/x/y/tarball/v1.7.0.20260929",'
                b'"published_at":"2026-09-29T12:00:00Z"}')
        mock_urlopen.return_value = _FakeResponse(body)
        rel = su.check_latest_release("x86Since8088/linux-cockpit-remote-desktop-guac")
        self.assertEqual(rel["tag_name"], "v1.7.0.20260929")
        self.assertEqual(rel["release_name"], "1.7.0")
        self.assertTrue(rel["tarball_url"].endswith("v1.7.0.20260929"))

    @mock.patch("selfupdate.urllib.request.urlopen")
    def test_404_is_no_releases_yet(self, mock_urlopen):
        import urllib.error
        mock_urlopen.side_effect = urllib.error.HTTPError("url", 404, "Not Found", {}, None)
        with self.assertRaises(su.SelfUpdateError) as ctx:
            su.check_latest_release("x86Since8088/linux-cockpit-remote-desktop-guac")
        self.assertIn("no releases", str(ctx.exception))

    @mock.patch("selfupdate.urllib.request.urlopen")
    def test_network_error(self, mock_urlopen):
        import urllib.error
        mock_urlopen.side_effect = urllib.error.URLError("boom")
        with self.assertRaises(su.SelfUpdateError):
            su.check_latest_release("x86Since8088/linux-cockpit-remote-desktop-guac")

    @mock.patch("selfupdate.urllib.request.urlopen")
    def test_no_tag_name_in_json(self, mock_urlopen):
        mock_urlopen.return_value = _FakeResponse(b'{"name": "oops"}')
        with self.assertRaises(su.SelfUpdateError):
            su.check_latest_release("x86Since8088/linux-cockpit-remote-desktop-guac")


# --- SelfUpdate.apply()/.rollback() exit-code mapping (mocked subprocess) ----


class ApplyMapping(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cache_path = os.path.join(self.tmp, "update-status.json")
        self.su = su.SelfUpdate(repo="x/y", cache_path=self.cache_path)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_nothing_cached_refuses_without_touching_subprocess(self):
        with mock.patch("selfupdate.subprocess.run") as mock_run:
            ok, detail, rolled_back = self.su.apply()
        self.assertFalse(ok)
        self.assertIsNone(rolled_back)
        self.assertIn("no update available", detail)
        mock_run.assert_not_called()

    def test_cached_but_not_available_refuses(self):
        su.write_cache({"update_available": False, "latest_version": "1.7.0.20260929"},
                       self.cache_path)
        ok, detail, rolled_back = self.su.apply()
        self.assertFalse(ok)
        self.assertIsNone(rolled_back)

    def _cache_update_available(self):
        su.write_cache({"update_available": True, "latest_version": "1.7.0.20260929"},
                       self.cache_path)

    @mock.patch("selfupdate.subprocess.run")
    def test_success(self, mock_run):
        self._cache_update_available()
        mock_run.return_value = mock.Mock(returncode=0)
        ok, detail, rolled_back = self.su.apply()
        self.assertTrue(ok)
        self.assertIn("1.7.0.20260929", detail)
        args, kwargs = mock_run.call_args
        self.assertEqual(args[0], ["systemctl", "start", su.APPLY_UNIT])

    def _failed_run(self, code):
        exc = subprocess.CalledProcessError(1, ["systemctl"], stderr=b"boom")
        return exc, code

    @mock.patch("selfupdate._exec_main_status")
    @mock.patch("selfupdate.subprocess.run")
    def test_exit_2_maps_to_no_update_available(self, mock_run, mock_status):
        self._cache_update_available()
        exc, code = self._failed_run("2")
        mock_run.side_effect = exc
        mock_status.return_value = code
        ok, detail, rolled_back = self.su.apply()
        self.assertFalse(ok)
        self.assertIsNone(rolled_back)
        self.assertIn("no update available", detail)

    @mock.patch("selfupdate._exec_main_status")
    @mock.patch("selfupdate.subprocess.run")
    def test_exit_3_is_safe_untouched(self, mock_run, mock_status):
        self._cache_update_available()
        exc, code = self._failed_run("3")
        mock_run.side_effect = exc
        mock_status.return_value = code
        ok, detail, rolled_back = self.su.apply()
        self.assertFalse(ok)
        self.assertIsNone(rolled_back)

    @mock.patch("selfupdate._exec_main_status")
    @mock.patch("selfupdate.subprocess.run")
    def test_exit_4_is_rolled_back_true(self, mock_run, mock_status):
        self._cache_update_available()
        exc, code = self._failed_run("4")
        mock_run.side_effect = exc
        mock_status.return_value = code
        ok, detail, rolled_back = self.su.apply()
        self.assertFalse(ok)
        self.assertTrue(rolled_back)
        self.assertIn("rolled back", detail)

    @mock.patch("selfupdate._exec_main_status")
    @mock.patch("selfupdate.subprocess.run")
    def test_exit_5_is_rolled_back_false(self, mock_run, mock_status):
        self._cache_update_available()
        exc, code = self._failed_run("5")
        mock_run.side_effect = exc
        mock_status.return_value = code
        ok, detail, rolled_back = self.su.apply()
        self.assertFalse(ok)
        self.assertFalse(rolled_back)
        self.assertIn("needs a human", detail)

    @mock.patch("selfupdate.subprocess.run")
    def test_timeout_is_rolled_back_false(self, mock_run):
        self._cache_update_available()
        mock_run.side_effect = subprocess.TimeoutExpired(cmd="systemctl", timeout=300)
        ok, detail, rolled_back = self.su.apply()
        self.assertFalse(ok)
        self.assertFalse(rolled_back)


class RollbackMapping(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, "payload-1.6.1.20260929"))
        os.makedirs(os.path.join(self.tmp, "payload-1.7.0.20260929"))
        os.symlink("payload-1.7.0.20260929", os.path.join(self.tmp, "payload"))
        self.su = su.SelfUpdate(repo="x/y")
        self._patch_root = mock.patch("selfupdate.install_root", return_value=self.tmp)
        self._patch_root.start()

    def tearDown(self):
        self._patch_root.stop()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_no_root_refuses(self):
        self._patch_root.stop()
        with mock.patch("selfupdate.install_root", return_value=None):
            ok, detail, rolled_back = self.su.rollback()
        self._patch_root.start()
        self.assertFalse(ok)
        self.assertIsNone(rolled_back)

    def test_ambiguous_refuses_without_touching_subprocess(self):
        os.makedirs(os.path.join(self.tmp, "payload-1.5.0.20260929"))
        with mock.patch("selfupdate.subprocess.run") as mock_run:
            ok, detail, rolled_back = self.su.rollback()
        self.assertFalse(ok)
        self.assertIsNone(rolled_back)
        mock_run.assert_not_called()

    @mock.patch("selfupdate.subprocess.run")
    def test_success(self, mock_run):
        mock_run.return_value = mock.Mock(returncode=0)
        ok, detail, rolled_back = self.su.rollback()
        self.assertTrue(ok)
        self.assertIn("1.6.1.20260929", detail)

    @mock.patch("selfupdate._exec_main_status")
    @mock.patch("selfupdate.subprocess.run")
    def test_exit_2_no_earlier_version(self, mock_run, mock_status):
        mock_run.side_effect = subprocess.CalledProcessError(1, ["systemctl"], stderr=b"x")
        mock_status.return_value = "2"
        ok, detail, rolled_back = self.su.rollback()
        self.assertFalse(ok)
        self.assertIsNone(rolled_back)
        self.assertIn("no earlier version", detail)

    @mock.patch("selfupdate._exec_main_status")
    @mock.patch("selfupdate.subprocess.run")
    def test_exit_3_needs_a_human(self, mock_run, mock_status):
        mock_run.side_effect = subprocess.CalledProcessError(1, ["systemctl"], stderr=b"x")
        mock_status.return_value = "3"
        ok, detail, rolled_back = self.su.rollback()
        self.assertFalse(ok)
        self.assertFalse(rolled_back)


# --- control.py dispatch for the four ops (FakeSelfUpdate injection) --------


class FakeSelfUpdate:
    """Stand-in for relay/selfupdate.py's SelfUpdate: records calls and returns
    canned results, so handle_control()'s POLICY (admin gate, typed-hostname
    confirm) is tested with no systemctl/network I/O -- the same injection
    contract as unlock/deskui in test_control.py."""

    def __init__(self, hostname="testhost", status=None, check=None,
                apply_result=(True, "updated to 1.7.0.20260929 and healthy", False),
                rollback_result=(True, "rolled back to 1.6.1.20260929 and healthy", False)):
        self.hostname = hostname
        self._status = status or {"ok": True, "update_available": False}
        self._check = check or dict(self._status, rate_limited=False)
        self._apply_result = apply_result
        self._rollback_result = rollback_result
        self.apply_calls = 0
        self.rollback_calls = 0

    def status(self):
        return self._status

    def check_now(self):
        return self._check

    def apply(self):
        self.apply_calls += 1
        return self._apply_result

    def rollback(self):
        self.rollback_calls += 1
        return self._rollback_result


class ControlDispatchStatusCheck(unittest.TestCase):
    def test_status_unavailable_without_controller(self):
        r = C.handle_control({"op": "update-status"}, 1000, None, None, False)
        self.assertFalse(r["ok"])
        self.assertIn("not available", r["error"])

    def test_status_passthrough(self):
        d = FakeSelfUpdate(status={"ok": True, "update_available": True, "latest_version": "1.7.0.20260929"})
        r = C.handle_control({"op": "update-status"}, 1000, None, None, False, selfupdate=d)
        self.assertTrue(r["ok"])
        self.assertTrue(r["update_available"])

    def test_status_probe_error_does_not_crash(self):
        class Boom(FakeSelfUpdate):
            def status(self):
                raise RuntimeError("kaboom")
        r = C.handle_control({"op": "update-status"}, 1000, None, None, False, selfupdate=Boom())
        self.assertFalse(r["ok"])
        self.assertIn("kaboom", r["error"])

    def test_check_rate_limited_passthrough(self):
        d = FakeSelfUpdate(check={"ok": True, "update_available": False, "rate_limited": True})
        r = C.handle_control({"op": "update-check"}, 1000, None, None, False, selfupdate=d)
        self.assertTrue(r["ok"])
        self.assertTrue(r["rate_limited"])

    def test_check_not_available_without_controller(self):
        r = C.handle_control({"op": "update-check"}, 1000, None, None, True)
        self.assertFalse(r["ok"])
        self.assertIn("not available", r["error"])


class ControlDispatchApply(unittest.TestCase):
    def _ctl(self, req, admin, d):
        return C.handle_control(req, 1000, None, None, admin, selfupdate=d)

    def test_unavailable_without_controller(self):
        r = self._ctl({"op": "update-apply"}, True, None)
        self.assertFalse(r["ok"]); self.assertIn("not available", r["error"])

    def test_not_admin_refused_before_any_call(self):
        d = FakeSelfUpdate()
        r = self._ctl({"op": "update-apply", "confirm": "testhost"}, False, d)
        self.assertFalse(r["ok"])
        self.assertIn("administrative access", r["error"])
        self.assertEqual(d.apply_calls, 0)

    def test_missing_confirm_needs_confirm(self):
        d = FakeSelfUpdate(hostname="edt1")
        r = self._ctl({"op": "update-apply"}, True, d)
        self.assertFalse(r["ok"])
        self.assertTrue(r["need_confirm"])
        self.assertEqual(r["hostname"], "edt1")
        self.assertEqual(d.apply_calls, 0)

    def test_wrong_confirm_needs_confirm(self):
        d = FakeSelfUpdate(hostname="edt1")
        r = self._ctl({"op": "update-apply", "confirm": "not-edt1"}, True, d)
        self.assertFalse(r["ok"]); self.assertTrue(r["need_confirm"])
        self.assertEqual(d.apply_calls, 0)

    def test_nothing_to_apply(self):
        d = FakeSelfUpdate(hostname="edt1", apply_result=(False, "no update available", None))
        r = self._ctl({"op": "update-apply", "confirm": "edt1"}, True, d)
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"], "no update available")
        self.assertNotIn("rolled_back", r)
        self.assertEqual(d.apply_calls, 1)

    def test_success(self):
        d = FakeSelfUpdate(hostname="edt1",
                           apply_result=(True, "updated to 1.7.0.20260929 and healthy", False))
        r = self._ctl({"op": "update-apply", "confirm": "edt1"}, True, d)
        self.assertTrue(r["ok"])
        self.assertEqual(r["detail"], "updated to 1.7.0.20260929 and healthy")
        self.assertNotIn("rolled_back", r)

    def test_auto_rolled_back(self):
        d = FakeSelfUpdate(hostname="edt1",
                           apply_result=(False, "update failed health and was rolled back", True))
        r = self._ctl({"op": "update-apply", "confirm": "edt1"}, True, d)
        self.assertFalse(r["ok"])
        self.assertTrue(r["rolled_back"])
        self.assertIn("detail", r)

    def test_catastrophic_rollback_also_failed(self):
        d = FakeSelfUpdate(hostname="edt1",
                           apply_result=(False, "update failed AND rollback failed", False))
        r = self._ctl({"op": "update-apply", "confirm": "edt1"}, True, d)
        self.assertFalse(r["ok"])
        self.assertFalse(r["rolled_back"])


class ControlDispatchRollback(unittest.TestCase):
    def _ctl(self, req, admin, d):
        return C.handle_control(req, 1000, None, None, admin, selfupdate=d)

    def test_unavailable_without_controller(self):
        r = self._ctl({"op": "update-rollback"}, True, None)
        self.assertFalse(r["ok"]); self.assertIn("not available", r["error"])

    def test_not_admin_refused_before_any_call(self):
        d = FakeSelfUpdate()
        r = self._ctl({"op": "update-rollback"}, False, d)
        self.assertFalse(r["ok"])
        self.assertIn("administrative access", r["error"])
        self.assertEqual(d.rollback_calls, 0)

    def test_no_confirmation_needed_for_admin(self):
        # deliberate asymmetry: rollback is the recovery action and carries no
        # typed-hostname confirmation, unlike update-apply.
        d = FakeSelfUpdate(rollback_result=(True, "rolled back to 1.6.1.20260929 and healthy", False))
        r = self._ctl({"op": "update-rollback"}, True, d)
        self.assertTrue(r["ok"])
        self.assertEqual(d.rollback_calls, 1)

    def test_nothing_to_roll_back_to(self):
        d = FakeSelfUpdate(rollback_result=(False, "no earlier version is available to "
                                            "roll back to on this host", None))
        r = self._ctl({"op": "update-rollback"}, True, d)
        self.assertFalse(r["ok"])
        self.assertIn("no earlier version", r["error"])
        self.assertNotIn("rolled_back", r)

    def test_rollback_failed(self):
        d = FakeSelfUpdate(rollback_result=(False, "rollback failed; needs a human", False))
        r = self._ctl({"op": "update-rollback"}, True, d)
        self.assertFalse(r["ok"])
        self.assertFalse(r["rolled_back"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
