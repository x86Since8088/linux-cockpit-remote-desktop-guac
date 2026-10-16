#!/usr/bin/env node
// A greeter connection that drops on its own is followed once onto the
// desktop the user just signed into. Disconnect, an explained error, and a
// second drop do not start another connection.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(
    path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');

const BEGIN = '// TESTHOOK:GREETERFOLLOW:BEGIN';
const END = '// TESTHOOK:GREETERFOLLOW:END';
const beginIdx = SRC.indexOf(BEGIN);
const endIdx = SRC.indexOf(END);
assert.ok(beginIdx !== -1 && endIdx !== -1 && endIdx > beginIdx,
    'guac-rdp.js TESTHOOK:GREETERFOLLOW sentinels not found');
const block = SRC.slice(beginIdx, endIdx);

function decide(scenario, errored, armed, follows) {
    const ctx = vm.createContext({});
    vm.runInContext(block, ctx);
    return ctx.shouldFollowGreeterDrop(scenario, errored, armed, follows);
}

test('an unexpected greeter drop is followed once', () => {
    assert.strictEqual(decide('greeter', false, true, 0), true);
});

test('a console, virtual, or remote drop is left alone', () => {
    assert.strictEqual(decide('console', false, true, 0), false);
    assert.strictEqual(decide('virtual', false, true, 0), false);
    assert.strictEqual(decide('remote', false, true, 0), false);
});

test('Disconnect disarms the follow', () => {
    assert.strictEqual(decide('greeter', false, false, 0), false);
});

test('an explained error does not follow', () => {
    assert.strictEqual(decide('greeter', true, true, 0), false);
});

test('a second drop before the new connection is stable does not loop', () => {
    assert.strictEqual(decide('greeter', false, true, 1), false);
});
