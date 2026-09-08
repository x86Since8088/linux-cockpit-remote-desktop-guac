#!/usr/bin/env bash
# run_tests.sh - phase-4 custom_validator for cockpit-guac-rdp.
# Non-zero exit fails the orchestrator's Test Execution phase. Runs where the
# repo sits; the Playwright portion is skipped (with a clear notice) if Cockpit
# or the test deps are unavailable, but the security/unit checks always run.
set -Eeuo pipefail
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail=0

echo "== py_compile relay =="
python3 -m py_compile "$SRC"/relay/*.py && echo "  ok" || { echo "  FAIL"; fail=1; }

echo "== relay unit tests (isolation, console gate, session tokens, allow-list, keepalive codec, registry, reaper) =="
( cd "$SRC/relay" && python3 -m unittest test_edy_rdp_relay test_session_registry test_control ) \
  || { echo "  FAIL"; fail=1; }

echo "== JS syntax (gjs if present) =="
if command -v gjs >/dev/null 2>&1; then
  for f in "$SRC"/*.js; do
    gjs -c "new Function(String.raw\`$(cat "$f")\`); print('ok');" >/dev/null 2>&1 \
      || echo "  note: $f did not load standalone (DOM code is covered by Playwright)"
  done
  echo "  checked"
else
  echo "  gjs not present; skipping standalone JS check"
fi

echo "== INVARIANT: guacd :4822 must be LOOPBACK-only (host-loopback + nft owner-gate design) =="
# guacd intentionally binds 127.0.0.1:4822 and is protected by the nftables owner-match,
# NOT by netns isolation. The regression to guard is a NON-loopback bind (0.0.0.0 / a LAN IP).
if ss -tln 2>/dev/null | awk '$4 ~ /:4822$/' | grep -vqE '(127\.0\.0\.1|\[::1\]):4822'; then
  echo "  FAIL: :4822 bound to a non-loopback address — I1/I7 violated"
  ss -tln 2>/dev/null | awk '$4 ~ /:4822$/{print "    "$0}'; fail=1
else
  echo "  ok: :4822 is loopback-only (or not up in this context)"
fi

echo "== DEPLOY-CONTRACT standing greps (section 4.4) =="
# Each must print nothing. These are cheap and they are the checks that catch a
# payload quietly growing a path back into a checkout.
g=0
# 1. no shipped file names a source .env
if grep -RIn --exclude-dir=.git -e 'source/\.env' -e '"\.env"' -e "'\.env'" \
     -- relay/ bridge/ headless/ rotate/ ./*.js ./*.sh 2>/dev/null; then
  echo "  FAIL a shipped file names a source .env"; g=1; fi
# 2. nothing resolves .env relative to itself
if grep -RIn --exclude-dir=.git \
     -e 'dirname.*\.env' -e '__file__.*\.env' -e 'BASH_SOURCE.*\.env' \
     -- relay/ bridge/ headless/ rotate/ 2>/dev/null; then
  echo "  FAIL something resolves .env relative to itself"; g=1; fi
# The one true DEV location, and the RETIRED checkout-under-/opt this contract
# exists because of - assembled from named parts so that NEITHER appears as a
# literal anywhere in this file, including in this comment.
#
# These scripts ship into the payload. An audit whose own text matches its
# pattern is an audit with a permanent known exception, and an audit with a
# permanent known exception is one nobody runs a second time. So a recursive
# grep of a deployed tree for either root must come back completely empty,
# and the two lines below are what pay for that.
_ao=ai-orchestrator; _retired=git
DEV_ROOT="/srv/smb/share/sc/${_ao}-group/${_ao}-storage/projects"
RETIRED_ROOT="/opt/sc/${_retired}"
if grep -RIn --exclude-dir=.git -e "$DEV_ROOT" -e "$RETIRED_ROOT" \
     -- ./*.js ./*.json ./*.html .envdefault systemd/ hardening/ relay/ bridge/ \
        headless/ rotate/ 2>/dev/null; then
  echo "  FAIL a shipped file hardcodes a development or retired root"; g=1; fi
# every unit template renders with no placeholder left over
for u in systemd/*.in; do
  [ -e "$u" ] || continue
  if sed -e 's|@PAYLOAD@|/x|g' -e 's|@INSTALL_PATH@|/x|g' -e 's|@ENV_FILE@|/x/.env|g' \
         -e 's|@LIBEXEC@|/usr/libexec/edy-rdp|g' -e 's|@SBIN@|/usr/local/sbin|g' "$u" \
     | grep -q '@[A-Z_]\+@'; then
    echo "  FAIL $u has a placeholder no renderer substitutes"; g=1; fi
done
# install.sh's own pre-flight, which IS the completeness gate. Only the
# pre-flight half gates the tests: the "installed state" half describes the host
# this happens to run on, and a source tree is not wrong because a machine has
# not been deployed to yet. A FATAL means the gate refused the SOURCE.
gate_out="$(./install.sh --verify 2>&1 || true)"
if printf '%s\n' "$gate_out" | grep -q '^FATAL'; then
  printf '%s\n' "$gate_out" | grep -A2 '^FATAL' | sed 's/^/    /'
  echo "  FAIL install.sh's pre-flight refuses this source tree"; g=1
fi
if ((g)); then echo "  FAIL"; fail=1; else echo "  ok"; fi

echo "== Playwright end-to-end (external harness, if present) =="
# The browser suite lives in the working-tree harness cockpit-e2e/ (outside this
# repo, since it needs a live Cockpit + a throwaway test user). Point E2E_DIR at it
# to run it here; otherwise it is skipped (the security/unit checks above still gate).
E2E_DIR="${E2E_DIR:-$SRC/../../cockpit-e2e}"
if [[ -d "$E2E_DIR/node_modules" ]] && command -v npx >/dev/null 2>&1; then
  ( cd "$E2E_DIR" && npx playwright test --reporter=line ) || { echo "  FAIL"; fail=1; }
else
  echo "  SKIP: no Playwright harness at \$E2E_DIR ($E2E_DIR)"
  echo "        (run manually: cd <cockpit-e2e> && npx playwright test)"
fi

if ((fail)); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
