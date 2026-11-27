# SPDX-License-Identifier: BSD-3-Clause
#
# bridge — the relay's orchestration of the per-connection FreeRDP3 bridge.
#
# For every bridged connection the relay starts edy-rdp-bridge-start.sh, which
# renders a grd RDP/RDSTLS target with the vanilla xfreerdp3 client into a headless
# Xvfb and re-serves it over LOOPBACK VNC (x11vnc). guacd's VNC plugin (not its
# FreeRDP2 RDP plugin) then bridges that to the browser. The bridge process is a
# child of the relay: it lives with the connection and its EXIT trap disposes the
# whole Xvfb/xfreerdp3/x11vnc stack, so a disconnect tears down the CONNECTION while
# the backing desktop (headless GNOME / the physical seat) lives on.
#
# The RDP credential reaches xfreerdp3 only via the 0600 .req file (never argv, so it
# is not exposed in the process list); the loopback VNC endpoint the relay hands guacd
# is written back to the 0640 .env file. stdlib only.

import base64
import logging
import os
import re
import socket
import struct
import subprocess
import time

trace_log = logging.getLogger("edy-rdp-trace")

BRIDGE_STATE = "/run/edy-rdp/bridge"
BRIDGE_BIN = "/usr/libexec/edy-rdp/edy-rdp-bridge-start"
BRIDGE_READY_TIMEOUT = 30.0


class BridgeError(Exception):
    """auth_failed is set when the xfreerdp3 log carried a definitive credential
    verdict. It is an attribute rather than message text because the message is
    truncated twice (see _rdplog_tail) and the verdict does not survive that."""

    def __init__(self, message, auth_failed=False):
        super(BridgeError, self).__init__(message)
        self.auth_failed = auth_failed


# The ONLY dependable credential discriminator FreeRDP gives us. Verified on this
# host: a wrong username, a wrong password for rdplocal, and a wrong password for
# rdplogin all emit exactly this line; two different non-auth failures (a fake
# server sending a malformed TSRequest, and one sending truncated DER) emit none.
#
# Anchored on the [nla_recv_pdu] tag because that is the emitter
# (libfreerdp/core/nla.c -> freerdp_set_last_error_ex), so a stray mention of the
# code elsewhere in the log cannot be mistaken for the verdict.
#
# Do NOT be tempted by two signatures that look diagnostic and are not:
#   * CONNECTION_STATE_NLA / nla_recv_pdu() fail  -- reproduced with NO credential
#     involvement at all; it means "NLA stage ended badly", not "bad password".
#   * the krb5 / kerberos_AcquireCredentialsHandleA lines -- ordinary SSPI
#     credential-acquisition noise emitted before NTLM fallback; they appear
#     identically in non-auth failures.
_AUTH_CODES = (
    "AUTHENTICATION_FAILED", "INSUFFICIENT_PRIVILEGES", "PASSWORD_EXPIRED",
    "PASSWORD_CERTAINLY_EXPIRED", "CLIENT_REVOKED", "KDC_UNREACHABLE",
    "ACCOUNT_DISABLED", "PASSWORD_MUST_CHANGE", "LOGON_FAILURE", "WRONG_PASSWORD",
    "ACCESS_DENIED", "ACCOUNT_RESTRICTION", "ACCOUNT_LOCKED_OUT", "ACCOUNT_EXPIRED",
    "LOGON_TYPE_NOT_GRANTED", "NO_OR_MISSING_CREDENTIALS",
)
AUTH_ERR_RE = re.compile(
    r"\[nla_recv_pdu\]:\s*ERRCONNECT_(?:%s)\b" % "|".join(_AUTH_CODES))


def _rdplog_auth_failed(key):
    """Scan the WHOLE xfreerdp3 log for the credential verdict.

    This must run before the log is unlinked, and it deliberately does not reuse
    _rdplog_tail: the verdict line is typically 7th of 10 ERROR lines, so the
    tail's last-3 window drops it. Raising that window is not a fix either --
    the 280-char cap then truncates the joined string before reaching it.
    """
    try:
        with open(_rdplog_path(key), "r", errors="replace") as fh:
            for line in fh:
                if AUTH_ERR_RE.search(line):
                    return True
    except OSError:
        pass
    return False


def _req_path(key):
    return os.path.join(BRIDGE_STATE, "%s.req" % key)


def _env_path(key):
    return os.path.join(BRIDGE_STATE, "%s.env" % key)


def start_bridge(key, host, port, security, username, password, geom="1600x1000"):
    """Write the request, launch the bridge as a child process, and block until it
    publishes its loopback VNC endpoint. Returns (endpoint_dict, Popen). Raises
    BridgeError on failure. endpoint_dict has VNCHOST/VNCPORT/VNCPASS."""
    trace_log.info("bridge START key=%s target=%s:%s security=%s user=%s geom=%s "
                   "password=<redacted:%d>", key, host, port, security, username,
                   geom, len(password or ""))
    # Defense-in-depth: the .req is a newline-delimited KEY=VALUE file, so a newline/CR
    # in ANY field could forge another key (e.g. HOST=/PORT=) and redirect the dial.
    # The relay validates client credentials, but re-check every value here so no caller
    # can inject regardless of path. (NUL would also truncate the shell read.)
    for _name, _val in (("host", host), ("port", port), ("security", security),
                        ("username", username), ("password", password), ("geom", geom)):
        if any(c in str(_val) for c in ("\n", "\r", "\x00")):
            raise BridgeError("illegal control character in bridge %s" % _name)
    try:
        os.makedirs(BRIDGE_STATE, exist_ok=True)
    except OSError as exc:
        raise BridgeError("bridge state dir: %s" % exc)

    # request file: 0600, credential never on a command line
    req = _req_path(key)
    env = _env_path(key)
    try:
        if os.path.exists(env):
            os.unlink(env)
        fd = os.open(req, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write("HOST=%s\nPORT=%s\nSECURITY=%s\nUSERNAME=%s\nPASSWORD=%s\nGEOM=%s\n"
                     % (host, port, security, username, password, geom))
    except OSError as exc:
        raise BridgeError("write bridge request: %s" % exc)

    # HOME so xfreerdp3/x11vnc have a writable config dir when run as the relay uid
    child_env = dict(os.environ)
    child_env.setdefault("HOME", BRIDGE_STATE)
    child_env.pop("WAYLAND_DISPLAY", None)
    child_env["XDG_SESSION_TYPE"] = "x11"
    try:
        proc = subprocess.Popen([BRIDGE_BIN, key], env=child_env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
    except OSError as exc:
        _safe_unlink(req)
        raise BridgeError("launch bridge: %s" % exc)

    deadline = time.time() + BRIDGE_READY_TIMEOUT
    info = None
    while time.time() < deadline:
        if proc.poll() is not None:
            _safe_unlink(req)
            detail = _rdplog_tail(key)
            # Both reads must happen before the unlink below; the relay cannot
            # re-open this file later (bridge.py is the only thing that opens it).
            auth = _rdplog_auth_failed(key)
            _safe_unlink(_rdplog_path(key))
            raise BridgeError("desktop connection failed%s" %
                              ((": " + detail) if detail else " (rc=%s)" % proc.returncode),
                              auth_failed=auth)
        info = _read_env(env)
        if info and info.get("VNCPORT"):
            break
        time.sleep(0.2)
    _safe_unlink(req)  # credential no longer needed on disk once the bridge read it
    if not info or not info.get("VNCPORT"):
        stop_bridge(proc, key)
        raise BridgeError("bridge did not become ready in %.0fs" % BRIDGE_READY_TIMEOUT)
    return info, proc


# ---------------------------------------------------------------------------
# Clipboard channel to the per-session helper (I85/I86; bridge/edy-rdp-clip-helper.py).
# x11vnc cannot carry the browser's text to the guest (I83) and hands the guest's text
# to guacd as xfreerdp3's winpr-ESCAPED "STRING" ("\\u00c9" for E-acute). The helper owns/reads
# the session's X CLIPBOARD itself, as UTF-8; the relay talks to it over a 0600 unix
# socket that lives in this session's own state dir and is named by the bridge key, so
# one session's text can never reach another session's display.
# ---------------------------------------------------------------------------
CLIP_MAX = 262144                   # guacd's clipboard buffer; larger text is truncated, not refused
CLIP_STREAM_BASE = 20000            # relay-minted guest->browser stream ids (guacd's are small)
CLIP_STREAM_SPAN = 10000
CLIP_UP_STREAMS = 8                 # concurrent browser->guest clipboard streams tracked


def cap_utf8(data, limit=CLIP_MAX):
    """`data` as valid UTF-8 of at most `limit` bytes, never splitting a character."""
    text = data.decode("utf-8", "replace")
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return raw
    return raw[:limit].decode("utf-8", "ignore").encode("utf-8")


def clip_path(key):
    return os.path.join(BRIDGE_STATE, ".%s.clip.sock" % key)


class ClipChannel(object):
    """Relay end of the helper socket. send_text(): browser text -> guest CLIPBOARD.
    read(): complete guest texts the helper has sent. `alive` goes False on any error."""

    def __init__(self, sock):
        self.sock = sock
        self.alive = True
        self._buf = b""

    def fileno(self):
        return self.sock.fileno()

    def send_text(self, data):
        if not self.alive:
            return False
        data = cap_utf8(data)
        try:
            self.sock.settimeout(5.0)
            self.sock.sendall(b"S %d\n" % len(data) + data)
            return True
        except OSError:
            self.close()
            return False
        finally:
            try:
                self.sock.settimeout(None)
            except OSError:
                pass

    def read(self):
        out = []
        try:
            chunk = self.sock.recv(65536)
        except (BlockingIOError, InterruptedError, socket.timeout):
            return out
        except OSError:
            chunk = b""
        if not chunk:
            self.close()
            return out
        self._buf += chunk
        while True:
            nl = self._buf.find(b"\n")
            if nl < 0:
                if len(self._buf) > 32:
                    self.close()
                return out
            head = self._buf[:nl].split()
            try:
                if len(head) != 2 or head[0] != b"G":
                    raise ValueError
                n = int(head[1])
                if not 0 <= n <= CLIP_MAX * 4:
                    raise ValueError
            except ValueError:
                self.close()
                return out
            if len(self._buf) < nl + 1 + n:
                return out
            out.append(cap_utf8(self._buf[nl + 1:nl + 1 + n]))
            self._buf = self._buf[nl + 1 + n:]

    def close(self):
        self.alive = False
        try:
            self.sock.close()
        except OSError:
            pass


def connect_clip(key):
    """ClipChannel for this session's helper, or None when the helper is not running
    (python-xlib missing, no XFIXES, ...): the bridge then keeps its old x11vnc path."""
    path = clip_path(key)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(2.0)
        s.connect(path)
        _pid, uid, _gid = struct.unpack("3i", s.getsockopt(
            socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        if uid != os.getuid():
            raise OSError("clip helper socket is owned by uid %d" % uid)
        s.settimeout(None)
        return ClipChannel(s)
    except OSError as exc:
        trace_log.info("clip helper not attached key=%s: %s", key, exc)
        try:
            s.close()
        except OSError:
            pass
        return None


class UpstreamClip(object):
    """Collects the browser's Guacamole clipboard streams (clipboard / blob... / end),
    text/plain only, capped at CLIP_MAX decoded bytes. Never logs contents."""

    def __init__(self):
        self._s = {}

    def start(self, stream, mimetype):
        """True when this stream is tracked (text/plain, room for it)."""
        if (mimetype or "").split(";")[0].strip().lower() != "text/plain":
            self._s.pop(stream, None)
            return False
        if len(self._s) >= CLIP_UP_STREAMS and stream not in self._s:
            return False
        self._s[stream] = bytearray()
        return True

    def tracking(self, stream):
        return stream in self._s

    def blob(self, stream, b64):
        buf = self._s.get(stream)
        if buf is None or len(buf) >= CLIP_MAX:
            return
        try:
            buf += base64.b64decode(b64 or "", validate=False)
        except (ValueError, TypeError):
            self._s[stream] = bytearray(CLIP_MAX)   # unusable: stop collecting, drop at end

    def end(self, stream):
        """The complete text (bytes, <= CLIP_MAX, valid UTF-8) or None."""
        buf = self._s.pop(stream, None)
        if buf is None or not buf:
            return None
        return cap_utf8(bytes(buf)[:CLIP_MAX])


def stop_bridge(proc, key):
    """Terminate the bridge child; its EXIT trap disposes Xvfb/xfreerdp3/x11vnc."""
    trace_log.info("bridge STOP key=%s", key)
    if proc is not None:
        try:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        except OSError:
            pass
    _safe_unlink(_env_path(key))
    _safe_unlink(_req_path(key))
    _safe_unlink(_rdplog_path(key))
    _safe_unlink(clip_path(key))


def _rdplog_path(key):
    return os.path.join(BRIDGE_STATE, "%s.rdplog" % key)


def _rdplog_tail(key, max_lines=3, max_chars=280):
    """Last few meaningful xfreerdp3 log lines for an error message. FreeRDP never
    logs the password, and we additionally keep only ERROR-ish lines."""
    try:
        with open(_rdplog_path(key), "r", errors="replace") as fh:
            lines = [l.strip() for l in fh if "ERROR" in l or "refused" in l.lower()]
    except OSError:
        return ""
    out = "; ".join(l.split("] - ")[-1] for l in lines[-max_lines:])
    return out[:max_chars]


def _read_env(path):
    out = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    k, v = line.split("=", 1)
                    out[k] = v
    except OSError:
        return None
    return out


def _safe_unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass
