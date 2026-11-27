# SPDX-License-Identifier: BSD-3-Clause
# I85/I86: the bridge's clipboard helper, end to end on a REAL Xvfb: relay code -> unix socket ->
# helper -> the session's X CLIPBOARD (browser -> guest), and a CLIPBOARD owner like xfreerdp3 ->
# helper -> relay code (guest -> browser). Runs the real bridge script rootless with a stub
# xfreerdp3 (no RDP server needed); skipped when Xvfb/x11vnc/xauth/python-xlib are absent.
import base64, os, shutil, stat, subprocess, sys, tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "relay"))
SCRIPT = os.environ.get("EDY_BRIDGE_SCRIPT") or os.path.join(HERE, "..", "bridge", "edy-rdp-bridge-start.sh")
NEED = ("Xvfb", "x11vnc", "xauth", "ss", "bash")
try:
    import Xlib  # noqa: F401
    HAVE_XLIB = True
except ImportError:
    HAVE_XLIB = False


def _xconn(display, xauth):
    os.environ["XAUTHORITY"] = xauth
    from Xlib import display as xdisplay
    return xdisplay.Display(display)


@unittest.skipUnless(all(shutil.which(t) for t in NEED) and HAVE_XLIB,
                     "needs Xvfb x11vnc xauth ss and python-xlib")
class BridgeClipboardHelper(unittest.TestCase):
    def setUp(self):
        import bridge
        self.bridge = bridge
        self.tmp = tempfile.mkdtemp(prefix="edy-brc-")
        self.state = os.path.join(self.tmp, "st")
        os.makedirs(self.state)
        self.key = "c%d" % os.getpid()
        stub = os.path.join(self.tmp, "bin")
        os.makedirs(stub)
        with open(os.path.join(stub, "xfreerdp3"), "w") as f:
            f.write("#!/bin/bash\nexec sleep 300\n")
        os.chmod(os.path.join(stub, "xfreerdp3"), 0o755)
        with open(os.path.join(self.state, self.key + ".req"), "w") as f:
            f.write("HOST=127.0.0.1\nPORT=3389\nSECURITY=nla\nUSERNAME=u\nPASSWORD=p\nGEOM=640x480\n")
        env = dict(os.environ, EDY_BRIDGE_STATE=self.state, PATH=stub + ":" + os.environ["PATH"])
        env.pop("XAUTHORITY", None)
        self.proc = subprocess.Popen(["bash", SCRIPT, self.key], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.envf = os.path.join(self.state, self.key + ".env")
        for _ in range(80):
            if os.path.exists(self.envf) or self.proc.poll() is not None:
                break
            time.sleep(0.25)
        self.assertTrue(os.path.exists(self.envf), "bridge did not come up: %r" % (
            self.proc.poll() is not None and self.proc.stdout.read()))
        self.xauth = os.path.join(self.state, ".%s.xauth" % self.key)
        self.disp = ":" + subprocess.run(["xauth", "-f", self.xauth, "list"], capture_output=True,
                                         text=True).stdout.split()[0].rsplit(":", 1)[1]
        bridge.BRIDGE_STATE = self.state
        self.clip = None

    def tearDown(self):
        if self.clip is not None:
            self.clip.close()
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.proc.stdout.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _read_selection(self, d, target="UTF8_STRING"):
        """Ask the CLIPBOARD owner for `target`, as xfreerdp3 / xclip -o would."""
        from Xlib import X
        win = d.screen().root.create_window(0, 0, 1, 1, 0, d.screen().root_depth)
        cb, tgt, prop = d.intern_atom("CLIPBOARD"), d.intern_atom(target), d.intern_atom("_T")
        win.convert_selection(cb, tgt, prop, X.CurrentTime)
        d.flush()
        end = time.time() + 5
        while time.time() < end:
            if d.pending_events():
                e = d.next_event()
                if e.type == X.SelectionNotify:
                    if e.property == X.NONE:
                        return None
                    r = win.get_full_property(prop, X.AnyPropertyType)
                    return bytes(r.value) if r is not None else None
            else:
                time.sleep(0.05)
        self.fail("no SelectionNotify")

    def test_env_publishes_the_helper_socket_privately(self):
        env = self.bridge._read_env(self.envf)
        self.assertEqual(env.get("CLIPSOCK"), self.bridge.clip_path(self.key))
        self.assertEqual(stat.S_IMODE(os.stat(env["CLIPSOCK"]).st_mode), 0o600)
        self.assertEqual(os.stat(env["CLIPSOCK"]).st_uid, os.getuid())

    def test_browser_text_becomes_the_session_clipboard(self):
        import edy_rdp_relay as R, session_registry as SR, socket
        a, _b = socket.socketpair()
        c = R.Connection(client=a, uid=os.getuid(), table=SR.SessionRegistry(),
                         guacd_addr=("127.0.0.1", 4822), admin_group="sudo")
        c.clip = self.clip = self.bridge.connect_clip(self.key)
        self.assertIsNotNone(c.clip)
        text = "Hello World! Éé 日本 \U0001F600"
        raw = text.encode()
        for el in (["clipboard", "3", "text/plain"],
                   ["blob", "3", base64.b64encode(raw[:17]).decode()],
                   ["blob", "3", base64.b64encode(raw[17:]).decode()], ["end", "3"]):
            self.assertIsNone(c._guard_upstream(el))
        time.sleep(0.5)
        d = _xconn(self.disp, self.xauth)
        self.assertEqual(self._read_selection(d, "UTF8_STRING"), raw)          # exact UTF-8
        self.assertEqual(self._read_selection(d, "STRING"),
                         text.encode("latin-1", "replace"))                      # Latin-1 targets work too
        self.assertIsNone(self._read_selection(d, "image/png"))

    def test_guest_text_arrives_as_utf8_not_escaped(self):
        from Xlib import X
        from Xlib.protocol import event
        self.clip = self.bridge.connect_clip(self.key)
        self.assertIsNotNone(self.clip)
        d = _xconn(self.disp, self.xauth)
        win = d.screen().root.create_window(0, 0, 1, 1, 0, d.screen().root_depth)
        cb, u8, st, tg, at = (d.intern_atom(n) for n in ("CLIPBOARD", "UTF8_STRING", "STRING", "TARGETS", "ATOM"))
        guest = "Hello World! Éé"
        win.set_selection_owner(cb, X.CurrentTime)
        d.flush()
        got, end = [], time.time() + 8
        self.clip.sock.settimeout(0.2)
        while time.time() < end and not got:
            while d.pending_events():
                e = d.next_event()
                if e.type != X.SelectionRequest:
                    continue
                ok = True
                if e.target == tg:
                    e.requestor.change_property(e.property, at, 32, [tg, u8, st])
                elif e.target == u8:
                    e.requestor.change_property(e.property, u8, 8, guest.encode())
                elif e.target == st:         # xfreerdp3 (winpr) answers STRING with \\uXXXX escapes
                    e.requestor.change_property(e.property, st, 8, guest.encode("ascii", "backslashreplace"))
                else:
                    ok = False
                e.requestor.send_event(event.SelectionNotify(
                    time=e.time, requestor=e.requestor, selection=e.selection, target=e.target,
                    property=e.property if ok else X.NONE))
                d.flush()
            got = self.clip.read()
        self.assertEqual(got, [guest.encode("utf-8")])

    def test_teardown_removes_the_helper_and_its_socket(self):
        sock = self.bridge.clip_path(self.key)
        self.assertTrue(os.path.exists(sock))
        out = subprocess.run(["pgrep", "-f", "edy-rdp-clip-helper.py " + sock], capture_output=True, text=True)
        self.assertTrue(out.stdout.split(), "helper not running")
        self.proc.terminate()
        self.proc.wait(10)
        time.sleep(1.0)
        self.assertFalse(os.path.exists(sock))
        out = subprocess.run(["pgrep", "-f", "edy-rdp-clip-helper.py " + sock], capture_output=True, text=True)
        self.assertEqual(out.stdout.split(), [])

    def test_x11vnc_gets_its_selection_window_at_once(self):
        # I83: without X11VNC_AVOID_WINDOWS=never x11vnc has no selection window for 45 s
        pid = subprocess.run(["pgrep", "-f", "x11vnc -display %s" % self.disp], capture_output=True,
                             text=True).stdout.split()[0]
        with open("/proc/%s/environ" % pid, "rb") as f:
            self.assertIn(b"X11VNC_AVOID_WINDOWS=never", f.read().split(b"\0"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
