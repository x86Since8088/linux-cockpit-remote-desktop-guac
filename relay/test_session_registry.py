# SPDX-License-Identifier: BSD-3-Clause
import os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(__file__))
import session_registry as SR


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.r = SR.SessionRegistry()

    def test_open_active_disconnect(self):
        self.r.open("u1", 1000, "virtual", now=0)
        self.assertEqual(self.r.owner("u1"), 1000)
        self.r.mark_active("u1", now=1)
        self.r.mark_disconnected("u1", now=2)
        self.assertEqual(self.r._by_uuid["u1"].state, SR.DISCONNECTED)

    def test_isolation(self):
        self.r.open("u1", 1000, "isolated", now=0)
        self.assertTrue(self.r.may_join("u1", 1000))
        self.assertFalse(self.r.may_join("u1", 1005))


class GreeterReap(unittest.TestCase):
    def setUp(self):
        self.r = SR.SessionRegistry()

    def test_isolated_reaped_after_session_ttl(self):   # I29: real desktop, not 60s greeter
        self.r.open("g", 1000, "isolated", now=0)
        self.r.mark_disconnected("g", now=100)
        # isolated is now the caller's OWN headless desktop -> kept well past 60s
        # (reconnectable), reaped only after the full session TTL.
        self.assertEqual(self.r.prune(now=100 + SR.SESSION_DISCONNECT_TTL - 1), [])
        reap = self.r.prune(now=100 + SR.SESSION_DISCONNECT_TTL + 1)
        self.assertEqual(len(reap), 1)
        self.assertEqual(reap[0][0], "g")

    def test_greeter_NOT_reaped_if_logged_on(self):
        self.r.open("g", 1000, "isolated", now=0)
        self.r.mark_logged_on("g", now=5)
        self.r.mark_disconnected("g", now=100)
        self.assertEqual(self.r.prune(now=200), [])   # 100s later, still kept (logged on)
        # but reaped after the longer session TTL
        reap = self.r.prune(now=100 + SR.SESSION_DISCONNECT_TTL + 1)
        self.assertEqual(len(reap), 1)

    def test_stuck_connecting_reaped(self):
        self.r.open("c", 1000, "virtual", now=0)   # never active
        self.assertEqual(self.r.prune(now=SR.CONNECTING_TTL - 1), [])
        self.assertEqual(len(self.r.prune(now=SR.CONNECTING_TTL + 1)), 1)


class EphemeralReap(unittest.TestCase):
    """Non-resumable scenarios (mirror/console, remote, vnc) hold no backend once
    disconnected, so a non-live entry is reaped promptly instead of lingering for
    the 15-min session TTL -- this is what stops duplicated mirror sessions from
    piling up in Active Sessions."""
    def setUp(self):
        self.r = SR.SessionRegistry()

    def test_console_reaped_promptly(self):
        self.r.open("m", 1000, "console", now=0)
        self.r.mark_active("m", now=1)
        self.r.mark_disconnected("m", now=10)
        # still within the short ephemeral TTL -> kept
        self.assertEqual(self.r.prune(now=10 + SR.EPHEMERAL_DISCONNECT_TTL - 1), [])
        reap = self.r.prune(now=10 + SR.EPHEMERAL_DISCONNECT_TTL + 1)
        self.assertEqual([(e[0], e[2]) for e in reap], [("m", "console")])

    def test_console_gone_well_before_session_ttl(self):
        # a disconnected mirror must NOT survive to the 15-min session TTL
        self.r.open("m", 1000, "console", now=0)
        self.r.mark_disconnected("m", now=0)
        self.assertEqual(len(self.r.prune(now=SR.EPHEMERAL_DISCONNECT_TTL + 1)), 1)

    def test_remote_and_vnc_are_ephemeral(self):
        self.r.open("r", 1000, "remote", now=0); self.r.mark_disconnected("r", now=0)
        self.r.open("n", 1000, "vnc", now=0); self.r.mark_disconnected("n", now=0)
        reap = self.r.prune(now=SR.EPHEMERAL_DISCONNECT_TTL + 1)
        self.assertEqual({e[0] for e in reap}, {"r", "n"})

    def test_reconnectable_not_reaped_early(self):
        # virtual/isolated are non-live too but stay for the long TTL (resumable)
        self.r.open("v", 1000, "virtual", now=0); self.r.mark_disconnected("v", now=0)
        self.r.open("i", 1000, "isolated", now=0); self.r.mark_disconnected("i", now=0)
        self.assertEqual(self.r.prune(now=SR.EPHEMERAL_DISCONNECT_TTL + 1), [])

    def test_ephemeral_ttl_is_tunable(self):
        self.r.open("m", 1000, "console", now=0); self.r.mark_disconnected("m", now=0)
        self.assertEqual(self.r.prune(now=20, ephemeral_ttl=30), [])       # under override
        self.assertEqual(len(self.r.prune(now=40, ephemeral_ttl=30)), 1)   # past override


class Reconnect(unittest.TestCase):
    def setUp(self):
        self.r = SR.SessionRegistry()

    def test_virtual_reconnectable(self):
        self.r.open("v", 1000, "virtual", now=0)
        self.r.mark_active("v", now=1)
        self.r.mark_disconnected("v", now=10)
        s = self.r.reusable_session(1000, "virtual", now=20)
        self.assertIsNotNone(s); self.assertEqual(s.uuid, "v")

    def test_reconnect_only_for_owner(self):
        self.r.open("v", 1000, "virtual", now=0)
        self.r.mark_disconnected("v", now=10)
        self.assertIsNone(self.r.reusable_session(1005, "virtual", now=20))

    def test_bare_greeter_not_reusable(self):
        self.r.open("g", 1000, "isolated", now=0)
        self.r.mark_disconnected("g", now=10)         # never logged on
        self.assertIsNone(self.r.reusable_session(1000, "isolated", now=20))

    def test_logged_on_isolated_reusable(self):
        self.r.open("g", 1000, "isolated", now=0)
        self.r.mark_logged_on("g", now=5)
        self.r.mark_disconnected("g", now=10)
        self.assertIsNotNone(self.r.reusable_session(1000, "isolated", now=20))

    def test_stale_disconnect_not_reusable(self):
        self.r.open("v", 1000, "virtual", now=0)
        self.r.mark_disconnected("v", now=10)
        self.assertIsNone(self.r.reusable_session(1000, "virtual",
                          now=10 + SR.SESSION_DISCONNECT_TTL + 1))


class Persistence(unittest.TestCase):
    def test_survives_reload(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "sub", "sessions.json")
            r1 = SR.SessionRegistry(path)
            r1.open("u", 1000, "virtual", now=0)
            r1.mark_logged_on("u", now=1)
            r2 = SR.SessionRegistry(path)     # fresh instance, same file
            self.assertEqual(r2.owner("u"), 1000)
            self.assertTrue(r2._by_uuid["u"].logged_on)


if __name__ == "__main__":
    unittest.main(verbosity=1)
