# SPDX-License-Identifier: BSD-3-Clause
#
# control.py — the relay's management API (list / terminate sessions).
#
# Exposed on a SECOND AF_UNIX socket (/run/edy-rdp/control.sock, 0660 group
# edy-rdp), separate from the guacd data socket. The Cockpit plugin's
# "Active Sessions" tab speaks newline-delimited JSON to it. The caller is
# identified by SO_PEERCRED (kernel-supplied uid); a user sees and may terminate
# only their OWN sessions, an admin sees and may terminate all. This is also
# what the Disconnect button calls to begin backend cleanup.
#
# handle_control() is a pure function (no I/O) so it is fully unit-testable; the
# socket server just wraps it.

import json
import threading
import time


class LiveConnections:
    """uuid -> terminate() for the data connections currently open, so the
    control API can actually close a live session (not just mark the registry).
    Thread-safe."""

    def __init__(self):
        self._by_uuid = {}
        self._lock = threading.Lock()

    def register(self, uuid, terminate_fn):
        with self._lock:
            self._by_uuid[uuid] = terminate_fn

    def unregister(self, uuid):
        with self._lock:
            self._by_uuid.pop(uuid, None)

    def has(self, uuid):
        with self._lock:
            return uuid in self._by_uuid

    def terminate(self, uuid):
        with self._lock:
            fn = self._by_uuid.get(uuid)
        if fn is None:
            return False
        try:
            fn()
        except Exception:
            pass
        return True

    def uuids(self):
        with self._lock:
            return list(self._by_uuid.keys())


def handle_control(request, peer_uid, registry, live, is_admin, tokens=None,
                   unlock=None, deskui=None):
    """Dispatch one control request. Returns a JSON-serialisable dict.

    request: parsed dict with "op" in {"list","terminate","ping","register","elevate"}.
    peer_uid: SO_PEERCRED uid of the caller (authoritative).
    registry: SessionRegistry.
    live: LiveConnections.
    is_admin: bool — may the caller see/act on other users' sessions (sudo-group).
    tokens: SessionTokens — the desktop-session token table (register/elevate).
    unlock: optional callable(uid) -> (ok, detail). Injected rather than called
        directly so this function stays pure and testable; the relay supplies the
        implementation that starts the privileged unit.
    deskui: optional desktop-UI controller (duck-typed). Injected the same way as
        unlock so the policy here (admin gate, opt-in gate, typed confirmation,
        force decision) stays pure and unit-testable while the systemctl I/O lives
        in the relay. Must expose:
          .write_enabled -> bool   host opted in to write actions
          .hostname      -> str    this host's name (the confirmation phrase)
          .status()      -> dict   current desktop/DM/session state
          .control(action, force) -> (ok, detail)   run the privileged verb
    """
    if not isinstance(request, dict):
        return {"ok": False, "error": "malformed request"}
    op = request.get("op")

    if op == "ping":
        return {"ok": True, "uid": peer_uid, "admin": bool(is_admin)}

    # -- desktop-session token registration (KNOWN_ISSUES I2/I4) --------------
    if op == "register":
        if tokens is None:
            return {"ok": False, "error": "token table unavailable"}
        token, chal_path = tokens.issue(peer_uid, time.time())
        # The caller reads chal_path over a SUPERUSER Cockpit channel (only an
        # elevated session can) and echoes the challenge back via "elevate".
        return {"ok": True, "uid": peer_uid, "token": token, "challenge_path": chal_path}

    if op == "elevate":
        if tokens is None:
            return {"ok": False, "error": "token table unavailable"}
        token = request.get("token")
        challenge = request.get("challenge")
        if not token or challenge is None:
            return {"ok": False, "error": "elevate requires token + challenge"}
        ok = tokens.elevate(token, peer_uid, challenge)
        return {"ok": bool(ok), "admin": bool(ok),
                "error": None if ok else "elevation proof rejected"}

    # -- unlock the caller's own locked graphical seat session ----------------
    #
    # Admin-only, and narrow by construction: the helper this delegates to
    # refuses any session that is not owned by peer_uid, on a seat, graphical,
    # active and locked. It exists because nothing else can reach a locked local
    # session -- the greeter opens a NEW one, and grd refuses console/virtual
    # while the seat is locked.
    if op == "unlock":
        if not is_admin:
            return {"ok": False, "error": "unlocking the physical session needs "
                                          "administrative access"}
        if unlock is None:
            return {"ok": False, "error": "unlock is not available on this server"}
        ok, detail = unlock(peer_uid)
        return {"ok": bool(ok), "detail": detail}

    # -- desktop-UI control: read current state -------------------------------
    #
    # Read-only, so any authenticated caller may run it (SO_PEERCRED identifies
    # them regardless). It reports the boot default target, the display manager
    # and whether it is running/enabled, and how many graphical seat sessions are
    # in use right now -- the number the UI shows before offering a Stop.
    if op == "deskui-status":
        if deskui is None:
            return {"ok": False, "error": "desktop UI control is not available on this server"}
        out = {"ok": True, "admin": bool(is_admin),
               "write_enabled": bool(deskui.write_enabled),
               "hostname": deskui.hostname}
        try:
            out.update(deskui.status())
        except Exception as exc:                       # never let a probe error 500 the panel
            out["ok"] = False
            out["error"] = "could not read desktop state: %s" % exc
        return out

    # -- desktop-UI control: enable / disable / start / stop ------------------
    #
    # Gated in three independent layers, every one server-side (a client check is
    # cosmetic):
    #   * admin        -- same gate as unlock; SO_PEERCRED + admin group.
    #   * opt-in       -- write_enabled reflects EDY_RDP_DESKUI_ENABLE; a host that
    #                     did not opt in (an operator's own workstation) refuses
    #                     every write here, so the feature is inert unless asked for.
    #   * confirmation -- 'stop' and 'disable' require the caller to have typed this
    #                     host's name. Without it they are refused with need_confirm,
    #                     so the UI can prompt. Stopping while a desktop is in use
    #                     additionally escalates to the forced verb -- only reachable
    #                     through this confirmed path.
    if op == "deskui":
        if deskui is None:
            return {"ok": False, "error": "desktop UI control is not available on this server"}
        action = request.get("action")
        if action not in ("enable", "disable", "start", "stop"):
            return {"ok": False, "error": "unknown desktop-ui action: %r" % (action,)}
        if not is_admin:
            return {"ok": False, "error": "changing the desktop UI needs administrative access"}
        if not deskui.write_enabled:
            return {"ok": False, "error": "desktop UI control is disabled on this host "
                    "(an administrator must set EDY_RDP_DESKUI_ENABLE=1 to opt in)"}
        force = False
        if action in ("stop", "disable"):
            try:
                live_n = int((deskui.status() or {}).get("active_graphical_sessions") or 0)
            except Exception:
                live_n = 0
            if request.get("confirm") != deskui.hostname:
                return {"ok": False, "error": "confirmation required",
                        "need_confirm": True, "hostname": deskui.hostname,
                        "active_graphical_sessions": live_n,
                        "detail": "type this host's name (%s) to confirm" % deskui.hostname}
            # Confirmed. Only 'stop' with a desktop in use needs the forced verb;
            # 'disable' changes the boot default and never kills a live session.
            if action == "stop" and live_n > 0:
                force = True
        ok, detail = deskui.control(action, force)
        return {"ok": bool(ok), "action": action, "forced": bool(force), "detail": detail}

    if op == "list":
        sessions = []
        for s in registry.snapshot():
            if not is_admin and s.get("uid") != peer_uid:
                continue
            sessions.append({
                "uuid": s.get("uuid"),
                "uid": s.get("uid"),
                "scenario": s.get("scenario"),
                "state": s.get("state"),
                "created": s.get("created"),
                "last_seen": s.get("last_seen"),
                "logged_on": s.get("logged_on"),
                "desktop_id": s.get("desktop_id"),          # virtual-desktop primary key
                "desktop_created": s.get("desktop_created"),
                "live": live.has(s.get("uuid")),
                "mine": s.get("uid") == peer_uid,
            })
        return {"ok": True, "uid": peer_uid, "admin": bool(is_admin), "sessions": sessions}

    if op == "terminate":
        uuid = request.get("uuid")
        if not uuid:
            return {"ok": False, "error": "terminate requires a uuid"}
        owner = registry.owner(uuid)
        if owner is None:
            # not in the registry — maybe already gone; treat as success if we
            # can't find it and the caller would have been allowed anyway.
            if not live.has(uuid):
                return {"ok": True, "uuid": uuid, "already_gone": True}
        if not is_admin and owner is not None and owner != peer_uid:
            return {"ok": False, "error": "not permitted to terminate another user's session"}
        killed = live.terminate(uuid)
        registry.close(uuid)
        return {"ok": True, "uuid": uuid, "terminated_live": killed}

    if op == "prune":
        # Maintenance op driven by the reaper (root). The RELAY is the sole
        # writer/authority of the registry, so the reaper prunes THROUGH here
        # rather than editing the state file behind our back (two registries +
        # one file => lost updates; a reaped entry would just be re-persisted by
        # the relay). Admin-only because it acts across all users' sessions.
        if not is_admin:
            return {"ok": False, "error": "prune requires admin"}
        now = request.get("now")
        if now is None:
            return {"ok": False, "error": "prune requires now"}
        kwargs = {}
        for k in ("greeter_ttl", "session_ttl", "connecting_ttl", "ephemeral_ttl"):
            v = request.get(k)
            if v is not None:
                kwargs[k] = v
        reaped = registry.prune(now, **kwargs)
        for uuid, _uid, _scn, _reason in reaped:
            live.terminate(uuid)  # drop any lingering live conn (normally none)
        return {"ok": True, "reaped": [
            {"uuid": u, "uid": uid, "scenario": scn, "reason": r}
            for (u, uid, scn, r) in reaped
        ]}

    return {"ok": False, "error": "unknown op: %s" % op}
