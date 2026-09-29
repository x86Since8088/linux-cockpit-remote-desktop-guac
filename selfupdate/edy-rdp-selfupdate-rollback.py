#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
#
# edy-rdp-selfupdate-rollback — swap this host's `payload` symlink back to
# whichever payload-<version> directory is NOT the current one, and restart the
# relay.
#
# Runs as ROOT, started through the edy-rdp-selfupdate-rollback.service oneshot
# unit (NO argument, NO %i instance -- same parameterless property as the apply
# unit). "rollback" always means "the one non-current payload-<version>
# directory under this install root" -- re-derived here from what is actually
# on disk, never handed a version by the caller. Refuses cleanly (exit 2) if
# there is not EXACTLY one such directory: zero means nothing to roll back to,
# more than one means this script cannot guess which is wanted.
#
# Exit codes (see docs/SELFUPDATE.md):
#   0 = rolled back, health check passed
#   2 = refused: no second payload-<version> directory exists on disk
#   3 = rollback swap/install.sh/restart failed -- the relay may be in a bad
#       state, needs a human
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import selfupdate as su  # noqa: E402  (see the sys.path.insert above)


def log(msg):
    print("[selfupdate-rollback] %s" % msg, flush=True)


def die(msg, code):
    print("[selfupdate-rollback] %s" % msg, file=sys.stderr, flush=True)
    sys.exit(code)


def main():
    root = su.install_root()
    if not root:
        die("could not determine this host's install path "
            "(%s missing or unreadable)" % su.INSTALL_CONF, 3)
    current = su.current_version()
    repo = os.environ.get("EDY_RDP_UPDATE_REPO", "").strip()

    ok, val = su.rollback_candidate(root)
    if not ok:
        die("no earlier version is available to roll back to on this host (%s)" % val, 2)
    target = su.version_from_payload_name(val) or val
    log("install root=%s current=%s -> rolling back to %s" % (root, current, target))

    swap_ok, swap_detail = su.swap_payload_and_install(root, val)
    log("payload swap: %s" % swap_detail)
    if not swap_ok:
        die("rollback failed: %s" % swap_detail, 3)

    su.daemon_reload()
    log("restarting %s" % su.RELAY_UNIT)
    restart_ok, restart_err = su.restart_relay()
    if not restart_ok:
        log("restart command failed: %s (still running the health check)" % restart_err)

    log("waiting up to %ss for the relay to report healthy" % su.HEALTH_TOTAL_TIMEOUT)
    healthy = su.wait_for_healthy()
    now = time.time()
    if healthy:
        log("rollback to %s succeeded and is healthy" % target)
        if repo:
            su.record_apply_result(repo, {"from": current, "to": target,
                                          "result": "ok",
                                          "detail": "manual rollback, healthy", "at": now})
        sys.exit(0)

    log("rollback to %s did NOT pass its health check -- this host needs a human" % target)
    if repo:
        su.record_apply_result(repo, {"from": current, "to": target,
                                      "result": "rollback_failed",
                                      "detail": "rolled back but the relay did not "
                                                "become healthy", "at": now})
    die("rollback restarted the relay but it did not become healthy", 3)


if __name__ == "__main__":
    main()
