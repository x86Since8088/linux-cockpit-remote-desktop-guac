# SPDX-License-Identifier: BSD-3-Clause
import os, sys, unittest
sys.path.insert(0, os.path.dirname(__file__))
import control as C
import session_registry as SR


class Live(unittest.TestCase):
    def test_register_terminate(self):
        live = C.LiveConnections(); flag = {"killed": False}
        live.register("u1", lambda: flag.__setitem__("killed", True))
        self.assertTrue(live.has("u1"))
        self.assertTrue(live.terminate("u1")); self.assertTrue(flag["killed"])
    def test_terminate_unknown(self):
        self.assertFalse(C.LiveConnections().terminate("nope"))


class ListOp(unittest.TestCase):
    def setUp(self):
        self.reg = SR.SessionRegistry(); self.live = C.LiveConnections()
        self.reg.open("a", 1000, "virtual", now=0); self.reg.mark_active("a", now=1)
        self.reg.open("b", 1005, "isolated", now=0)
        self.live.register("a", lambda: None)
    def test_user_sees_only_own(self):
        r = C.handle_control({"op":"list"}, 1000, self.reg, self.live, is_admin=False)
        ids = {s["uuid"] for s in r["sessions"]}
        self.assertEqual(ids, {"a"})
        self.assertTrue(r["sessions"][0]["live"])
        self.assertTrue(r["sessions"][0]["mine"])
    def test_admin_sees_all(self):
        r = C.handle_control({"op":"list"}, 0, self.reg, self.live, is_admin=True)
        self.assertEqual({s["uuid"] for s in r["sessions"]}, {"a","b"})


class TerminateOp(unittest.TestCase):
    def setUp(self):
        self.reg = SR.SessionRegistry(); self.live = C.LiveConnections()
        self.reg.open("a", 1000, "virtual", now=0)
        self.killed = {"a": False}
        self.live.register("a", lambda: self.killed.__setitem__("a", True))
    def test_owner_terminates(self):
        r = C.handle_control({"op":"terminate","uuid":"a"}, 1000, self.reg, self.live, is_admin=False)
        self.assertTrue(r["ok"]); self.assertTrue(self.killed["a"])
        self.assertIsNone(self.reg.owner("a"))            # removed from registry
    def test_foreign_terminate_refused(self):
        r = C.handle_control({"op":"terminate","uuid":"a"}, 1005, self.reg, self.live, is_admin=False)
        self.assertFalse(r["ok"]); self.assertFalse(self.killed["a"])  # not killed
    def test_admin_terminates_any(self):
        r = C.handle_control({"op":"terminate","uuid":"a"}, 0, self.reg, self.live, is_admin=True)
        self.assertTrue(r["ok"]); self.assertTrue(self.killed["a"])
    def test_terminate_requires_uuid(self):
        self.assertFalse(C.handle_control({"op":"terminate"}, 0, self.reg, self.live, True)["ok"])


class PruneOp(unittest.TestCase):
    def setUp(self):
        self.reg = SR.SessionRegistry(); self.live = C.LiveConnections()
        # a disconnected greeter past the 60s TTL (reapable); a fresh one (kept).
        self.reg.open("old", 1000, "isolated", now=0); self.reg.mark_disconnected("old", now=0)
        self.reg.open("new", 1000, "isolated", now=1000); self.reg.mark_disconnected("new", now=1000)
    def test_admin_prunes_stale_only(self):
        r = C.handle_control({"op":"prune","now":1000,"greeter_ttl":60}, 0,
                             self.reg, self.live, is_admin=True)
        self.assertTrue(r["ok"])
        self.assertEqual({e["uuid"] for e in r["reaped"]}, {"old"})
        self.assertIsNone(self.reg.owner("old"))       # gone from the registry
        self.assertEqual(self.reg.owner("new"), 1000)  # young greeter kept
    def test_prune_requires_admin(self):
        r = C.handle_control({"op":"prune","now":1000}, 1000, self.reg, self.live, is_admin=False)
        self.assertFalse(r["ok"]); self.assertEqual(self.reg.owner("old"), 1000)  # untouched
    def test_prune_requires_now(self):
        self.assertFalse(C.handle_control({"op":"prune"}, 0, self.reg, self.live, True)["ok"])
    def test_prune_closes_lingering_live(self):
        killed = {"old": False}
        self.live.register("old", lambda: killed.__setitem__("old", True))
        C.handle_control({"op":"prune","now":1000,"greeter_ttl":60}, 0, self.reg, self.live, True)
        self.assertTrue(killed["old"])  # any lingering live conn for a reaped uuid is dropped


class Misc(unittest.TestCase):
    def test_ping(self):
        r = C.handle_control({"op":"ping"}, 1000, SR.SessionRegistry(), C.LiveConnections(), False)
        self.assertTrue(r["ok"]); self.assertEqual(r["uid"], 1000)
    def test_unknown_op(self):
        self.assertFalse(C.handle_control({"op":"wat"}, 0, SR.SessionRegistry(), C.LiveConnections(), True)["ok"])
    def test_malformed(self):
        self.assertFalse(C.handle_control("nope", 0, SR.SessionRegistry(), C.LiveConnections(), True)["ok"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
