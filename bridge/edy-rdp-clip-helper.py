# SPDX-License-Identifier: BSD-3-Clause
#
# edy-rdp-clip-helper <SOCKET>  (I85 / I86)
#
# The FreeRDP3 bridge carries the clipboard as xfreerdp3 <-> X selection <-> x11vnc <->
# guacd. Both directions are broken at x11vnc:
#
#   * browser -> guest: x11vnc receives the VNC cut text and logs "Set CLIPBOARD" but never
#     calls XSetSelectionOwner (I83), so xfreerdp3 never sees a selection to forward.
#   * guest -> browser: x11vnc polls the selection with a hard-coded XConvertSelection(...,
#     XA_STRING, ...) (x11vnc 0.9.17 xevents.c). xfreerdp3 answers the STRING target through
#     winpr's text/plain converter, which writes every non-ASCII character as a literal
#     "\uXXXX" (winpr/libwinpr/crt/unicode.c, winpr_utf8ToUtfEscapedString). Its UTF8_STRING
#     target is correct UTF-8, but x11vnc never asks for it.
#
# This helper sits beside x11vnc on the SAME per-session Xvfb (it inherits DISPLAY and the
# per-session XAUTHORITY of I81) and carries clipboard text itself, both directions, as
# UTF-8:
#   * relay -> helper "S <n>\n<n bytes>": own the CLIPBOARD selection and serve it (UTF8_STRING,
#     STRING as Latin-1, text/plain[;charset=utf-8], TEXT, TARGETS, TIMESTAMP). xfreerdp3 sees
#     the owner change through XFixes and forwards the text to the RDP guest.
#   * helper -> relay "G <n>\n<n bytes>": the CLIPBOARD owner changed to someone else
#     (xfreerdp3, after the guest copied); its UTF8_STRING is fetched and handed over.
# One relay client at a time, same uid only (SO_PEERCRED), socket mode 0600. Contents are
# never logged, only byte counts. Texts are capped at CLIP_MAX (guacd's own clipboard cap).
import os
import select
import signal
import socket
import struct
import sys
import time

CLIP_MAX = 262144           # 256 KiB: guacd's clipboard buffer (GUAC_COMMON_CLIPBOARD_MAX_LENGTH)
READ_TIMEOUT = 3.0          # a guest owner that does not answer a conversion in this long is skipped
LATIN1_TARGETS = ("STRING", "TEXT", "text/plain")
UTF8_TARGETS = ("UTF8_STRING", "text/plain;charset=utf-8")


def log(msg):
    sys.stderr.write("edy-rdp-clip-helper: %s\n" % msg)
    sys.stderr.flush()


def cap_utf8(data, limit=CLIP_MAX):
    """Truncate UTF-8 `data` to at most `limit` bytes without splitting a character, and
    return it with replacement characters for anything invalid, re-encoded."""
    text = data.decode("utf-8", "replace")
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return raw
    return raw[:limit].decode("utf-8", "ignore").encode("utf-8")


class Helper(object):
    def __init__(self, sock_path):
        from Xlib import X, display
        from Xlib.ext import xfixes
        self.X = X
        self.xfixes = xfixes
        self.d = display.Display()
        self.screen = self.d.screen()
        self.win = self.screen.root.create_window(
            0, 0, 1, 1, 0, self.screen.root_depth, X.InputOutput, X.CopyFromParent,
            event_mask=X.PropertyChangeMask)
        a = self.d.intern_atom
        self.A = {n: a(n) for n in ("CLIPBOARD", "TARGETS", "TIMESTAMP", "UTF8_STRING", "STRING",
                                    "TEXT", "text/plain", "text/plain;charset=utf-8", "INCR",
                                    "ATOM", "INTEGER", "_EDY_CLIP_IN")}
        if not self.d.has_extension("XFIXES"):
            raise RuntimeError("X server has no XFIXES")
        self.d.xfixes_query_version()
        self.d.xfixes_select_selection_input(self.win, self.A["CLIPBOARD"],
                                             xfixes.XFixesSetSelectionOwnerNotifyMask)
        self.owned = None            # bytes we serve while we own CLIPBOARD
        self.own_time = X.CurrentTime
        self.pending = None          # deadline of an outstanding guest-side conversion
        self.last_sent = None        # last guest text handed to the relay (suppresses repeats)
        self.sock_path = sock_path
        try:
            os.unlink(sock_path)
        except OSError:
            pass
        old = os.umask(0o177)
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.srv.bind(sock_path)
        finally:
            os.umask(old)
        os.chmod(sock_path, 0o600)
        self.srv.listen(1)
        self.cli = None
        self.rbuf = b""

    # -- relay socket --------------------------------------------------------
    def _drop_client(self):
        if self.cli:
            try:
                self.cli.close()
            except OSError:
                pass
        self.cli = None
        self.rbuf = b""

    def _accept(self):
        conn, _ = self.srv.accept()
        try:
            pid, uid, gid = struct.unpack("3i", conn.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        except OSError:
            uid = -1
        if uid != os.getuid():
            log("refused a peer with uid %s" % uid)
            conn.close()
            return
        self._drop_client()
        self.cli = conn
        self.last_sent = None        # a fresh relay connection gets the current guest text again

    def _feed(self):
        try:
            data = self.cli.recv(65536)
        except OSError:
            data = b""
        if not data:
            self._drop_client()
            return
        self.rbuf += data
        while True:
            nl = self.rbuf.find(b"\n")
            if nl < 0:
                if len(self.rbuf) > 32:
                    self._drop_client()
                return
            head = self.rbuf[:nl].split()
            try:
                if len(head) != 2 or head[0] != b"S":
                    raise ValueError("bad frame")
                n = int(head[1])
                if not 0 <= n <= CLIP_MAX * 4:
                    raise ValueError("bad length")
            except ValueError:
                self._drop_client()
                return
            if len(self.rbuf) < nl + 1 + n:
                return
            payload = self.rbuf[nl + 1:nl + 1 + n]
            self.rbuf = self.rbuf[nl + 1 + n:]
            self.set_owner(cap_utf8(payload))

    def _send(self, text):
        if not self.cli:
            return
        try:
            self.cli.sendall(b"G %d\n" % len(text) + text)
        except OSError:
            self._drop_client()

    # -- X: serving (browser -> guest) --------------------------------------
    def set_owner(self, data):
        X = self.X
        self.owned = data
        self.win.set_selection_owner(self.A["CLIPBOARD"], X.CurrentTime)
        self.d.flush()
        ok = self.d.get_selection_owner(self.A["CLIPBOARD"]) == self.win
        self.last_sent = data        # our own text must not bounce back as a guest copy
        log("set CLIPBOARD %d bytes owner=%s" % (len(data), "ours" if ok else "LOST"))

    def _on_request(self, e):
        from Xlib.protocol import event
        X, A = self.X, self.A
        prop = e.property if e.property != X.NONE else e.target
        ok = False
        if self.owned is not None and e.selection == A["CLIPBOARD"]:
            tname = self.d.get_atom_name(e.target)
            if e.target == A["TARGETS"]:
                atoms = [A["TARGETS"], A["TIMESTAMP"]] + [A[n] for n in UTF8_TARGETS + LATIN1_TARGETS]
                e.requestor.change_property(prop, A["ATOM"], 32, atoms)
                ok = True
            elif e.target == A["TIMESTAMP"]:
                e.requestor.change_property(prop, A["INTEGER"], 32, [self.own_time])
                ok = True
            elif tname in UTF8_TARGETS:
                e.requestor.change_property(prop, A["UTF8_STRING"], 8, self.owned)
                ok = True
            elif tname in LATIN1_TARGETS:
                txt = self.owned.decode("utf-8", "replace").encode("latin-1", "replace")
                e.requestor.change_property(prop, A["STRING"], 8, txt)
                ok = True
        ev = event.SelectionNotify(
            time=e.time, requestor=e.requestor, selection=e.selection, target=e.target,
            property=prop if ok else X.NONE)
        e.requestor.send_event(ev)
        self.d.flush()

    # -- X: reading the guest's text (guest -> browser) ----------------------
    def _on_owner_change(self, e):
        A = self.A
        if e.selection != A["CLIPBOARD"]:
            return
        owner = getattr(e.owner, "id", e.owner)
        if owner == self.win.id or owner == self.X.NONE:
            return
        # someone else (xfreerdp3 after the guest copied) took CLIPBOARD
        self.owned = None
        self.win.convert_selection(A["CLIPBOARD"], A["UTF8_STRING"], A["_EDY_CLIP_IN"], e.timestamp)
        self.pending = time.monotonic() + READ_TIMEOUT
        self.d.flush()

    def _on_notify(self, e):
        A, X = self.A, self.X
        if e.selection != A["CLIPBOARD"] or e.target != A["UTF8_STRING"]:
            return
        self.pending = None
        if e.property == X.NONE:
            log("guest CLIPBOARD owner refused UTF8_STRING")
            return
        r = self.win.get_full_property(A["_EDY_CLIP_IN"], X.AnyPropertyType, sizehint=CLIP_MAX // 4 + 1)
        try:
            self.win.delete_property(A["_EDY_CLIP_IN"])
        except Exception:
            pass
        if r is None or r.property_type == A["INCR"]:
            log("guest CLIPBOARD too large or incremental; skipped")
            return
        raw = r.value if isinstance(r.value, bytes) else bytes(r.value)
        if raw.endswith(b"\0"):
            raw = raw.rstrip(b"\0")
        text = cap_utf8(raw)
        if not text or text == self.last_sent:
            return
        self.last_sent = text
        log("guest CLIPBOARD %d bytes -> relay%s" % (len(text), "" if self.cli else " (no relay attached)"))
        self._send(text)

    def run(self):
        X = self.X
        while True:
            rl = [self.d.fileno(), self.srv] + ([self.cli] if self.cli else [])
            r, _, _ = select.select(rl, [], [], 0.5)
            if self.srv in r:
                self._accept()
            if self.cli and self.cli in r:
                self._feed()
            while self.d.pending_events():
                e = self.d.next_event()
                if e.type == X.SelectionRequest:
                    self._on_request(e)
                elif e.type == X.SelectionClear:
                    if e.atom == self.A["CLIPBOARD"]:      # SelectionClear names it `atom`
                        self.owned = None
                elif e.type == X.SelectionNotify:
                    self._on_notify(e)
                elif type(e).__name__ == "SetSelectionOwnerNotify":   # python-xlib builds this class per display
                    self._on_owner_change(e)
            if self.pending is not None and time.monotonic() > self.pending:
                self.pending = None
                log("guest CLIPBOARD conversion timed out")


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: edy-rdp-clip-helper <SOCKET>\n")
        return 2
    try:
        h = Helper(argv[1])
    except Exception as exc:        # no Xlib, no XFIXES, no display: the bridge carries on without us
        log("cannot start: %s" % exc)
        return 1
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        h.run()
    except (SystemExit, KeyboardInterrupt):
        pass
    except Exception as exc:        # X connection gone (Xvfb exited) or similar
        import traceback
        tb = [f for f in traceback.extract_tb(sys.exc_info()[2]) if f.filename == __file__][-1]
        log("stopping: %s: %s (%s:%d)" % (type(exc).__name__, exc, tb.name, tb.lineno))
    finally:
        try:
            os.unlink(argv[1])
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
