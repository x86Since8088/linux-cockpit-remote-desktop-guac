#!/usr/bin/env node
// Two page-side security decisions, extracted from guac-rdp.js between the
// TESTHOOK:SECDECIDE sentinels:
//   * consoleShouldFallBackToGreeter: the I48 greeter failover may redirect only
//     on a POSITIVE count of exactly 0, never on "unknown".
//   * connectNeedsAdminProof: Remote VNC must ask for administrator proof just
//     like Remote RDP, because the relay demands it for both when
//     EDY_RDP_REMOTE_ADMIN_ONLY=1.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');
const BEGIN = '// TESTHOOK:SECDECIDE:BEGIN';
const END = '// TESTHOOK:SECDECIDE:END';
const b = SRC.indexOf(BEGIN), e = SRC.indexOf(END);
assert.ok(b !== -1 && e > b, 'guac-rdp.js TESTHOOK:SECDECIDE sentinels not found');
const ctx = vm.createContext({});
vm.runInContext(SRC.slice(b, e), ctx);

test('console falls back to the greeter only when the count is exactly 0', () => {
    assert.strictEqual(ctx.consoleShouldFallBackToGreeter({ ok: true, active_graphical_sessions: 0 }), true);
    assert.strictEqual(ctx.consoleShouldFallBackToGreeter({ ok: true, active_graphical_sessions: 1 }), false);
});

test('an unknown count (null, missing, failed probe) never redirects to the greeter', () => {
    assert.strictEqual(ctx.consoleShouldFallBackToGreeter({ ok: true, active_graphical_sessions: null }), false);
    assert.strictEqual(ctx.consoleShouldFallBackToGreeter({ ok: true }), false);
    assert.strictEqual(ctx.consoleShouldFallBackToGreeter({ ok: false, active_graphical_sessions: 0 }), false);
    assert.strictEqual(ctx.consoleShouldFallBackToGreeter(null), false);
});

test('the page wires both decisions in (not just defines them)', () => {
    assert.ok(/if \(!consoleShouldFallBackToGreeter\(r\)\) return key;/.test(SRC));
    assert.ok(/var needAdmin = connectNeedsAdminProof\(t, key, isAdmin\);/.test(SRC));
});

test('admin proof is requested for remote AND vnc when the session is elevated', () => {
    assert.strictEqual(ctx.connectNeedsAdminProof({}, 'remote', true), true);
    assert.strictEqual(ctx.connectNeedsAdminProof({}, 'vnc', true), true);
});

test('admin proof is not requested for vnc/remote when not elevated, nor for ordinary targets', () => {
    assert.strictEqual(ctx.connectNeedsAdminProof({}, 'vnc', false), false);
    assert.strictEqual(ctx.connectNeedsAdminProof({}, 'remote', false), false);
    assert.strictEqual(ctx.connectNeedsAdminProof({}, 'virtual', true), false);
});

test('admin-only targets always need proof', () => {
    assert.strictEqual(ctx.connectNeedsAdminProof({ admin: true }, 'console', false), true);
});
