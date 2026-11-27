# SPDX-License-Identifier: BSD-3-Clause
# Unit tests for the relay's security-critical pure logic.
import base64, os, sys, time, unittest
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


class SeatedSessionPredicate(unittest.TestCase):
    """_is_seated_graphical_session() is the pure per-session classifier
    seated_uids() applies to each loginctl show-session property dict --
    no subprocess involved, same style as LockedScreenHint above."""
    def test_seated_graphical(self):
        self.assertTrue(R._is_seated_graphical_session(
            {"Type": "wayland", "Active": "yes", "Seat": "seat0", "Class": "user"}))
        self.assertTrue(R._is_seated_graphical_session(
            {"Type": "x11", "Active": "yes", "Seat": "seat0", "Class": "user"}))

    def test_not_seated(self):
        for props in (
            {"Type": "wayland", "Active": "yes", "Seat": "seat0", "Class": "greeter"},
            {"Type": "tty", "Active": "yes", "Seat": "seat0", "Class": "user"},
            {"Type": "wayland", "Active": "yes", "Seat": "", "Class": "user"},
            {"Type": "wayland", "Active": "no", "Seat": "seat0", "Class": "user"},
            {},
        ):
            self.assertFalse(R._is_seated_graphical_session(props))


class ShadowGateDecision(unittest.TestCase):
    """shadow_gate_required() encodes the actual security decision -- pure,
    no I/O -- so it is exercised directly with literal seated-set/requester
    combinations, the same way LockedScreenHint drives its pure helper."""
    def test_not_required_when_nobody_seated(self):
        self.assertFalse(R.shadow_gate_required(set(), 1000))

    def test_not_required_when_only_requester_seated(self):
        self.assertFalse(R.shadow_gate_required({1000}, 1000))

    def test_required_when_a_different_uid_seated(self):
        self.assertTrue(R.shadow_gate_required({1000, 2000}, 1000))
        self.assertTrue(R.shadow_gate_required({2000}, 1000))

    def test_required_when_undetermined(self):   # fail closed, like is_admin()
        self.assertTrue(R.shadow_gate_required(None, 1000))


class ConsoleShadowGate(unittest.TestCase):
    """Integration-level: drives the real _peek_scenario_from_connect for
    scenario=console with seated_uids() monkey-patched, the same style Guard
    already uses for R.bridge.start_bridge."""

    class _FakeProc:
        def terminate(self): pass
        def wait(self, timeout=None): return 0
        def poll(self): return None
        def kill(self): pass

    def _conn(self, uid, admin_group="sudo", shadow_group="cockpit-guac-rdp-shadow"):
        c = R.Connection(client=None, uid=uid, table=SR.SessionRegistry(),
                         guacd_addr=("127.0.0.1", 4822), admin_group=admin_group,
                         shadow_group=shadow_group)
        c.arg_names = ["hostname", "port", "password"]
        return c

    def _connect_console(self, c):
        orig_bridge = R.bridge.start_bridge
        R.bridge.start_bridge = lambda *a, **k: (
            {"VNCHOST": "127.0.0.1", "VNCPORT": "6001", "VNCPASS": "secret"},
            self._FakeProc())
        try:
            return c._peek_scenario_from_connect(
                ["connect", "scenario=console", "rdpcred=u" + "\x1f" + "p"])
        finally:
            R.bridge.start_bridge = orig_bridge
            if c.desktop_id:
                R.DESKTOP_SLOTS.release(c.desktop_id, c)
            if c._bridge_counted:
                R.BRIDGE_COUNTER.release(c.uid)

    def test_nobody_seated_admin_only_gate_applies(self):
        # uid 0 would pass is_admin() unconditionally regardless of the shadow
        # gate's own exemption logic, so a non-root admin (not a shadow-group
        # member) is used here -- this actually proves the gate was SKIPPED,
        # not merely that it ran and trivially passed because the caller is
        # root (found by review: the original version of this test used uid 0
        # and could not tell the two apart).
        c = self._conn(4242)
        orig_seated, orig_admin = R.seated_uids, R.is_admin
        R.seated_uids = lambda: set()
        R.is_admin = lambda uid, group="sudo": group == "sudo"   # admin, NOT a shadow member
        try:
            self._connect_console(c)   # must not raise: nobody seated, gate does not apply
        finally:
            R.seated_uids, R.is_admin = orig_seated, orig_admin

    def test_same_user_seated_allowed_without_shadow_membership(self):
        c = self._conn(4242)   # see test_nobody_seated_admin_only_gate_applies for why not uid 0
        orig_seated, orig_admin = R.seated_uids, R.is_admin
        R.seated_uids = lambda: {4242}
        R.is_admin = lambda uid, group="sudo": group == "sudo"   # admin, NOT a shadow member
        try:
            self._connect_console(c)   # must not raise: requester is the one seated
        finally:
            R.seated_uids, R.is_admin = orig_seated, orig_admin

    def test_different_user_seated_and_not_in_shadow_group_refused(self):
        c = self._conn(4242)
        orig_seated, orig_admin = R.seated_uids, R.is_admin
        R.seated_uids = lambda: {1000}
        # admin (so the EXISTING admin gate passes) but not a shadow-group member
        R.is_admin = lambda uid, group="sudo": group == "sudo"
        try:
            with self.assertRaises(R.Refuse):
                self._connect_console(c)
        finally:
            R.seated_uids, R.is_admin = orig_seated, orig_admin

    def test_different_user_seated_and_in_shadow_group_allowed(self):
        c = self._conn(4242)
        orig_seated, orig_admin = R.seated_uids, R.is_admin
        R.seated_uids = lambda: {1000}
        R.is_admin = lambda uid, group="sudo": True   # admin AND shadow-group member
        try:
            self._connect_console(c)   # must not raise
        finally:
            R.seated_uids, R.is_admin = orig_seated, orig_admin

    def test_seated_undetermined_fails_closed_unless_shadow_member(self):
        orig_seated, orig_admin = R.seated_uids, R.is_admin
        R.seated_uids = lambda: None   # categorical failure -- cannot rule out someone else
        try:
            R.is_admin = lambda uid, group="sudo": group == "sudo"   # admin, not shadow member
            c = self._conn(4242)
            with self.assertRaises(R.Refuse):
                self._connect_console(c)

            R.is_admin = lambda uid, group="sudo": True   # admin AND shadow member
            c = self._conn(4242)
            self._connect_console(c)   # must not raise
        finally:
            R.seated_uids, R.is_admin = orig_seated, orig_admin

    def test_shadow_group_empty_disables_gate(self):
        c = self._conn(4242, shadow_group="")
        orig_seated, orig_admin = R.seated_uids, R.is_admin
        R.seated_uids = lambda: {1000}   # a different uid IS seated
        R.is_admin = lambda uid, group="sudo": group == "sudo"   # admin, not a shadow member
        try:
            self._connect_console(c)   # feature off -> admin gate alone is enough
        finally:
            R.seated_uids, R.is_admin = orig_seated, orig_admin


class SeatedUidsSubprocessHandling(unittest.TestCase):
    """Drives the REAL seated_uids() against a fake subprocess.run -- the one
    thing every ConsoleShadowGate test above deliberately bypasses by
    monkey-patching seated_uids() itself away. This is what actually catches a
    regression in the parsing/error-handling glue, not just the gate's policy
    given a canned seated-uid result."""

    class _Result:
        def __init__(self, returncode=0, stdout=""):
            self.returncode = returncode
            self.stdout = stdout

    def _run_with(self, fake_run):
        orig = R.subprocess.run
        R.subprocess.run = fake_run
        try:
            return R.seated_uids()
        finally:
            R.subprocess.run = orig

    def test_list_sessions_nonzero_is_categorical_failure(self):
        self.assertIsNone(self._run_with(lambda *a, **k: self._Result(returncode=1)))

    def test_list_sessions_raises_is_categorical_failure(self):
        def fake_run(*a, **k):
            raise OSError("no loginctl")
        self.assertIsNone(self._run_with(fake_run))

    def test_clean_success_returns_seated_uid(self):
        def fake_run(argv, **k):
            if argv[1] == "list-sessions":
                return self._Result(returncode=0, stdout="2 1001 seat0\n")
            return self._Result(returncode=0, stdout=(
                "Type=wayland\nActive=yes\nSeat=seat0\nClass=user\nUser=1001\n"))
        self.assertEqual(self._run_with(fake_run), {1001})

    def test_show_session_exception_is_categorical_not_skipped(self):
        # Found by review: an earlier version of this function treated a
        # show-session FAILURE the same as "that session doesn't exist" and
        # silently returned an empty set -- exactly the fail-open this guards.
        def fake_run(argv, **k):
            if argv[1] == "list-sessions":
                return self._Result(returncode=0, stdout="2 1001 seat0\n")
            raise OSError("logind hiccup")
        self.assertIsNone(self._run_with(fake_run))

    def test_show_session_nonzero_is_categorical_not_skipped(self):
        def fake_run(argv, **k):
            if argv[1] == "list-sessions":
                return self._Result(returncode=0, stdout="2 1001 seat0\n")
            return self._Result(returncode=1, stdout="")
        self.assertIsNone(self._run_with(fake_run))

    def test_unparseable_user_is_categorical_not_skipped(self):
        def fake_run(argv, **k):
            if argv[1] == "list-sessions":
                return self._Result(returncode=0, stdout="2 1001 seat0\n")
            return self._Result(returncode=0, stdout=(
                "Type=wayland\nActive=yes\nSeat=seat0\nClass=user\nUser=notanumber\n"))
        self.assertIsNone(self._run_with(fake_run))

    def test_greeter_session_excluded_but_others_still_seen(self):
        def fake_run(argv, **k):
            if argv[1] == "list-sessions":
                return self._Result(returncode=0, stdout="1 0 seat0\n2 1001 seat0\n")
            sid = argv[2]
            if sid == "1":
                return self._Result(returncode=0, stdout=(
                    "Type=wayland\nActive=yes\nSeat=seat0\nClass=greeter\nUser=0\n"))
            return self._Result(returncode=0, stdout=(
                "Type=wayland\nActive=yes\nSeat=seat0\nClass=user\nUser=1001\n"))
        self.assertEqual(self._run_with(fake_run), {1001})

    def test_no_sessions_at_all_returns_empty_set(self):
        self.assertEqual(self._run_with(lambda *a, **k: self._Result(returncode=0, stdout="")), set())


class ActiveGraphicalSessionsCount(unittest.TestCase):
    """DesktopUI._active_graphical_sessions() feeds deskui-status, which the I48
    greeter failover reads: the page redirects a console connect to the sign-in
    screen exactly when the count is 0. A loginctl failure must therefore be
    UNKNOWN (None), never 0, and a door-handed-off session (no Seat=) counts."""

    def _count(self, fake_run):
        orig = R.subprocess.run
        R.subprocess.run = fake_run
        try:
            return R.DesktopUI()._active_graphical_sessions()
        finally:
            R.subprocess.run = orig

    class _P:
        def __init__(self, returncode=0, stdout=b""):
            self.returncode = returncode
            self.stdout = stdout

    def _sessions(self, listing, props):
        def fake_run(argv, **k):
            if argv[1] == "list-sessions":
                return self._P(0, listing.encode())
            sid = argv[2]
            if props[sid] is None:
                return self._P(1, b"")
            return self._P(0, props[sid].encode())
        return fake_run

    def test_list_sessions_nonzero_is_unknown_not_zero(self):
        self.assertIsNone(self._count(lambda *a, **k: self._P(1, b"")))

    def test_list_sessions_raises_is_unknown_not_zero(self):
        def boom(*a, **k):
            raise OSError("no loginctl")
        self.assertIsNone(self._count(boom))

    def test_list_sessions_timeout_is_unknown_not_zero(self):
        def slow(*a, **k):
            raise R.subprocess.TimeoutExpired("loginctl", 8)
        self.assertIsNone(self._count(slow))

    def test_show_session_failure_is_unknown_not_skipped(self):
        fake = self._sessions("1 1000 u seat0\n2 1001 v -\n",
                              {"1": "Type=wayland\nActive=yes\nClass=user\n", "2": None})
        self.assertIsNone(self._count(fake))

    def test_genuinely_empty_listing_is_zero(self):
        self.assertEqual(self._count(lambda *a, **k: self._P(0, b"")), 0)

    def test_seatless_door_session_is_counted(self):
        fake = self._sessions("5 1000 eddie -\n",
                              {"5": "Type=wayland\nActive=yes\nClass=user\n"})
        self.assertEqual(self._count(fake), 1)

    def test_greeter_tty_and_inactive_are_not_counted(self):
        fake = self._sessions(
            "1 120 gdm seat0\n2 1000 a seat0\n3 1000 b seat0\n4 1001 c -\n",
            {"1": "Type=wayland\nActive=yes\nClass=greeter\n",
             "2": "Type=tty\nActive=yes\nClass=user\n",
             "3": "Type=x11\nActive=no\nClass=user\n",
             "4": "Type=x11\nActive=yes\nClass=user\n"})
        self.assertEqual(self._count(fake), 1)


class NonAdminAccess(unittest.TestCase):
    """Proves an existing property, for docs/GROUP-ACCESS-MODEL.md: isolated, virtual
    monitor, wayland-vnc and greeter have never had an admin_required path
    (ADMIN_ONLY_SCENARIOS is exactly {"console"} -- console alone), so reaching the
    relay at all is already sufficient for a non-admin, non-elevated caller to use
    them. "Reaching the relay" is modeled here simply as a Connection constructed
    with a non-admin uid and no session_token_admin -- the real gate is the AF_UNIX
    socket's group permission (see docs/GROUP-ACCESS-MODEL.md), which is OS-level and
    out of this module's reach to test directly. Each test just drives
    _peek_scenario_from_connect and lets an unexpected Refuse fail it naturally,
    same as the existing success-path tests in Guard above."""

    NONADMIN_UID = 4242   # not in "sudo" on any real host: is_admin() fails closed (KeyError)

    class _FakeProc:
        def terminate(self): pass
        def wait(self, timeout=None): return 0
        def poll(self): return None
        def kill(self): pass

    def _conn(self):
        c = R.Connection(client=None, uid=self.NONADMIN_UID, table=SR.SessionRegistry(),
                          guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
        c.arg_names = ["hostname", "port", "password"]
        return c

    def _release(self, c):
        if c.desktop_id:
            R.DESKTOP_SLOTS.release(c.desktop_id, c)
        if c._bridge_counted:
            R.BRIDGE_COUNTER.release(c.uid)

    def _fake_bridge(self, port):
        return lambda *a, **k: (
            {"VNCHOST": "127.0.0.1", "VNCPORT": port, "VNCPASS": "x"}, self._FakeProc())

    def test_isolated_no_admin_required(self):
        c = self._conn()
        orig_headless, orig_bridge = R.ensure_headless_session, R.bridge.start_bridge
        R.ensure_headless_session = lambda uid: {
            "PORT": "33001", "USER": "isoluser", "CRED": "isolcred",
            "DESKTOP_ID": "isolated:%d" % uid, "CREATED": None}
        R.bridge.start_bridge = self._fake_bridge("6001")
        try:
            out = c._peek_scenario_from_connect(["connect", "scenario=isolated"])
        finally:
            R.ensure_headless_session, R.bridge.start_bridge = orig_headless, orig_bridge
            self._release(c)
        self.assertEqual(c.scenario, "isolated")
        self.assertEqual(out[0], "connect")

    def test_virtual_no_admin_required(self):
        c = self._conn()
        orig_bridge = R.bridge.start_bridge
        R.bridge.start_bridge = self._fake_bridge("6002")
        try:
            out = c._peek_scenario_from_connect(
                ["connect", "scenario=virtual", "rdpcred=u" + "\x1f" + "p"])
        finally:
            R.bridge.start_bridge = orig_bridge
            self._release(c)
        self.assertEqual(c.scenario, "virtual")
        self.assertEqual(out[0], "connect")

    def test_wayland_vnc_no_admin_required(self):
        c = self._conn()
        orig = R.ensure_waylandvnc_session
        R.ensure_waylandvnc_session = lambda uid: {"HOST": "127.0.0.1", "PORT": "34001"}
        try:
            out = c._peek_scenario_from_connect(["connect", "scenario=wayland-vnc"])
        finally:
            R.ensure_waylandvnc_session = orig
            self._release(c)
        self.assertEqual(c.scenario, "wayland-vnc")
        self.assertEqual(out[0], "connect")

    def test_greeter_no_admin_required(self):
        c = self._conn()
        orig_bridge = R.bridge.start_bridge
        R.bridge.start_bridge = self._fake_bridge("6003")
        try:
            out = c._peek_scenario_from_connect(
                ["connect", "scenario=greeter", "rdpcred=u" + "\x1f" + "p"])
        finally:
            R.bridge.start_bridge = orig_bridge
            self._release(c)
        self.assertEqual(c.scenario, "greeter")
        self.assertEqual(out[0], "connect")


class Utf8SplitAcrossRecv(unittest.TestCase):
    """I80: a multibyte character split across recv() boundaries must survive,
    in both directions, through the real handle() loop."""
    def _run(self, payload_text, split_at_byte):
        import socket, threading
        srv_c, cli = socket.socketpair()        # cli = browser side, srv_c = relay's client sock
        relay_g, fake_guacd = socket.socketpair()
        class Live:
            def register(self, *a): pass
            def unregister(self, *a): pass
        orig = R._connect_guacd
        R._connect_guacd = lambda addr: relay_g
        try:
            t = threading.Thread(target=R.handle, args=(
                srv_c, SR.SessionRegistry(), Live(), ("127.0.0.1", 4822), "sudo"))
            t.start()
            wire = R.encode("select", "vnc") + R.encode("clipboard", "1", payload_text)
            raw = wire.encode("utf-8")
            cut = raw.index(payload_text.encode("utf-8")) + split_at_byte
            cli.sendall(raw[:cut]); time.sleep(0.3); cli.sendall(raw[cut:])
            time.sleep(0.3)
            # guacd -> browser direction, same treatment
            back = R.encode("clipboard", "9", payload_text).encode("utf-8")
            bcut = back.index(payload_text.encode("utf-8")) + split_at_byte
            fake_guacd.sendall(back[:bcut]); time.sleep(0.3); fake_guacd.sendall(back[bcut:])
            time.sleep(0.3)
            fake_guacd.settimeout(2); cli.settimeout(2)
            got_up = fake_guacd.recv(65536).decode("utf-8")
            got_down = cli.recv(65536).decode("utf-8")
            cli.close()
            t.join(5)
        finally:
            R._connect_guacd = orig
            fake_guacd.close()
        return got_up, got_down

    def test_cjk_split_mid_character(self):
        txt = "日本語テキスト"
        up, down = self._run(txt, 1)             # 1 byte into a 3-byte char
        self.assertIn(R.encode("clipboard", "1", txt), up)
        self.assertEqual(down, R.encode("clipboard", "9", txt))

    def test_emoji_split_mid_character(self):
        txt = "a\U0001F600b"                      # 4-byte sequence
        for cut in (2, 3, 4):
            up, down = self._run(txt, cut)
            self.assertIn(R.encode("clipboard", "1", txt), up)
            self.assertEqual(down, R.encode("clipboard", "9", txt))

    def test_directions_do_not_share_decoder_state(self):
        c = R.Connection(client=None, uid=1, table=SR.SessionRegistry(),
                         guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
        b = "日".encode("utf-8")
        self.assertEqual(c.decode_chunk("client", b[:1]), "")
        self.assertEqual(c.decode_chunk("guacd", "x".encode()), "x")   # must not eat the client's pending byte
        self.assertEqual(c.decode_chunk("client", b[1:]), "日")


class FakeClip(object):
    """Stands in for bridge.ClipChannel: records what the relay hands the helper."""
    def __init__(self, ok=True):
        self.alive = True
        self.sent = []
        self.ok = ok
    def send_text(self, data):
        self.sent.append(data)
        if not self.ok:
            self.alive = False
        return self.ok


class BridgeClipboardChannel(unittest.TestCase):
    """I85/I86: browser<->guest clipboard through the per-session helper, not x11vnc."""
    def _conn(self, clip="fake"):
        import socket
        a, self.browser = socket.socketpair()
        g, self.guacd = socket.socketpair()
        c = R.Connection(client=a, uid=1000, table=SR.SessionRegistry(),
                         guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
        c.guacd = g
        c.clip = FakeClip() if clip == "fake" else clip
        return c

    def _drain(self, sock):
        sock.settimeout(0.2)
        try:
            return sock.recv(1 << 20).decode("utf-8")
        except Exception:
            return ""

    def _stream(self, c, text, sid="3", cut=None):
        raw = text.encode("utf-8")
        cut = len(raw) // 2 if cut is None else cut
        out = [c._guard_upstream(["clipboard", sid, "text/plain"])]
        for part in (raw[:cut], raw[cut:]):
            out.append(c._guard_upstream(["blob", sid, base64.b64encode(part).decode()]))
        out.append(c._guard_upstream(["end", sid]))
        return out

    def test_text_goes_to_helper_not_guacd_and_is_acked(self):
        c = self._conn()
        text = "Hello World! \u00c9\u00e9 \u65e5\u672c \U0001F600"
        # cut inside the 4-byte emoji: the BYTES must be rejoined before decoding
        out = self._stream(c, text, cut=len(text.encode()) - 2)
        self.assertEqual(out, [None, None, None, None])      # nothing for guacd to mangle
        self.assertEqual(c.clip.sent, [text.encode("utf-8")])
        self.assertEqual(self._drain(self.guacd), "")
        acks = self._drain(self.browser)
        self.assertEqual(acks, R.encode("ack", "3", "OK", 0) * 3)   # clipboard + 2 blobs

    def test_no_helper_forwards_to_guacd_unchanged(self):
        c = self._conn(clip=None)
        els = [["clipboard", "3", "text/plain"], ["blob", "3", "SGk="], ["end", "3"]]
        self.assertEqual([c._guard_upstream(list(e)) for e in els], els)

    def test_dead_helper_forwards_to_guacd(self):
        c = self._conn()
        c.clip.alive = False
        self.assertEqual(c._guard_upstream(["clipboard", "3", "text/plain"]),
                         ["clipboard", "3", "text/plain"])

    def test_helper_dying_at_the_last_moment_loses_nothing(self):
        c = self._conn(clip=FakeClip(ok=False))
        self._stream(c, "caf\u00e9")
        got = self._drain(self.guacd)
        self.assertIn(R.encode("clipboard", "3", "text/plain"), got)
        self.assertIn(R.encode("blob", "3", base64.b64encode("caf\u00e9".encode()).decode()), got)
        self.assertIn(R.encode("end", "3"), got)

    def test_non_text_stream_is_not_taken(self):
        c = self._conn()
        el = ["clipboard", "4", "image/png"]
        self.assertEqual(c._guard_upstream(list(el)), el)
        self.assertEqual(c._guard_upstream(["blob", "4", "AAAA"]), ["blob", "4", "AAAA"])
        self.assertEqual(c.clip.sent, [])

    def test_size_cap_matches_guacd_and_keeps_utf8_valid(self):
        c = self._conn()
        text = "\u65e5" * 200000                                # 600000 bytes
        raw = text.encode()
        c._guard_upstream(["clipboard", "5", "text/plain"])
        for i in range(0, len(raw), 4096):
            c._guard_upstream(["blob", "5", base64.b64encode(raw[i:i + 4096]).decode()])
        c._guard_upstream(["end", "5"])
        sent = c.clip.sent[0]
        self.assertLessEqual(len(sent), 262144)
        self.assertGreater(len(sent), 262144 - 4)
        sent.decode("utf-8")                                   # no split character

    def test_one_session_cannot_reach_another(self):
        # the channel is the connection's own object, created from its own bridge key
        a, b = self._conn(), self._conn()
        self._stream(a, "only-for-a")
        self.assertEqual(b.clip.sent, [])
        import bridge
        self.assertNotEqual(bridge.clip_path("console-1000-aaaa"), bridge.clip_path("console-1000-bbbb"))
        self.assertTrue(bridge.clip_path("k").startswith(bridge.BRIDGE_STATE + "/"))

    def test_synthetic_ack_is_swallowed_others_pass(self):
        c = self._conn()
        self.assertIsNone(c._guard_upstream(["ack", "20001", "OK", "0"]))
        ack = ["ack", "7", "OK", "0"]
        self.assertEqual(c._guard_upstream(list(ack)), ack)

    def test_guacd_clipboard_dropped_while_helper_attached(self):
        c = self._conn()
        self.assertTrue(c.drop_guacd_clipboard(["clipboard", "0", "text/plain"]))
        self.assertTrue(c.drop_guacd_clipboard(["blob", "0", "SGVsbG8="]))
        self.assertTrue(c.drop_guacd_clipboard(["end", "0"]))
        # an image stream with the same id later, and other instructions, are untouched
        self.assertFalse(c.drop_guacd_clipboard(["blob", "0", "AAAA"]))
        self.assertFalse(c.drop_guacd_clipboard(["img", "1", "14", "0", "image/png", "0", "0"]))
        self.assertFalse(c.drop_guacd_clipboard(["blob", "1", "AAAA"]))

    def test_guacd_clipboard_forwarded_without_helper(self):
        c = self._conn(clip=None)
        self.assertFalse(c.drop_guacd_clipboard(["clipboard", "0", "text/plain"]))
        self.assertFalse(c.drop_guacd_clipboard(["blob", "0", "SGk="]))

    def test_guest_text_reaches_browser_as_utf8_stream(self):
        c = self._conn()
        text = ("Hello \u00c9\u00e9 \u65e5\u672c " * 700).encode("utf-8")   # spans several blobs
        c.clip_to_client(text)
        wire = self._drain(self.browser)
        got = []
        R.drain(wire, got.append)
        self.assertEqual(got[0][0:3:2], ["clipboard", "text/plain"])
        sid = got[0][1]
        self.assertTrue(20000 <= int(sid) < 30000)
        self.assertEqual(got[-1], ["end", sid])
        body = b"".join(base64.b64decode(e[2]) for e in got if e[0] == "blob")
        self.assertEqual(body, text)
        self.assertNotIn("\\u00c9", body.decode("utf-8"))

    def test_channel_frames_and_bad_input(self):
        import socket, bridge
        a, b = socket.socketpair()
        ch = bridge.ClipChannel(a)
        payload = "\u00c9\u00e9 \u65e5".encode()
        frame = b"G %d\n" % len(payload) + payload
        b.sendall(frame[:3]); self.assertEqual(ch.read(), [])
        b.sendall(frame[3:] + frame); self.assertEqual(ch.read(), [payload, payload])
        b.sendall(b"X 1\nz"); ch.read()
        self.assertFalse(ch.alive)

    def test_channel_sends_capped_frame(self):
        import socket, bridge
        a, b = socket.socketpair()
        ch = bridge.ClipChannel(a)
        self.assertTrue(ch.send_text("\u00e9".encode()))
        b.settimeout(1)
        self.assertEqual(b.recv(100), b"S 2\n\xc3\xa9")

    def test_connect_clip_none_when_no_socket(self):
        import bridge
        self.assertIsNone(bridge.connect_clip("no-such-key-%d" % os.getpid()))


class BrowserParamAllowList(unittest.TestCase):
    """I82: browser-supplied guacd parameters are allow-listed per scenario."""
    NAMES = ["VERSION_1_5_0", "hostname", "port", "read-only", "username", "password",
             "color-depth", "swap-red-blue", "cursor", "encodings", "clipboard-encoding",
             "disable-copy", "disable-paste", "dest-host", "dest-port", "enable-audio",
             "audio-servername", "recording-path", "recording-name", "reverse-connect",
             "enable-sftp", "sftp-hostname", "autoretry"]

    def _conn(self, scenario):
        c = R.Connection(client=None, uid=1000, table=SR.SessionRegistry(),
                         guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
        c.arg_names = list(self.NAMES)
        c.scenario = scenario
        return c

    def _evil(self, **over):
        vals = {n: "" for n in self.NAMES}
        vals.update({"VERSION_1_5_0": "VERSION_1_5_0", "hostname": "evil.example", "port": "1",
                     "read-only": "true", "disable-copy": "true", "disable-paste": "true",
                     "dest-host": "10.9.9.9", "dest-port": "22", "audio-servername": "10.9.9.9",
                     "recording-path": "/tmp", "recording-name": "x", "reverse-connect": "true",
                     "enable-sftp": "true", "sftp-hostname": "h", "autoretry": "99",
                     "password": "attacker"})
        vals.update(over)
        return ["connect"] + [vals[n] for n in self.NAMES]

    INFO = {"VNCHOST": "127.0.0.1", "VNCPORT": "5999", "VNCPASS": "srv"}

    def _out(self, scenario, **over):
        c = self._conn(scenario)
        return c, dict(zip(self.NAMES, c._inject_vnc_target(self._evil(**over), self.INFO)[1:]))

    def test_dangerous_keys_forced_to_default_all_scenarios(self):
        for sc in ("isolated", "virtual", "console", "greeter", "remote", "wayland-vnc", "vnc"):
            _c, p = self._out(sc)
            for k in ("read-only", "disable-copy", "disable-paste", "dest-host", "dest-port",
                      "audio-servername", "recording-path", "recording-name",
                      "reverse-connect", "enable-sftp", "sftp-hostname", "autoretry"):
                self.assertEqual(p[k], "", (sc, k))
            self.assertEqual((p["hostname"], p["port"], p["password"]), ("127.0.0.1", "5999", "srv"))
            self.assertEqual(p["VERSION_1_5_0"], "VERSION_1_5_0")

    def test_legit_page_values_pass(self):
        for sc in ("isolated", "wayland-vnc", "vnc"):
            _c, p = self._out(sc, **{"enable-audio": "true", "clipboard-encoding": "UTF-8"})
            self.assertEqual(p["enable-audio"], "true")
            self.assertEqual(p["clipboard-encoding"], "UTF-8")

    def test_bad_value_for_allowed_key_dropped(self):
        _c, p = self._out("wayland-vnc", **{"clipboard-encoding": "../../x", "enable-audio": "yes"})
        self.assertEqual((p["clipboard-encoding"], p["enable-audio"]), ("", ""))

    def test_vnc_only_tuning_keys(self):
        _c, p = self._out("vnc", **{"color-depth": "16", "swap-red-blue": "true",
                                   "cursor": "remote", "username": "bob"})
        self.assertEqual((p["color-depth"], p["swap-red-blue"], p["cursor"], p["username"]),
                         ("16", "true", "remote", "bob"))
        _c, p = self._out("isolated", **{"color-depth": "16", "username": "bob"})
        self.assertEqual((p["color-depth"], p["username"]), ("", ""))

    def test_rejections_logged_once_names_only(self):
        c = self._conn("isolated")
        with self.assertLogs(R.log, level="WARNING") as cm:
            c._inject_vnc_target(self._evil(), self.INFO)
            c._inject_vnc_target(self._evil(), self.INFO)
        lines = [l for l in cm.output if "ignored" in l]
        self.assertEqual(len(lines), 1)
        self.assertIn("disable-copy", lines[0])
        for secret in ("evil.example", "attacker", "10.9.9.9", "/tmp"):
            self.assertNotIn(secret, lines[0])

    def test_clean_connect_logs_nothing(self):
        c = self._conn("isolated")
        vals = ["connect"] + [("VERSION_1_5_0" if n.startswith("VERSION_") else "") for n in self.NAMES]
        with self.assertRaises(AssertionError):      # assertLogs fails when nothing is logged
            with self.assertLogs(R.log, level="WARNING"):
                c._inject_vnc_target(vals, self.INFO)

    def test_end_to_end_vnc_scenario_keeps_user_target_and_credential(self):
        R.REMOTE_ALLOW = R.parse_remote_allow("10.20.0.7:5901")
        R.REMOTE_ADMIN_ONLY = False
        try:
            c = self._conn(None)
            vals = self._evil()[:]
            out = c._peek_scenario_from_connect(
                vals + ["rdpcred=ignored\x1fvncsecret", "remotehost=10.20.0.7:5901", "scenario=vnc"])
            p = dict(zip(self.NAMES, out[1:]))
            self.assertEqual((p["hostname"], p["port"], p["password"]),
                             ("10.20.0.7", "5901", "vncsecret"))
            self.assertEqual(p["disable-copy"], "")
            self.assertEqual(p["dest-host"], "")
        finally:
            R.REMOTE_ALLOW = []

    def test_end_to_end_wayland_vnc_server_target_wins(self):
        orig = R.ensure_waylandvnc_session
        R.ensure_waylandvnc_session = lambda uid: {"HOST": "127.0.0.1", "PORT": "5901"}
        try:
            c = self._conn(None)
            out = c._peek_scenario_from_connect(
                self._evil(**{"clipboard-encoding": "UTF-8"}) + ["scenario=wayland-vnc"])
            p = dict(zip(self.NAMES, out[1:]))
            self.assertEqual((p["hostname"], p["port"], p["password"]), ("127.0.0.1", "5901", ""))
            self.assertEqual(p["clipboard-encoding"], "UTF-8")
            self.assertEqual(p["read-only"], "")
        finally:
            R.ensure_waylandvnc_session = orig


if __name__ == "__main__":
    unittest.main(verbosity=1)
