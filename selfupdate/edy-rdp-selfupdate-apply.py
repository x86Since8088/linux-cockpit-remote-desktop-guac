#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
#
# edy-rdp-selfupdate-apply — fetch this project's latest tagged GitHub Release
# and deploy it, with AUTOMATIC rollback if the restarted relay fails its
# post-restart health check.
#
# Runs as ROOT, started through the edy-rdp-selfupdate-apply.service oneshot
# unit (NO argument, NO %i instance -- see the unit file for why that is a
# deliberate, stronger property than the %i-templated deskui/unlock units).
# The relay (edy-relay) is granted by polkit to start ONLY this exact unit name;
# everything this script does, it re-derives and re-validates ITSELF -- it
# trusts NOTHING about "which version" from any argument, environment variable
# the caller set, or file the unprivileged relay wrote. That is what makes the
# parameterless unit meaningful: even a compromised relay process can only ever
# trigger "apply whatever GitHub says is latest right now", never choose what
# gets installed.
#
# Exit codes (mirrors DesktopUI.control()'s ExecMainStatus idiom on the relay
# side -- see relay/selfupdate.py's SelfUpdate._map_apply_failure):
#   0 = applied, restarted, health check passed
#   2 = refused: nothing cached to apply / already on the latest version
#   3 = fetch/extract/deploy.sh invocation failed BEFORE anything on the host
#       was touched (the old payload is still live and was never touched)
#   4 = new version installed + relay restarted, health check FAILED, automatic
#       rollback SUCCEEDED (host is back on the old version and healthy)
#   5 = new version installed + relay restarted, health check FAILED, and the
#       rollback attempt ALSO failed -- worst case, a human is needed now
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import selfupdate as su  # noqa: E402  (see the sys.path.insert above)


def log(msg):
    print("[selfupdate-apply] %s" % msg, flush=True)


def die(msg, code):
    print("[selfupdate-apply] %s" % msg, file=sys.stderr, flush=True)
    sys.exit(code)


def main():
    root = su.install_root()
    if not root:
        die("could not determine this host's install path "
            "(%s missing or unreadable)" % su.INSTALL_CONF, 3)
    current = su.current_version()
    if not current:
        die("could not determine the currently installed version", 3)
    repo = os.environ.get("EDY_RDP_UPDATE_REPO", "").strip()
    if not repo:
        die("EDY_RDP_UPDATE_REPO is not set", 3)
    log("install root=%s current=%s repo=%s" % (root, current, repo))

    log("checking GitHub for the latest release (fresh call -- caches are never trusted here)")
    try:
        rel = su.check_latest_release(repo)
    except su.SelfUpdateError as exc:
        die("GitHub check failed: %s" % exc, 3)

    latest = rel["tag_name"]
    if not su.is_newer(current, latest):
        log("nothing to apply: current=%s latest=%s" % (current, latest))
        sys.exit(2)
    log("update available: %s -> %s" % (current, latest))

    prev_payload = su.current_payload_name(root)
    fetch_dir = tempfile.mkdtemp(prefix="edy-rdp-selfupdate-fetch-")
    log("fetching and extracting %s into %s" % (rel.get("tarball_url"), fetch_dir))
    try:
        extracted = su.fetch_and_extract_release(rel["tarball_url"], fetch_dir)
    except su.SelfUpdateError as exc:
        die("fetch/extract failed (nothing on this host was touched): %s" % exc, 3)

    deploy_sh = os.path.join(extracted, "deploy.sh")
    if not os.path.isfile(deploy_sh):
        die("fetched release tree has no deploy.sh at %s (nothing was touched)" % deploy_sh, 3)
    try:
        os.chmod(deploy_sh, 0o755)
    except OSError:
        pass

    # Deliberately NO --with-units/--with-deps/--with-image/--all: this is
    # exactly the "safe, just swap the payload" mode already used all session
    # (copy -> swap the `payload` symlink -> run the NEWLY-linked install.sh,
    # which places/reconciles .env). Reused by invoking it, not reimplemented.
    log("running the fetched deploy.sh --install-to %s (no --with-units)" % root)
    try:
        p = subprocess.run([deploy_sh, "--install-to", root], cwd=extracted,
                           timeout=180, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except (OSError, subprocess.TimeoutExpired) as exc:
        die("deploy.sh did not run (nothing was touched): %s" % exc, 3)

    log("deploy.sh output:\n" + p.stdout.decode("utf-8", "replace"))
    if p.returncode != 0:
        # deploy.sh's own do_deploy() copies the NEW payload and swaps the
        # `payload` symlink BEFORE running the newly-linked install.sh; a
        # failure inside install.sh (e.g. a bad .env) therefore CAN leave the
        # symlink pointed at a half-installed new payload even though nothing
        # was copied over the OLD one. Restore the old symlink so "nothing was
        # touched" is actually true, not just the exit code's framing.
        now_payload = su.current_payload_name(root)
        if prev_payload and now_payload and now_payload != prev_payload:
            log("deploy.sh failed after swapping the payload symlink; restoring "
                "payload -> %s" % prev_payload)
            ok, detail = su.swap_payload_and_install(root, prev_payload)
            log("restore %s: %s" % ("ok" if ok else "FAILED", detail))
        die("deploy.sh exited %d (see output above)" % p.returncode, 3)

    # deploy.sh renders unit files even without --with-units, but its OWN
    # explicit daemon-reload is gated behind --with-units, which this
    # invocation deliberately never passes (units are already enabled on a
    # real deployment; re-running the whole --with-units enable sequence here
    # would be wrong). install.sh's own unit-render branch already calls
    # daemon-reload for a deployed layout (verified in do_install()), so this
    # is normally a harmless repeat -- it runs anyway, unconditionally, so that
    # invariant is never load-bearing for THIS feature specifically.
    su.daemon_reload()

    log("restarting %s" % su.RELAY_UNIT)
    ok, err = su.restart_relay()
    if not ok:
        log("restart command itself failed: %s (still running the health check)" % err)

    log("waiting up to %ss for the relay to report healthy" % su.HEALTH_TOTAL_TIMEOUT)
    healthy = su.wait_for_healthy()
    now = time.time()
    if healthy:
        log("health check passed: now running %s" % latest)
        su.record_apply_result(repo, {"from": current, "to": latest,
                                      "result": "ok", "detail": "healthy", "at": now})
        sys.exit(0)

    log("health check FAILED for %s; rolling back to %s" % (latest, current))
    ok_rb, val = su.rollback_candidate(root)
    if not ok_rb:
        log("no rollback candidate found (%s) -- cannot recover automatically" % val)
        su.record_apply_result(repo, {"from": current, "to": latest,
                                      "result": "rollback_failed",
                                      "detail": "health check failed and no rollback "
                                                "candidate exists (%s)" % val, "at": now})
        sys.exit(5)

    swap_ok, swap_detail = su.swap_payload_and_install(root, val)
    su.daemon_reload()
    restart_ok, restart_err = su.restart_relay()
    if not restart_ok:
        log("rollback restart command failed: %s" % restart_err)
    rb_healthy = su.wait_for_healthy() if swap_ok else False

    if swap_ok and rb_healthy:
        log("automatic rollback to %s succeeded and is healthy" % current)
        su.record_apply_result(repo, {"from": current, "to": latest,
                                      "result": "rolled_back",
                                      "detail": "update failed health check; rolled "
                                                "back to %s" % current, "at": now})
        sys.exit(4)

    log("automatic rollback FAILED: %s" % swap_detail)
    su.record_apply_result(repo, {"from": current, "to": latest,
                                  "result": "rollback_failed",
                                  "detail": "update failed health check AND the "
                                            "automatic rollback also failed: %s"
                                            % swap_detail, "at": now})
    sys.exit(5)


if __name__ == "__main__":
    main()
