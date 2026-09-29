# SPDX-License-Identifier: BSD-3-Clause
#
# selfupdate.py — self-update: check this project's own GitHub repo for a newer
# tagged Release than what is installed, and apply/roll back that update.
#
# stdlib only (this project's stated philosophy: "relay/reaper are stdlib Python
# 3, no PyPI dependencies"). Imported by BOTH the unprivileged relay (for
# read-mostly status/check, and to kick off the privileged units) and the two
# ROOT-run helpers in selfupdate/ (for the actual fetch/extract/deploy/rollback
# mechanics) — one copy of the version parsing, the GitHub call, the cache
# format and the payload-directory bookkeeping, never two that could disagree.
#
# TRUST MODEL (see docs/SELFUPDATE.md for the full statement): this verifies
# TLS to api.github.com/codeload.github.com and nothing more. There is no
# code-signing or GPG verification of the fetched tarball in this pass — a
# compromise of the repository owner's GitHub account is a compromise of every
# host that applies an update. Documented as a known limitation, not hidden.
#
# Privilege boundary: the two privileged units this module's callers start are
# NON-templated and take NO argument at all (no %i, no caller-supplied version
# string). "apply" always means "whatever THIS module's OWN fresh GitHub call
# says is latest" and "rollback" always means "whichever payload-<version>
# directory is not the current `payload` symlink target" — both re-derived here,
# never trusted from a caller. Zero caller-influenced data crosses the
# `systemctl start` boundary.

import contextlib
import fcntl
import json
import os
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

# --- constants ---------------------------------------------------------------

CACHE_PATH = "/run/edy-rdp/update-status.json"
CACHE_TTL = 24 * 3600          # status() kicks a background refresh past this age
CHECK_RATE_LIMIT = 60          # update-check is synchronous; throttle it server-side
GITHUB_API_TIMEOUT = 10
TARBALL_FETCH_TIMEOUT = 60
CONTROL_SOCK = "/run/edy-rdp/control.sock"
INSTALL_CONF = "/etc/cockpit-guac-rdp/install.conf"

# Same account/group install.sh's manifest declares (RELAY_USER/RELAY_GROUP).
# Not read from there (this module has no shell dependency); kept in sync by
# hand, same as the relay already hardcodes "cockpit-guac-rdp" as its default --group.
RELAY_USER = "edy-relay"
RELAY_GROUP = "cockpit-guac-rdp"

APPLY_UNIT = "edy-rdp-selfupdate-apply.service"
ROLLBACK_UNIT = "edy-rdp-selfupdate-rollback.service"
APPLY_TIMEOUT = 300     # network fetch + extract + deploy.sh + restart + health-check(+rollback)
ROLLBACK_TIMEOUT = 120
RELAY_UNIT = "edy-rdp-relay.service"

HEALTH_TOTAL_TIMEOUT = 20      # total time to wait for the relay to come back healthy
HEALTH_ATTEMPT_TIMEOUT = 3     # per-attempt (systemctl is-active / control-socket ping)
HEALTH_POLL_INTERVAL = 1.0


class SelfUpdateError(Exception):
    """A GitHub call or a fetch/extract step failed. Message is operator-facing."""


class NoReleasesError(SelfUpdateError):
    """This repo has no GitHub Releases published yet (HTTP 404 on
    .../releases/latest). A known, calm, day-one state (docs/SELFUPDATE.md) --
    NOT a failure -- kept as its own type so callers can tell it apart from a
    real outage without string-matching the message."""


class AlreadyRunning(Exception):
    """Another apply/rollback is already in progress on this host."""


LOCK_NAME = ".selfupdate.lock"


@contextlib.contextmanager
def exclusive_run(root):
    """Hold an exclusive, non-blocking lock for the ENTIRE duration of one
    privileged apply or rollback run (both scripts wrap their whole main() in
    this). Without it, an admin clicking 'Roll back' while 'Update now' is
    still in flight (a real scenario: apply can take up to APPLY_TIMEOUT, and
    an admin who thinks it looks stuck is exactly who reaches for the recovery
    button) starts a SECOND oneshot unit that races the first one's swap of the
    SAME `payload` symlink and its restart of the SAME relay unit -- found by
    review, reproduced (two processes racing swap_payload_and_install() lost
    the payload symlink update about half the time in a stress test). Raises
    AlreadyRunning immediately (LOCK_NB) rather than queuing: the caller should
    refuse and say so, not silently block for minutes behind someone else's run."""
    path = os.path.join(root, LOCK_NAME)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        raise AlreadyRunning()
    try:
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


# --- version parse/compare ---------------------------------------------------
#
# This project's scheme is maj.min.patch.YYYYMMDD (VERSION, manifest.json,
# CHANGELOG.md headings), optionally prefixed 'v' in a git tag ("v1.7.0.20260929").


def parse_version(v):
    """"v1.7.0.20260929" | "1.7.0.20260929" -> (1,7,0,20260929), or None if it
    does not parse. Never raises — garbage input is a None, not an exception, so
    a malformed tag can never crash the comparison or be reported as an update."""
    if not v or not isinstance(v, str):
        return None
    s = v.strip()
    if s[:1] in ("v", "V"):
        s = s[1:]
    parts = s.split(".")
    if len(parts) != 4:
        return None
    try:
        return tuple(int(p) for p in parts)
    except ValueError:
        return None


def compare_versions(a, b):
    """-1/0/1 for already-parsed 4-tuples a, b."""
    if a == b:
        return 0
    return -1 if a < b else 1


def is_newer(current_str, candidate_str):
    """True iff candidate is a well-formed version strictly newer than current.
    Either side failing to parse -> False (fail closed: never claims an update
    is available on garbage input)."""
    c = parse_version(current_str)
    d = parse_version(candidate_str)
    if c is None or d is None:
        return False
    return compare_versions(c, d) < 0


# --- this host's install -----------------------------------------------------
#
# Never resolved relative to this file (a symlink into whichever payload is
# current) — read from /etc/cockpit-guac-rdp/install.conf, which install.sh
# writes at every install, the same source edy_rdp_relay.py's _env_file_hint()
# already trusts for the same reason (DEPLOY-CONTRACT 4.3).


def _read_install_conf(key):
    try:
        with open(INSTALL_CONF, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        return None
    return None


def current_version():
    return _read_install_conf("VERSION")


def install_root():
    return _read_install_conf("INSTALL_PATH")


# --- payload-directory bookkeeping (for rollback) ----------------------------


def _payload_dirs(root):
    try:
        entries = os.listdir(root)
    except OSError:
        return []
    return sorted(e for e in entries
                  if e.startswith("payload-") and os.path.isdir(os.path.join(root, e)))


def current_payload_name(root):
    """Basename the `payload` symlink resolves to (e.g. 'payload-1.7.0.20260929'),
    or None if it is missing or not a symlink."""
    link = os.path.join(root, "payload")
    try:
        target = os.readlink(link)
    except OSError:
        return None
    return os.path.basename(target.rstrip("/"))


def version_from_payload_name(name):
    if name and name.startswith("payload-"):
        return name[len("payload-"):]
    return None


def rollback_candidate(root):
    """(True, "payload-<version>") the ONE directory to roll back to, or
    (False, reason) in reason in {"no-root","no-current","none","ambiguous"}.
    Refuses (does not guess) unless exactly one non-current payload dir exists —
    the same refusal the privileged rollback script itself makes (exit 2)."""
    if not root:
        return (False, "no-root")
    current = current_payload_name(root)
    if current is None:
        return (False, "no-current")
    others = [d for d in _payload_dirs(root) if d != current]
    if not others:
        return (False, "none")
    if len(others) > 1:
        return (False, "ambiguous")
    return (True, others[0])


# --- cache: /run/edy-rdp/update-status.json ----------------------------------
#
# Written by BOTH the unprivileged relay (background/forced checks) and the
# ROOT-run apply/rollback scripts (recording the outcome in "last_apply").
# Write-to-temp-then-rename is atomic against a concurrent reader; the chown
# back to edy-relay:cockpit-guac-rdp is what lets the relay keep reading (and later
# rewriting) the file after a ROOT process last touched it. When the relay
# itself writes, this is a same-uid no-op (it already owns the file); when a
# root-run script writes it, this is the actual handoff.


def _chown_cache(path):
    try:
        import grp
        import pwd
        uid = pwd.getpwnam(RELAY_USER).pw_uid
        gid = grp.getgrnam(RELAY_GROUP).gr_gid
        os.chown(path, uid, gid)
    except (KeyError, OSError):
        pass          # best-effort: a dev/staged environment may have neither
    try:
        os.chmod(path, 0o644)
    except OSError:
        pass


def read_cache(path=CACHE_PATH):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def write_cache(data, path=CACHE_PATH):
    d = os.path.dirname(path) or "."
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(prefix=".update-status-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
            fh.write("\n")
        os.rename(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    _chown_cache(path)


def cache_is_stale(cache, ttl=CACHE_TTL, now=None):
    now = time.time() if now is None else now
    if not cache:
        return True
    checked = cache.get("checked_at")
    if not checked:
        return True
    return (now - checked) > ttl


_UNSET = object()   # sentinel: "last_apply not being overridden" vs. "clear it"


def _do_live_check(repo, path, last_apply=_UNSET):
    """The one GitHub-comparison-then-cache-write, shared by SelfUpdate's own
    background/forced refresh and by record_apply_result() (called by the
    ROOT-run apply/rollback scripts once current_version() has just changed).
    A GitHub failure keeps the PREVIOUS latest_version/release fields (an
    outage does not make a real update disappear from the cache) and only
    records the new check_error; it never raises."""
    prev = read_cache(path) or {}
    entry = {"checked_at": time.time(),
             "last_apply": prev.get("last_apply") if last_apply is _UNSET else last_apply}
    try:
        rel = check_latest_release(repo, timeout=GITHUB_API_TIMEOUT)
    except SelfUpdateError as exc:
        entry.update({
            "latest_version": prev.get("latest_version"),
            "update_available": False,
            "release_name": prev.get("release_name"),
            "release_notes_url": prev.get("release_notes_url"),
            "published_at": prev.get("published_at"),
            "check_error": str(exc),
            # Typed, not string-matched: found by review that treating "no
            # releases published yet" (an expected, calm, day-one state for a
            # repo with none — see docs/SELFUPDATE.md) the same as a real
            # outage made the UI render it as a bold error on this very repo.
            "no_releases": isinstance(exc, NoReleasesError),
        })
        write_cache(entry, path)
        return entry
    entry.update({
        "latest_version": rel["tag_name"],
        "update_available": is_newer(current_version(), rel["tag_name"]),
        "release_name": rel.get("release_name"),
        "release_notes_url": rel.get("release_notes_url"),
        "published_at": rel.get("published_at"),
        "check_error": None,
        "no_releases": False,
    })
    write_cache(entry, path)
    return entry


def record_apply_result(repo, last_apply_entry, path=CACHE_PATH):
    """Called by the privileged apply/rollback scripts right after
    current_version() has actually changed (a successful apply, or a failed
    apply that the automatic rollback recovered from): records last_apply AND
    re-derives latest_version/update_available with one more live GitHub call
    against the NEW current_version, so a caller reading update-status right
    afterward sees the host's real state (update_available flips to false post-
    apply; rollback_available flips to true) rather than the stale pre-change
    cache. Best-effort against GitHub: a network hiccup here just leaves the
    prior comparison, which self-corrects at the relay's next TTL-driven
    refresh or an operator's own update-check."""
    return _do_live_check(repo, path, last_apply=last_apply_entry)


# --- the GitHub call ----------------------------------------------------------


def check_latest_release(repo, timeout=GITHUB_API_TIMEOUT):
    """GET .../releases/latest. Returns a dict (tag_name, release_name,
    release_notes_url, tarball_url, published_at) or raises SelfUpdateError with
    an operator-facing message — including the expected case on a repo with no
    Releases yet (HTTP 404), which is NOT a bug (see docs/SELFUPDATE.md)."""
    if not repo:
        raise SelfUpdateError("no GitHub repository configured (EDY_RDP_UPDATE_REPO)")
    url = "https://api.github.com/repos/%s/releases/latest" % repo
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "cockpit-guac-rdp-selfupdate",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout,
                                    context=ssl.create_default_context()) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise NoReleasesError("no releases published yet for %s" % repo)
        raise SelfUpdateError("GitHub API returned HTTP %s for %s" % (exc.code, repo))
    except (urllib.error.URLError, OSError) as exc:
        raise SelfUpdateError("could not reach GitHub: %s" % exc)
    try:
        data = json.loads(raw.decode("utf-8", "replace"))
    except ValueError as exc:
        raise SelfUpdateError("GitHub returned unparseable JSON: %s" % exc)
    tag = data.get("tag_name") if isinstance(data, dict) else None
    if not tag:
        raise SelfUpdateError("GitHub release JSON had no tag_name")
    return {
        "tag_name": tag,
        "release_name": data.get("name") or tag,
        "release_notes_url": data.get("html_url"),
        "tarball_url": data.get("tarball_url"),
        "published_at": data.get("published_at"),
    }


# --- fetch + extract (path-traversal guarded) --------------------------------


def fetch_and_extract_release(tarball_url, dest_dir, timeout=TARBALL_FETCH_TIMEOUT):
    """Download tarball_url (a GitHub per-release tarball: one top-level dir
    holding the full repo tree at that tag, deploy.sh included) into dest_dir.
    Returns the path to that one top-level directory. Raises SelfUpdateError on
    any failure — nothing on the host has been touched yet when this raises."""
    if not tarball_url:
        raise SelfUpdateError("release JSON carried no tarball_url")
    req = urllib.request.Request(tarball_url, headers={"User-Agent": "cockpit-guac-rdp-selfupdate"})
    try:
        with urllib.request.urlopen(req, timeout=timeout,
                                    context=ssl.create_default_context()) as resp:
            blob = resp.read()
    except (urllib.error.URLError, OSError) as exc:
        raise SelfUpdateError("could not download the release tarball: %s" % exc)
    try:
        os.makedirs(dest_dir, exist_ok=True)
    except OSError as exc:
        raise SelfUpdateError("could not create extraction directory: %s" % exc)
    fd, tar_path = tempfile.mkstemp(prefix="edy-rdp-selfupdate-", suffix=".tar.gz")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(blob)
        _safe_extract(tar_path, dest_dir)
    finally:
        try:
            os.unlink(tar_path)
        except OSError:
            pass
    tops = [e for e in os.listdir(dest_dir) if os.path.isdir(os.path.join(dest_dir, e))]
    if len(tops) != 1:
        raise SelfUpdateError(
            "release tarball did not extract to exactly one top-level directory "
            "(found %d)" % len(tops))
    return os.path.join(dest_dir, tops[0])


def _safe_extract(tar_path, dest_dir):
    """extractall() guarded against path traversal: try the filter="data" kwarg
    (Python 3.12+, and backported to 3.9.17/3.10.12/3.11.4+ — CVE-2007-4559-class
    protection built in); on an interpreter without it (requires.txt only pins
    python3 >=3.9, so an unpatched 3.9-3.11 is possible) fall back to a manual
    per-member check before extracting anything.

    The manual fallback's containment check uses realpath() on each member's
    OWN path, which cannot see a not-yet-extracted symlink: a member "evil" that
    IS a symlink to somewhere outside dest_dir, followed by a member
    "evil/pwned" nested under it, both pass the per-member realpath check (the
    "evil" path component doesn't exist on disk yet), and extractall() would
    then create the symlink and write "pwned" through it. Reviewed and found to
    be unreachable via a genuine GitHub-generated tarball (a git tree cannot
    hold both a symlink entry and a file entry nested under the same name — one
    tree entry is either a blob or a subtree, never both), so this is defence
    in depth rather than a fix for a reachable bug: reject any symlink/hardlink
    member outright in the fallback path, the same way filter="data" already
    would on a newer interpreter."""
    import tarfile
    dest_real = os.path.realpath(dest_dir)
    with tarfile.open(tar_path, "r:*") as tf:
        try:
            tf.extractall(dest_dir, filter="data")
            return
        except TypeError:
            pass   # this Python has no `filter=` kwarg — fall through
        except tarfile.TarError as exc:
            # filter="data" itself rejected the tarball (traversal, an
            # absolute/outside-destination link, a device/special file, ...) --
            # found by testing: this propagated as a raw tarfile exception
            # instead of SelfUpdateError, which the caller only catches as the
            # latter, so a malicious/malformed tarball crashed the privileged
            # script with an uncaught traceback (exit 1, unclassified) instead
            # of the intended "fetch/extract failed, nothing touched" (exit 3).
            raise SelfUpdateError(
                "refusing to extract release tarball: %s" % exc) from exc
        for member in tf.getmembers():
            if member.issym() or member.islnk():
                raise SelfUpdateError(
                    "refusing to extract %r: link members are not permitted "
                    "in a release tarball" % member.name)
            member_path = os.path.realpath(os.path.join(dest_dir, member.name))
            if member_path != dest_real and not member_path.startswith(dest_real + os.sep):
                raise SelfUpdateError(
                    "refusing to extract %r outside %s (path traversal in the "
                    "release tarball)" % (member.name, dest_dir))
        tf.extractall(dest_dir)


# --- health check --------------------------------------------------------------
#
# Runs from the ROOT-run privileged script, so a plain subprocess/socket call —
# nothing fancy. Gates AUTOMATIC rollback, so it must work with no browser open:
# `systemctl is-active` first, then a real control-socket ping, retried for up to
# HEALTH_TOTAL_TIMEOUT (the relay needs a moment to restart).


def relay_is_active(timeout=HEALTH_ATTEMPT_TIMEOUT):
    try:
        p = subprocess.run(["systemctl", "is-active", "--quiet", RELAY_UNIT], timeout=timeout)
        return p.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def ping_control_socket(sock_path=CONTROL_SOCK, timeout=HEALTH_ATTEMPT_TIMEOUT):
    s = None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(sock_path)
        s.sendall(b'{"op":"ping"}\n')
        buf = b""
        while b"\n" not in buf and len(buf) < 65536:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        line = buf.split(b"\n", 1)[0]
        resp = json.loads(line.decode("utf-8", "replace"))
        return bool(resp.get("ok"))
    except Exception:
        return False
    finally:
        if s is not None:
            try:
                s.close()
            except OSError:
                pass


def wait_for_healthy(total_timeout=HEALTH_TOTAL_TIMEOUT,
                     attempt_timeout=HEALTH_ATTEMPT_TIMEOUT,
                     sock_path=CONTROL_SOCK, poll_interval=HEALTH_POLL_INTERVAL,
                     sleep_fn=time.sleep, clock_fn=time.monotonic):
    deadline = clock_fn() + total_timeout
    while True:
        if relay_is_active(timeout=attempt_timeout) and ping_control_socket(sock_path, timeout=attempt_timeout):
            return True
        if clock_fn() >= deadline:
            return False
        sleep_fn(poll_interval)


# --- privileged mechanics shared by apply (on health-check failure) and the
# standalone rollback script: point `payload` at an EXISTING payload-<version>
# directory and run THAT directory's own install.sh (exactly the recipe
# deploy.sh itself prints under "rollback:" in do_deploy()'s closing banner) --
# never re-invented here.


def swap_payload_and_install(root, payload_name, timeout=150):
    target = os.path.join(root, payload_name)
    if not os.path.isdir(target):
        return (False, "%s does not exist" % target)
    link = os.path.join(root, "payload")
    # Per-process name, not the fixed "payload.new" deploy.sh itself uses --
    # exclusive_run() is what actually prevents two privileged runs from
    # overlapping, but a unique name here means even a bypass of that lock
    # (e.g. someone starting the unit by hand outside the normal flow) cannot
    # collide on the same temp path, matching deploy.sh's own versioned
    # "$NEW.tmp" convention rather than a single shared scratch name.
    new_link = os.path.join(root, "payload.new.%d" % os.getpid())
    try:
        os.symlink(payload_name, new_link)
        os.replace(new_link, link)
    except OSError as exc:
        try:
            os.unlink(new_link)   # best-effort: don't leave an orphaned temp symlink
        except OSError:
            pass
        return (False, "could not swap the payload symlink: %s" % exc)
    install_sh = os.path.join(target, "install.sh")
    try:
        p = subprocess.run([install_sh], cwd=target, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return (False, "install.sh did not run: %s" % exc)
    if p.returncode != 0:
        tail = p.stdout.decode("utf-8", "replace")[-2000:] if p.stdout else ""
        return (False, "install.sh exited %d:\n%s" % (p.returncode, tail))
    return (True, "payload -> %s (install.sh completed)" % payload_name)


def daemon_reload(timeout=30):
    """Explicit defense in depth: install.sh's OWN unit-render branch already
    calls this for a deployed layout (verified in do_install() — the skip
    condition is `KIND == dev && !WITH_UNITS`, which is false here since a
    deployed tree is never KIND=dev), so this is normally a harmless repeat, not
    the only thing standing between a changed edy-rdp-relay.service and it
    taking effect. It is called anyway, unconditionally, so that invariant is
    never load-bearing for this feature specifically."""
    try:
        subprocess.run(["systemctl", "daemon-reload"], timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


def restart_relay(timeout=60):
    try:
        subprocess.run(["systemctl", "restart", RELAY_UNIT], check=True, timeout=timeout,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        return (True, None)
    except subprocess.CalledProcessError as exc:
        return (False, (exc.stderr or b"").decode("utf-8", "replace").strip()[:300])
    except (OSError, subprocess.TimeoutExpired) as exc:
        return (False, str(exc))


# --- systemctl exit-code plumbing (mirrors DesktopUI.control()'s idiom) ------


def _exec_main_status(unit, timeout=8):
    try:
        p = subprocess.run(["systemctl", "show", "-p", "ExecMainStatus", "--value", unit],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        return p.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


# --- the object the relay injects into handle_control() ----------------------
#
# Mirrors DesktopUI's shape: a small controller the pure handle_control() calls
# through an injection point, so ITS policy (admin gate, typed-hostname confirm)
# stays testable with no systemctl/network I/O, while all of that I/O lives here.


class SelfUpdate:
    def __init__(self, repo=None, cache_path=CACHE_PATH, cache_ttl=CACHE_TTL,
                rate_limit=CHECK_RATE_LIMIT):
        self.repo = repo or None
        self.cache_path = cache_path
        self.cache_ttl = cache_ttl
        self.rate_limit = rate_limit
        self._refresh_lock = threading.Lock()
        self._refreshing = False
        self._rate_lock = threading.Lock()
        self._last_live_check = 0.0
        try:
            self.hostname = socket.gethostname() or os.uname().nodename
        except OSError:
            self.hostname = "this-host"

    # -- response building ----------------------------------------------------
    def _build(self, cache, rate_limited=None):
        cache = cache or {}
        root = install_root()
        rollback_available = False
        rollback_version = None
        if root:
            ok, val = rollback_candidate(root)
            if ok:
                rollback_available = True
                rollback_version = version_from_payload_name(val)
        out = {
            "ok": True,
            "current_version": current_version(),
            "latest_version": cache.get("latest_version"),
            "update_available": bool(cache.get("update_available")),
            "release_name": cache.get("release_name"),
            "release_notes_url": cache.get("release_notes_url"),
            "published_at": cache.get("published_at"),
            "checked_at": cache.get("checked_at"),
            "check_error": cache.get("check_error"),
            "no_releases": bool(cache.get("no_releases")),
            "rollback_available": rollback_available,
            "rollback_version": rollback_version,
            "last_apply": cache.get("last_apply"),
        }
        if rate_limited is not None:
            out["rate_limited"] = bool(rate_limited)
        return out

    # -- read-mostly ops --------------------------------------------------------
    def status(self):
        """Never blocks on the network. Serves the cache as-is; kicks a
        background refresh when it is missing or older than cache_ttl."""
        cache = read_cache(self.cache_path)
        if cache_is_stale(cache, self.cache_ttl):
            self._kick_background_refresh()
        return self._build(cache)

    def check_now(self):
        """Synchronous, but rate-limited to once per `rate_limit` seconds
        wall-clock regardless of caller: inside that window, serves the cache
        with rate_limited=True instead of erroring or re-hitting GitHub."""
        now = time.time()
        with self._rate_lock:
            if now - self._last_live_check < self.rate_limit:
                return self._build(read_cache(self.cache_path), rate_limited=True)
            self._last_live_check = now
        self._live_check()
        return self._build(read_cache(self.cache_path), rate_limited=False)

    def _kick_background_refresh(self):
        with self._refresh_lock:
            if self._refreshing:
                return
            self._refreshing = True

        def _run():
            try:
                self._live_check()
            finally:
                with self._refresh_lock:
                    self._refreshing = False
        threading.Thread(target=_run, daemon=True).start()

    def _live_check(self):
        _do_live_check(self.repo, self.cache_path)

    # -- write ops: gated by handle_control() (admin + typed-confirm live there,
    # same split as DesktopUI); these methods are the mechanism only. Each
    # returns (ok, detail, rolled_back) where rolled_back is:
    #   None   nothing was attempted (refused before touching the unit at all)
    #   True   the update failed health and the automatic rollback succeeded
    #   False  either the write itself failed, or (only possible on apply) the
    #          update failed health AND the rollback also failed
    def apply(self):
        cache = read_cache(self.cache_path)
        if not cache or not cache.get("update_available"):
            return (False, "no update available", None)
        prev_version = current_version() or "the previous version"
        latest = cache.get("latest_version") or "the latest version"
        try:
            subprocess.run(["systemctl", "start", APPLY_UNIT], check=True,
                           timeout=APPLY_TIMEOUT, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as exc:
            return self._map_apply_failure(exc, latest, prev_version)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return (False, "self-update apply failed: %s" % exc, False)
        return (True, "updated to %s and healthy" % latest, False)

    def _map_apply_failure(self, exc, latest, prev_version):
        code = _exec_main_status(APPLY_UNIT)
        detail = (exc.stderr or b"").decode("utf-8", "replace").strip()[:300]
        if code == "2":
            return (False, "no update available", None)
        if code == "3":
            return (False, detail or (
                "could not fetch, extract or deploy %s; nothing on this host "
                "was touched" % latest), None)
        if code == "4":
            return (False, "update to %s failed its health check and was "
                    "automatically rolled back to %s" % (latest, prev_version), True)
        if code == "5":
            return (False, "update to %s failed its health check AND the "
                    "automatic rollback also failed -- this host needs a human "
                    "right now" % latest, False)
        if code == "6":
            return (False, "an apply or rollback is already in progress on "
                    "this host; wait for it to finish and try again", None)
        return (False, detail or ("self-update apply failed (exit status %r)" % code), False)

    #: rollback_candidate()'s refusal reasons, translated to an operator-facing
    #: message -- found by review: collapsing "ambiguous" (more than one older
    #: payload dir on disk) into the same text as "none" told an operator
    #: nothing exists to roll back to on a host where multiple actually do.
    _ROLLBACK_REFUSAL_MESSAGES = {
        "no-root": "install path is unknown; cannot roll back",
        "no-current": "this host's `payload` symlink is missing or broken; "
                      "cannot determine what to roll back FROM",
        "none": "no earlier version is available to roll back to on this host",
        "ambiguous": "more than one earlier version exists on this host; an "
                     "operator must remove the extra payload-<version> "
                     "directory before an automatic rollback can pick one",
    }

    def rollback(self):
        root = install_root()
        if not root:
            return (False, self._ROLLBACK_REFUSAL_MESSAGES["no-root"], None)
        ok, val = rollback_candidate(root)
        if not ok:
            return (False, self._ROLLBACK_REFUSAL_MESSAGES.get(
                val, "no earlier version is available to roll back to "
                     "on this host"), None)
        target = version_from_payload_name(val) or val
        try:
            subprocess.run(["systemctl", "start", ROLLBACK_UNIT], check=True,
                           timeout=ROLLBACK_TIMEOUT, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as exc:
            return self._map_rollback_failure(exc, target)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return (False, "self-update rollback failed: %s" % exc, False)
        return (True, "rolled back to %s and healthy" % target, False)

    def _map_rollback_failure(self, exc, target):
        code = _exec_main_status(ROLLBACK_UNIT)
        detail = (exc.stderr or b"").decode("utf-8", "replace").strip()[:300]
        if code == "2":
            return (False, "no earlier version is available to roll back to "
                    "on this host", None)
        if code == "3":
            return (False, detail or (
                "rollback to %s failed; the relay may be in a bad state and "
                "needs a human" % target), False)
        if code == "6":
            return (False, "an apply or rollback is already in progress on "
                    "this host; wait for it to finish and try again", None)
        return (False, detail or ("self-update rollback failed (exit status %r)" % code), False)
