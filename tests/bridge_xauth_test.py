# SPDX-License-Identifier: BSD-3-Clause
# I81: the bridge's Xvfb must (a) not listen on the abstract socket, (b) demand a
# per-session MIT-MAGIC-COOKIE, and (c) hand that cookie (XAUTHORITY) to its X clients.
# Runs the REAL bridge script rootless with a stub xfreerdp3 (no RDP server needed);
# skipped when Xvfb/x11vnc/xauth are absent.
import os, shutil, socket, stat, struct, subprocess, tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("EDY_BRIDGE_SCRIPT") or os.path.join(HERE, "..", "bridge", "edy-rdp-bridge-start.sh")
NEED = ("Xvfb", "x11vnc", "xauth", "ss", "bash")


def x_setup_ok(path, auth_name=b"", auth_data=b""):
    """Raw X11 connection setup over the filesystem socket; True if the server accepts."""
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(path)
    pad = lambda b: b + b"\0" * (-len(b) % 4)
    s.sendall(struct.pack("<BxHHHHxx", 0x6C, 11, 0, len(auth_name), len(auth_data))
              + pad(auth_name) + pad(auth_data))
    status = s.recv(1)
    s.close()
    return status == b"\x01"


@unittest.skipUnless(all(shutil.which(t) for t in NEED), "needs Xvfb x11vnc xauth ss")
class BridgeXAuthority(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="edy-brx-")
        self.state = os.path.join(self.tmp, "st")
        os.makedirs(self.state)
        self.key = "t%d" % os.getpid()
        stub = os.path.join(self.tmp, "bin")
        os.makedirs(stub)
        with open(os.path.join(stub, "xfreerdp3"), "w") as f:
            f.write('#!/bin/bash\necho "$XAUTHORITY" > %s/stub.xauth\nexec sleep 300\n' % self.tmp)
        os.chmod(os.path.join(stub, "xfreerdp3"), 0o755)
        with open(os.path.join(self.state, self.key + ".req"), "w") as f:
            f.write("HOST=127.0.0.1\nPORT=3389\nSECURITY=nla\nUSERNAME=u\nPASSWORD=p\nGEOM=640x480\n")
        env = dict(os.environ, EDY_BRIDGE_STATE=self.state,
                   PATH=stub + ":" + os.environ["PATH"])
        env.pop("XAUTHORITY", None)
        self.proc = subprocess.Popen(["bash", SCRIPT, self.key], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        envf = os.path.join(self.state, self.key + ".env")
        for _ in range(60):
            if os.path.exists(envf) or self.proc.poll() is not None:
                break
            time.sleep(0.25)
        self.assertTrue(os.path.exists(envf), "bridge did not come up: %r" % (
            self.proc.poll() is not None and self.proc.stdout.read()))
        # the display number is named by the authority file's single entry
        self.xauth = os.path.join(self.state, ".%s.xauth" % self.key)
        lst = subprocess.run(["xauth", "-f", self.xauth, "list"], capture_output=True, text=True).stdout.split()
        self.disp = lst[0].rsplit(":", 1)[1]
        self.cookie = bytes.fromhex(lst[2])
        self.sock = "/tmp/.X11-unix/X" + self.disp

    def tearDown(self):
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.proc.stdout.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_no_abstract_socket(self):
        out = subprocess.run(["ss", "-xlnH"], capture_output=True, text=True).stdout
        self.assertNotIn("@/tmp/.X11-unix/X" + self.disp + " ", out)

    def test_unauthenticated_client_refused_cookie_accepted(self):
        self.assertFalse(x_setup_ok(self.sock), "no-cookie client was admitted")
        self.assertFalse(x_setup_ok(self.sock, b"MIT-MAGIC-COOKIE-1", b"\0" * 16), "wrong cookie admitted")
        self.assertTrue(x_setup_ok(self.sock, b"MIT-MAGIC-COOKIE-1", self.cookie))

    def test_authority_file_private_and_passed_to_clients(self):
        mode = stat.S_IMODE(os.stat(self.xauth).st_mode)
        self.assertEqual(mode, 0o600)
        for _ in range(40):
            if os.path.exists(os.path.join(self.tmp, "stub.xauth")):
                break
            time.sleep(0.25)
        with open(os.path.join(self.tmp, "stub.xauth")) as f:
            self.assertEqual(f.read().strip(), self.xauth)    # xfreerdp3 got XAUTHORITY
        # x11vnc attached (it would have exited with "cannot open display" otherwise)
        for _ in range(40):
            try:
                s = socket.create_connection(("127.0.0.1", int(open(os.path.join(self.state, self.key + ".env")).read().split("VNCPORT=")[1].split()[0])), 2)
                self.assertTrue(s.recv(12).startswith(b"RFB"))
                s.close()
                break
            except OSError:
                time.sleep(0.25)
        else:
            self.fail("x11vnc did not serve the authenticated display")

    def test_authority_removed_on_exit(self):
        self.proc.terminate()
        self.proc.wait(10)
        time.sleep(0.5)
        self.assertFalse(os.path.exists(self.xauth))


if __name__ == "__main__":
    unittest.main()
