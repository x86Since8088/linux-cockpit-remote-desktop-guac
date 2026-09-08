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


class RemoteAllowList(unittest.TestCase):
    """The remote-scenario allow-list: fail-closed, IPv4-only, host+port gated."""
    def _set(self, spec):
        R.REMOTE_ALLOW = R.parse_remote_allow(spec)

    def tearDown(self):
        R.REMOTE_ALLOW = []

    def test_empty_denies_all(self):                # fail-closed default
        self._set("")
        self.assertFalse(R.remote_target_allowed("10.0.0.5", 3389))

    def test_exact_host_and_port(self):
        self._set("10.20.0.5:3389")
        self.assertTrue(R.remote_target_allowed("10.20.0.5", 3389))
        self.assertFalse(R.remote_target_allowed("10.20.0.5", 3390))   # port gates
        self.assertFalse(R.remote_target_allowed("10.20.0.9", 3389))   # host gates

    def test_subnet_default_port(self):
        self._set("192.168.2.0/24")
        self.assertTrue(R.remote_target_allowed("192.168.2.50", 3389))
        self.assertFalse(R.remote_target_allowed("192.168.2.50", 3390))  # non-3389 refused
        self.assertFalse(R.remote_target_allowed("10.0.0.1", 3389))      # outside subnet

    def test_any_and_wildcard_port(self):
        self._set("any")
        self.assertTrue(R.remote_target_allowed("8.8.8.8", 3389))
        self.assertFalse(R.remote_target_allowed("8.8.8.8", 3390))       # 'any' still 3389 only
        self._set("any:*")
        self.assertTrue(R.remote_target_allowed("8.8.8.8", 3390))        # any host, any port

    def test_never_a_hostname_or_ipv6(self):        # no DNS rebinding; IPv4 only
        self._set("any:*")
        for bad in ("evil.example.com", "::1", "fe80::1", "10.0.0.5; rm", ""):
            self.assertFalse(R.remote_target_allowed(bad, 3389))


class RemoteScenario(unittest.TestCase):
    """The 'remote' connect path: SSRF gate before the bridge, client-cred only,
    guacd sees only the loopback VNC, no marker leak."""
    def _conn(self, uid=1000):
        c = R.Connection(client=None, uid=uid, table=SR.SessionRegistry(),
                         guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
        c.arg_names = ["hostname", "port", "password"]
        return c

    class _FakeProc:
        def terminate(self): pass
        def wait(self, timeout=None): return 0
        def poll(self): return None
        def kill(self): pass

    def setUp(self):
        self._orig = R.bridge.start_bridge
        self.calls = []
        R.bridge.start_bridge = lambda *a, **k: (
            self.calls.append((a, k)) or
            ({"VNCHOST": "127.0.0.1", "VNCPORT": "6002", "VNCPASS": "s"}, self._FakeProc()))
        R.REMOTE_ALLOW = R.parse_remote_allow("10.20.0.0/24")
        R.REMOTE_ADMIN_ONLY = False

    def tearDown(self):
        R.bridge.start_bridge = self._orig
        R.REMOTE_ALLOW = []
        R.REMOTE_ADMIN_ONLY = False

    def test_allowed_remote_bridges_target_and_injects_loopback(self):
        c = self._conn()
        out = c._peek_scenario_from_connect(
            ["connect", "x", "y", "z", "rdpcred=u\x1fp",
             "remotehost=10.20.0.5:3389", "scenario=remote"])
        try:
            self.assertEqual(c.scenario, "remote")
            host, port = self.calls[-1][0][1], self.calls[-1][0][2]
            self.assertEqual((host, port), ("10.20.0.5", "3389"))   # bridge dials the REMOTE host
            self.assertEqual(self.calls[-1][0][4:6], ("u", "p"))    # client-supplied cred, not relay-managed
            params = dict(zip(c.arg_names, out[1:]))
            self.assertEqual(params["hostname"], "127.0.0.1")       # guacd sees loopback VNC only
            self.assertEqual(params["port"], "6002")
            self.assertFalse(any(str(x).startswith(
                ("scenario=", "rdpcred=", "remotehost=", "sessiontoken=")) for x in out))
            self.assertEqual(c.desktop_id, "remote:10.20.0.5:3389:1000")
        finally:
            if c.desktop_id:
                R.DESKTOP_SLOTS.release(c.desktop_id, c)

    def test_outside_allowlist_refused_before_bridge(self):     # SSRF
        c = self._conn()
        with self.assertRaises(R.Refuse):
            c._peek_scenario_from_connect(
                ["connect", "x", "y", "z", "rdpcred=u\x1fp",
                 "remotehost=10.99.0.1:3389", "scenario=remote"])
        self.assertEqual(self.calls, [])   # a denied target must NOT dial out

    def test_missing_credential_refused(self):
        c = self._conn()
        with self.assertRaises(R.Refuse):
            c._peek_scenario_from_connect(
                ["connect", "x", "y", "z", "remotehost=10.20.0.5:3389", "scenario=remote"])
        self.assertEqual(self.calls, [])

    def test_malformed_target_refused(self):       # hostname / newline / no-port
        for bad in ("evil.com:3389", "10.20.0.5", "10.20.0.5:0", "10.20.0.5:22\n"):
            c = self._conn()
            with self.assertRaises(R.Refuse):
                c._peek_scenario_from_connect(
                    ["connect", "x", "y", "z", "rdpcred=u\x1fp",
                     "remotehost=" + bad, "scenario=remote"])
            self.assertEqual(self.calls, [])

    def test_admin_only_refuses_nonadmin(self):
        R.REMOTE_ADMIN_ONLY = True
        c = self._conn(4242)
        with self.assertRaises(R.Refuse):
            c._peek_scenario_from_connect(
                ["connect", "x", "y", "z", "rdpcred=u\x1fp",
                 "remotehost=10.20.0.5:3389", "scenario=remote"])


class CredentialInjection(unittest.TestCase):
    """A newline/CR/NUL in a client-supplied RDP credential must be refused before it
    can forge a HOST=/PORT= line in the bridge .req (SSRF). Regression for the
    adversarial-review finding; covers virtual/console (loopback) AND remote."""
    class _FakeProc:
        def terminate(self): pass
        def wait(self, timeout=None): return 0
        def poll(self): return None
        def kill(self): pass

    def _conn(self, uid=1000):
        c = R.Connection(client=None, uid=uid, table=SR.SessionRegistry(),
                         guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
        c.arg_names = ["hostname", "port", "password"]
        return c

    def setUp(self):
        self._orig = R.bridge.start_bridge
        self.calls = []
        R.bridge.start_bridge = lambda *a, **k: (
            self.calls.append(a) or
            ({"VNCHOST": "127.0.0.1", "VNCPORT": "6002", "VNCPASS": "s"}, self._FakeProc()))

    def tearDown(self):
        R.bridge.start_bridge = self._orig
        R.REMOTE_ALLOW = []

    def _cleanup(self, c):
        if c.desktop_id:
            R.DESKTOP_SLOTS.release(c.desktop_id, c)
        if c._bridge_counted:
            R.BRIDGE_COUNTER.release(c.uid)

    def test_newline_in_password_virtual_refused(self):     # SSRF via loopback scenario
        c = self._conn()
        with self.assertRaises(R.Refuse):
            c._peek_scenario_from_connect(
                ["connect", "a", "b", "c", "rdpcred=alice\x1fx\nHOST=8.8.8.8\nPORT=22",
                 "scenario=virtual"])
        self.assertEqual(self.calls, [])                    # never dialed

    def test_newline_in_username_refused(self):
        c = self._conn()
        with self.assertRaises(R.Refuse):
            c._peek_scenario_from_connect(
                ["connect", "a", "b", "c", "rdpcred=a\nHOST=8.8.8.8\x1fpw", "scenario=virtual"])
        self.assertEqual(self.calls, [])

    def test_newline_in_remote_credential_refused(self):    # allow-list bypass attempt
        R.REMOTE_ALLOW = R.parse_remote_allow("192.168.2.20:3389")
        c = self._conn()
        with self.assertRaises(R.Refuse):
            c._peek_scenario_from_connect(
                ["connect", "a", "b", "c", "rdpcred=alice\x1fp\nHOST=10.9.9.9\nPORT=3389",
                 "remotehost=192.168.2.20:3389", "scenario=remote"])
        self.assertEqual(self.calls, [])

    def test_clean_credential_still_connects(self):
        c = self._conn()
        try:
            c._peek_scenario_from_connect(
                ["connect", "a", "b", "c", "rdpcred=alice\x1fgoodpass", "scenario=virtual"])
            self.assertEqual(self.calls[-1][1], "127.0.0.1")   # still dials loopback
        finally:
            self._cleanup(c)


class BridgeInjectionDefense(unittest.TestCase):
    """bridge.start_bridge itself rejects a control char in any .req field."""
    def test_bridge_rejects_newline_value(self):
        for i, args in enumerate([
            ("k", "10.0.0.1\nHOST=x", "3389", "nla", "u", "p", "1x1"),
            ("k", "10.0.0.1", "3389", "nla", "u", "p\nHOST=evil", "1x1"),
            ("k", "10.0.0.1", "3389", "nla\nSECURITY=rdp", "u", "p", "1x1"),
        ]):
            with self.assertRaises(R.bridge.BridgeError):
                R.bridge.start_bridge(*args)


class BridgeCap(unittest.TestCase):
    """Per-uid concurrent-bridge cap prevents display-slot exhaustion (DoS)."""
    def test_counter_caps_per_uid(self):
        ctr = R._BridgeCounter()
        got = [ctr.acquire(1000) for _ in range(R.MAX_BRIDGES_PER_UID + 2)]
        self.assertEqual(got.count(True), R.MAX_BRIDGES_PER_UID)   # exactly the cap
        self.assertFalse(got[-1])                                  # excess refused
        ctr.release(1000)
        self.assertTrue(ctr.acquire(1000))                         # a release frees one
        self.assertTrue(ctr.acquire(1001))                         # a different uid is independent


class LockedScreenHint(unittest.TestCase):
    """The console/virtual bridge failure is re-labelled 'screen is locked' only for an
    ACTIVE GRAPHICAL SEAT session that is LOCKED — never a TTY, seatless, or inactive one."""
    def test_locked_graphical_seat(self):
        self.assertTrue(R._session_locked_props(
            "Type=wayland\nActive=yes\nSeat=seat0\nLockedHint=yes\n"))
        self.assertTrue(R._session_locked_props(
            "Type=x11\nActive=yes\nSeat=seat0\nLockedHint=yes\n"))

    def test_not_flagged(self):
        for props in (
            "Type=wayland\nActive=yes\nSeat=seat0\nLockedHint=no\n",   # unlocked
            "Type=tty\nActive=yes\nSeat=seat0\nLockedHint=yes\n",      # a TTY, not the screen
            "Type=wayland\nActive=yes\nSeat=\nLockedHint=yes\n",       # no seat
            "Type=wayland\nActive=no\nSeat=seat0\nLockedHint=yes\n",   # not active
            "",                                                        # empty
        ):
            self.assertFalse(R._session_locked_props(props))


class AuthVerdictDiscriminator(unittest.TestCase):
    """The ONLY dependable credential verdict FreeRDP gives us, and the two
    look-alikes that must NOT be treated as one. Every string below was captured
    from a real xfreerdp3 3.31.0 run against this host's grd."""

    def _m(self, line):
        import bridge
        return bool(bridge.AUTH_ERR_RE.search(line))

    def test_real_auth_failures_match(self):
        for line in (
            "[ERROR][com.freerdp.core] - [nla_recv_pdu]: ERRCONNECT_LOGON_FAILURE [0x00020014]",
            "[ERROR][com.freerdp.core] - [nla_recv_pdu]: ERRCONNECT_ACCOUNT_DISABLED [0x00020011]",
            "[ERROR][com.freerdp.core] - [nla_recv_pdu]: ERRCONNECT_PASSWORD_EXPIRED [0x0002000E]",
        ):
            self.assertTrue(self._m(line), line)

    def test_non_auth_failures_do_not_match(self):
        # Reproduced with NO credential involvement (fake server, malformed
        # TSRequest and truncated DER). Matching these would relabel a transport
        # fault as a rejected password.
        for line in (
            "[ERROR][com.freerdp.core.rdp] - [rdp_recv_callback_int][0x55]: "
            "CONNECTION_STATE_NLA - nla_recv_pdu() fail",
            "[ERROR][com.freerdp.core.rdp] - [rdp_recv_callback_int][0x55]: "
            "CONNECTION_STATE_NLA status STATE_RUN_FAILED [-1]",
            "[ERROR][com.freerdp.core.transport] - [transport_check_fds]: "
            "transport_check_fds: transport->ReceiveCallback() - STATE_RUN_FAILED [-1]",
            "[ERROR][com.freerdp.core] - [nego_connect]: "
            "ERRCONNECT_CONNECT_TRANSPORT_FAILED [0x0002000D]",
            # krb5 noise: emitted before NTLM fallback in BOTH auth and non-auth runs
            "[ERROR][com.winpr.sspi.Kerberos] - [kerberos_AcquireCredentialsHandleA]: "
            "krb5glue_get_init_creds (Client 'rdplogin@AD.EDT1.LAB' not found in "
            "Kerberos database [-1765328378])",
        ):
            self.assertFalse(self._m(line), line)

    def test_anchored_on_the_emitting_function(self):
        # The code named anywhere else in the log is not the verdict.
        self.assertFalse(self._m("some prose mentioning ERRCONNECT_LOGON_FAILURE"))



class SecurityValuesAreAcceptedByFreeRDP(unittest.TestCase):
    """Every security value the relay can emit must be one xfreerdp3 /sec: accepts.

    The greeter scenario shipped "rdstls" for months. RDSTLS is a real protocol,
    but it is not a value /sec: accepts -- xfreerdp3 fails at command-line
    before any network I/O, so the scenario could never connect. It went
    unnoticed because nothing in the UI could select it.
    """

    # xfreerdp3 3.31.0: /sec: rdp|tls|nla|ext|aad, each optionally :on|:off
    ACCEPTED = {"rdp", "tls", "nla", "ext", "aad"}

    def test_every_scenario_security_is_valid(self):
        import re as _re
        with open(R.__file__, encoding="utf-8") as fh:
            src = fh.read()
        body = src[src.index("def _grd_target"):]
        body = body[:body.index("\n    def ")]
        # the 3rd element of each returned tuple is the security value
        vals = _re.findall(r'return \(\s*"[^"]*",\s*"[^"]*",\s*"([^"]+)"', body)
        self.assertTrue(vals, "no security values found -- did _grd_target change shape?")
        for v in vals:
            base = v.split(":")[0]
            self.assertIn(base, self.ACCEPTED | {"negotiate"},
                          "%r is not a /sec: value xfreerdp3 accepts" % v)

    def test_greeter_returns_nla(self):
        """Check the VALUE the greeter branch returns, not whether the word
        appears in the file -- the comment above that branch names rdstls in
        order to explain why it is wrong, and a source-text grep flags that."""
        import re as _re
        with open(R.__file__, encoding="utf-8") as fh:
            src = fh.read()
        m = _re.search(r'if scenario == "greeter":.*?return \(\s*"[^"]*",\s*'
                       r'"([^"]*)",\s*"([^"]+)"', src, _re.S)
        self.assertIsNotNone(m, "greeter branch not found in _grd_target")
        port, sec = m.group(1), m.group(2)
        self.assertEqual(port, "3390")
        self.assertEqual(sec, "nla")



if __name__ == "__main__":
    unittest.main(verbosity=1)
