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

import logging
import os
import re
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
