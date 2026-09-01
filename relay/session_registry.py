# SPDX-License-Identifier: BSD-3-Clause
#
# session_registry — persistent per-user RDP session state for cockpit-guac-rdp.
#
# Purpose (from the session-lifecycle requirement):
#   * Track every session the relay opens, per owning uid, with state and
#     timestamps, persisted to disk so it survives a relay restart.
#   * Prune closed sessions; a disconnected GDM greeter is reaped after 60s
#     UNLESS a logon occurred (it became a real desktop session).
#   * Make backend virtual-desktop sessions RECONNECTABLE: a user reconnecting
#     is matched to their existing reusable session instead of always spawning a
#     new one.
#
# This module is pure bookkeeping (stdlib only, no I/O to guacd/grd) so it is
# fully unit-testable. The relay calls it; a separate reaper acts on prune().
#
# Time is injected (now=) so tests are deterministic — no wall-clock reads here.

import json
import os
import tempfile
import threading

# States a session moves through.
CONNECTING = "connecting"     # client attached, no ready yet
ACTIVE = "active"             # ready seen, client attached
DISCONNECTED = "disconnected" # client gone; may be reconnectable or reapable
CLOSED = "closed"             # terminated; pruned from the registry

# Scenarios whose backend session should persist across client disconnects so a
# reconnect resumes it rather than starting fresh.
RECONNECTABLE_SCENARIOS = {"isolated", "virtual"}

# Default lifecycle policy (seconds).
GREETER_DISCONNECT_TTL = 60      # reap a greeter 60s after disconnect unless logged on
SESSION_DISCONNECT_TTL = 900     # reap a logged-on desktop 15min after disconnect
CONNECTING_TTL = 120             # reap a stuck half-open connect


class Session:
    # desktop_id is the PRIMARY KEY of the persistent virtual DESKTOP this transient
    # connection (uuid) is attached to; desktop_created is that desktop's creation
    # time. The same (desktop_id, desktop_created) is reissued when a user reconnects
    # to the same desktop, so the registry tracks both the connection and the desktop.
    __slots__ = ("uuid", "uid", "scenario", "state", "created", "last_seen",
                 "logged_on", "reconnect_token", "desktop_id", "desktop_created")

    def __init__(self, uuid, uid, scenario, now, reconnect_token=None,
                 desktop_id=None, desktop_created=None):
        self.uuid = uuid
        self.uid = uid
        self.scenario = scenario
        self.state = CONNECTING
        self.created = now
        self.last_seen = now
        self.logged_on = False        # a real user logged in behind the greeter
        self.reconnect_token = reconnect_token
        self.desktop_id = desktop_id
        self.desktop_created = desktop_created

    def to_dict(self):
        return {k: getattr(self, k) for k in self.__slots__}

    @classmethod
    def from_dict(cls, d):
        s = cls(d["uuid"], d["uid"], d["scenario"], d["created"], d.get("reconnect_token"),
                d.get("desktop_id"), d.get("desktop_created"))
        s.state = d.get("state", CONNECTING)
        s.last_seen = d.get("last_seen", d["created"])
        s.logged_on = d.get("logged_on", False)
        return s


class SessionRegistry:
    """Thread-safe, disk-backed registry of sessions keyed by guacd UUID."""

    def __init__(self, state_path=None):
        self._by_uuid = {}
        self._lock = threading.RLock()
        self._state_path = state_path
        if state_path:
            self.load()

    # -- lifecycle transitions ----------------------------------------------
    def open(self, uuid, uid, scenario, now, reconnect_token=None,
             desktop_id=None, desktop_created=None):
        with self._lock:
            self._by_uuid[uuid] = Session(uuid, uid, scenario, now, reconnect_token,
                                          desktop_id, desktop_created)
            self._persist_locked()
            return self._by_uuid[uuid]

    def desktop_owner(self, desktop_id):
        """uid that owns a virtual desktop (primary key = desktop_id), or None."""
        with self._lock:
            for s in self._by_uuid.values():
                if s.desktop_id == desktop_id:
                    return s.uid
            return None

    def mark_active(self, uuid, now):
        with self._lock:
            s = self._by_uuid.get(uuid)
            if s:
                s.state = ACTIVE
                s.last_seen = now
                self._persist_locked()

    def mark_disconnected(self, uuid, now):
        with self._lock:
            s = self._by_uuid.get(uuid)
            if s:
                s.state = DISCONNECTED
                s.last_seen = now
                self._persist_locked()

    def mark_logged_on(self, uuid, now):
        """Called when a greeter transitioned to a real desktop login, so the
        60s greeter reap no longer applies."""
        with self._lock:
            s = self._by_uuid.get(uuid)
            if s:
                s.logged_on = True
                s.last_seen = now
                self._persist_locked()

    def touch(self, uuid, now):
        with self._lock:
            s = self._by_uuid.get(uuid)
            if s:
                s.last_seen = now
                self._persist_locked()

    def close(self, uuid):
        with self._lock:
            self._by_uuid.pop(uuid, None)
            self._persist_locked()

    # -- ownership / isolation (mirrors the relay's guard) ------------------
    def owner(self, uuid):
        with self._lock:
            s = self._by_uuid.get(uuid)
            return s.uid if s else None

    def may_join(self, uuid, uid):
        return self.owner(uuid) == uid

    # -- reconnection -------------------------------------------------------
    def reusable_session(self, uid, scenario, now, disconnect_ttl=SESSION_DISCONNECT_TTL):
        """Return a session this uid can RECONNECT to for `scenario`, or None.

        A session is reusable when it belongs to the uid, is a reconnectable
        scenario, is currently DISCONNECTED (client gone but backend alive),
        and has not exceeded its disconnect TTL. Greeters that never logged on
        are NOT reusable (they get reaped instead)."""
        if scenario not in RECONNECTABLE_SCENARIOS:
            return None
        with self._lock:
            best = None
            for s in self._by_uuid.values():
                if s.uid != uid or s.scenario != scenario:
                    continue
                if s.state != DISCONNECTED:
                    continue
                if scenario == "isolated" and not s.logged_on:
                    continue  # a bare greeter is not a resumable desktop
                if now - s.last_seen > disconnect_ttl:
                    continue
                if best is None or s.last_seen > best.last_seen:
                    best = s
            return best

    # -- pruning (the reaper consumes this) ---------------------------------
    def prune(self, now,
              greeter_ttl=GREETER_DISCONNECT_TTL,
              session_ttl=SESSION_DISCONNECT_TTL,
              connecting_ttl=CONNECTING_TTL):
        """Return a list of (uuid, uid, scenario, reason) that should be reaped,
        and remove them from the registry. Policy:
          * DISCONNECTED session -> reap after session_ttl (kept meanwhile so a
            reconnect resumes the same isolated desktop). NOTE: "isolated" now
            means the caller's own headless GNOME session (I29), a real desktop --
            NOT the deprecated 3390 bare greeter, so it is NOT reaped at 60s.
            Actual GDM greeter *OS* sessions are reaped separately by the reaper's
            loginctl pass using greeter_ttl.
          * CONNECTING that never became active -> reap after connecting_ttl.
        """
        reap = []
        with self._lock:
            for uuid, s in list(self._by_uuid.items()):
                age = now - s.last_seen
                reason = None
                if s.state == DISCONNECTED:
                    if age > session_ttl:
                        reason = "session idle >%ds" % session_ttl
                elif s.state == CONNECTING:
                    if age > connecting_ttl:
                        reason = "stuck connecting >%ds" % connecting_ttl
                if reason:
                    reap.append((uuid, s.uid, s.scenario, reason))
                    del self._by_uuid[uuid]
            if reap:
                self._persist_locked()
        return reap

    def snapshot(self):
        with self._lock:
            return [s.to_dict() for s in self._by_uuid.values()]

    # -- persistence (atomic write) ----------------------------------------
    def load(self):
        if not self._state_path or not os.path.exists(self._state_path):
            return
        try:
            with open(self._state_path) as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return
        with self._lock:
            self._by_uuid = {d["uuid"]: Session.from_dict(d)
                             for d in data.get("sessions", [])}

    def _persist_locked(self):
        if not self._state_path:
            return
        tmp = None
        try:
            d = os.path.dirname(self._state_path)
            os.makedirs(d, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".sessions.")
            with os.fdopen(fd, "w") as fh:
                json.dump({"sessions": [s.to_dict() for s in self._by_uuid.values()]}, fh)
            os.replace(tmp, self._state_path)
            tmp = None
        except OSError:
            pass
        finally:
            if tmp:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
