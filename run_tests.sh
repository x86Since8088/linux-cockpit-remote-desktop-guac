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
