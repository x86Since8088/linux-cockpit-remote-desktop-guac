# SPDX-License-Identifier: BSD-3-Clause
# Unit tests for the relay's security-critical pure logic.
import os, sys, unittest
sys.path.insert(0, os.path.dirname(__file__))
import edy_rdp_relay as R
import session_registry as SR


class Codec(unittest.TestCase):
    def test_encode(self):
        self.assertEqual(R.encode("select", "rdp"), "6.select,3.rdp;")
        self.assertEqual(R.encode(""), "0.;")
        self.assertEqual(R.encode("size", 1024, 768, 96), "4.size,4.1024,3.768,2.96;")

    def test_roundtrip_multibyte(self):
        got = []
        tail = R.drain(R.encode("t", "héllo", "日本"), got.append)
        self.assertEqual(tail, "")
        self.assertEqual(got, [["t", "héllo", "日本"]])

    def test_partial_then_complete(self):
        whole = R.encode("a", "bb") + R.encode("c")
        acc, got = "", []
        for ch in whole:
            acc = R.drain(acc + ch, got.append)
        self.assertEqual(got, [["a", "bb"], ["c"]])

    def test_incomplete_returns_buffer(self):
        got = []
        tail = R.drain("6.sele", got.append)   # truncated
        self.assertEqual(got, [])
        self.assertEqual(tail, "6.sele")


class Select(unittest.TestCase):
    def test_new(self):
        self.assertEqual(R.classify_select(["select", "rdp"]), ("new", "rdp"))

    def test_join(self):
        self.assertEqual(R.classify_select(["select", "$abc-123"]), ("join", "abc-123"))

    def test_bad(self):
        self.assertEqual(R.classify_select(["select"])[0], "bad")
        self.assertEqual(R.classify_select(["connect", "x"])[0], "bad")
        self.assertEqual(R.classify_select(["select", ""])[0], "bad")


class Guard(unittest.TestCase):
    def _conn(self, uid):
        return R.Connection(client=None, uid=uid, table=SR.SessionRegistry(),
                            guacd_addr=("127.0.0.1", 4822), admin_group="sudo")

    def test_new_session_allowed(self):
        c = self._conn(1000)
        self.assertEqual(c._guard_upstream(["select", "rdp"]), ["select", "rdp"])

    def test_foreign_join_raises(self):         # I2
        c = self._conn(1005)
        c.table.open("victim", 1000, "virtual", now=0)
        with self.assertRaises(R.Refuse):
            c._guard_upstream(["select", "$victim"])

    def test_own_rejoin_allowed(self):
        c = self._conn(1000)
        c.table.open("mine", 1000, "virtual", now=0)
        self.assertEqual(c._guard_upstream(["select", "$mine"]), ["select", "$mine"])

    def test_console_admin_fallback_marker_strip_vnc_inject(self):
        # root (uid 0) is admin -> the no-token sudo FALLBACK admits console. Console
        # needs an rdpcred (the 3389 gate key); with one, the connect is rewritten to
        # the bridge's loopback VNC target and every gate marker is stripped before
        # guacd sees it. The bridge start is mocked (no real Xvfb/xfreerdp3/x11vnc).
        c = self._conn(0)
        c.arg_names = ["hostname", "port", "password"]

        class _FakeProc:
            def terminate(self): pass
            def wait(self, timeout=None): return 0
            def poll(self): return None
            def kill(self): pass

        orig = R.bridge.start_bridge
        R.bridge.start_bridge = lambda *a, **k: (
            {"VNCHOST": "127.0.0.1", "VNCPORT": "6001", "VNCPASS": "secret"}, _FakeProc())
        try:
            out = c._peek_scenario_from_connect(
                ["connect", "scenario=console", "rdpcred=u" + "\x1f" + "p"])
        finally:
            R.bridge.start_bridge = orig
            if c.desktop_id:
                R.DESKTOP_SLOTS.release(c.desktop_id, c)

        self.assertEqual(c.scenario, "console")
        self.assertEqual(out[0], "connect")
        params = dict(zip(c.arg_names, out[1:]))
        self.assertEqual(params["hostname"], "127.0.0.1")     # VNC target injected
        self.assertEqual(params["port"], "6001")
        self.assertEqual(params["password"], "secret")        # VNC password injected
        # no gate marker leaks to guacd
        self.assertFalse(any(str(x).startswith(("scenario=", "rdpcred=", "sessiontoken="))
                             for x in out))

    def test_console_scenario_refused_for_nonadmin(self):   # I4 server-side gate
        c = self._conn(4242)  # not in sudo
        with self.assertRaises(R.Refuse):
            c._peek_scenario_from_connect(["connect", "v", "scenario=console"])

    def test_parse_guacd_forms(self):
        self.assertEqual(R.parse_guacd("127.0.0.1:4822"), ("127.0.0.1", 4822))
        self.assertEqual(R.parse_guacd("unix:/run/x.sock"), "unix:/run/x.sock")




class AllowList(unittest.TestCase):
    def _conn(self, allow):
        c = R.Connection(client=None, uid=0, table=SR.SessionRegistry(),
                         guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
        c.allow_targets = allow
        c.arg_names = ["hostname", "port", "username"]
        return c

    def test_permitted_target(self):
        c = self._conn({"host.containers.internal:3390"})
        # should not raise
        c._enforce_target(["connect", "host.containers.internal", "3390", "rdplogin"])

    def test_forbidden_target_refused(self):     # SSRF-class
        c = self._conn({"host.containers.internal:3390"})
        with self.assertRaises(R.Refuse):
            c._enforce_target(["connect", "10.0.0.9", "3389", "x"])

    def test_no_allowlist_permits_all(self):
        c = self._conn(None)
        c._enforce_target(["connect", "anywhere", "9999", "x"])  # no raise

class SyncKeepalive(unittest.TestCase):
    def _conn(self):
        return R.Connection(client=None, uid=0, table=SR.SessionRegistry(),
                            guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
    def test_sync_timestamp_captured(self):
        c = self._conn()
        c._watch_downstream(["sync", "12345"])
        self.assertEqual(c.last_sync, "12345")
    def test_no_sync_yet(self):
        c = self._conn()
        self.assertIsNone(c.last_sync)

class UuidNormalization(unittest.TestCase):
    def _conn(self, uid):
        return R.Connection(client=None, uid=uid, table=SR.SessionRegistry(),
                            guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
    def test_owner_can_rejoin_after_ready(self):
        c = self._conn(1000)
        c._watch_downstream(["ready", "$abc-123"])   # guacd emits ready with '$'
        # a join arrives as `select $abc-123` -> classify strips '$' -> 'abc-123'
        self.assertTrue(c.table.may_join("abc-123", 1000))
    def test_foreign_still_refused_after_ready(self):
        c = self._conn(1000)
        c._watch_downstream(["ready", "$abc-123"])
        self.assertFalse(c.table.may_join("abc-123", 1005))


if __name__ == "__main__":
    unittest.main(verbosity=1)
