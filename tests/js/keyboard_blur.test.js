#!/usr/bin/env node
// Unit tests for the focus-loss key-release wiring in ../../guac-rdp.js.
//
// Live-reported bug: a held modifier (classically Alt, via Alt+Tab) "sticks"
// -- the guest OS keeps believing it is held, and the operator's next
// keystroke on returning gets misread as a modifier combo. Root cause: the
// browser only delivers `keyup` to whatever element currently holds DOM
// focus, and losing focus never synthesizes one. Guacamole.Keyboard DOES
// self-correct stale modifier state, but only reactively, on the NEXT
// keyboard event it sees -- by then the guest may already have misread that
// very keystroke. The fix calls keyboard.reset() (a real Guacamole.Keyboard
// API that fires a genuine onkeyup for every keysym it still believes is
// pressed) the moment focus is lost, instead of waiting for the next
// keystroke to self-correct.
//
// The wiring block is extracted VERBATIM (between the TESTHOOK:KEYBLUR
// sentinels) and run standalone via `vm`, so this tests the actual shipped
// code, not a reimplementation.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(
    path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');

const BEGIN = '// TESTHOOK:KEYBLUR:BEGIN';
const END = '// TESTHOOK:KEYBLUR:END';
const beginIdx = SRC.indexOf(BEGIN);
const endIdx = SRC.indexOf(END);
assert.ok(beginIdx !== -1 && endIdx !== -1 && endIdx > beginIdx,
    'guac-rdp.js TESTHOOK:KEYBLUR sentinels not found -- did the focus-loss ' +
    'key-release block move or get renamed? Update this test to match.');
const block = SRC.slice(beginIdx, endIdx);

// Node's own built-in EventTarget does NOT correctly match a bare boolean
// `capture` argument between addEventListener/removeEventListener (verified:
// it fires a "removed" listener anyway) -- a real Node quirk/deviation from
// the DOM spec, not present in an actual browser (confirmed separately
// against jsdom, which -- like real browsers -- treats a bare boolean the
// same as {capture: bool}). This project's own existing code already relies
// on that spec-correct boolean-capture matching elsewhere (e.g. the display
// element's own mousedown/keydown listeners), so this minimal, spec-correct
// stand-in is used here instead of Node's own EventTarget, to test what a
// real browser actually does without adding jsdom as a permanent dependency
// of this repo's dependency-free test suite.
function normCapture(opts) {
    return typeof opts === 'boolean' ? opts : !!(opts && opts.capture);
}
class FakeEventTarget {
    constructor() { this._listeners = new Map(); }
    addEventListener(type, fn, opts) {
        const capture = normCapture(opts);
        if (!this._listeners.has(type)) this._listeners.set(type, []);
        const list = this._listeners.get(type);
        if (!list.some((l) => l.fn === fn && l.capture === capture))
            list.push({ fn, capture });
    }
    removeEventListener(type, fn, opts) {
        const capture = normCapture(opts);
        const list = this._listeners.get(type);
        if (!list) return;
        this._listeners.set(type, list.filter((l) => !(l.fn === fn && l.capture === capture)));
    }
    dispatchEvent(evt) {
        (this._listeners.get(evt.type) || []).slice().forEach((l) => l.fn(evt));
    }
}

function makeSandbox() {
    const box = new FakeEventTarget();
    const win = new FakeEventTarget();
    const doc = new FakeEventTarget();
    const resetCalls = [];
    const traceCalls = [];
    const keyboard = { reset() { resetCalls.push(true); } };
    const ctx = vm.createContext({
        box, window: win, document: doc,
        keyboard, keyboardBlurHandler: null,
        resetShiftAdjust() { resetCalls.push('shiftAdjust'); },
        trace(cat, msg) { traceCalls.push([cat, msg]); },
    });
    vm.runInContext(block, ctx);
    return { ctx, box, win, doc, keyboard, resetCalls, traceCalls };
}

test('blur on the display element releases held keys', () => {
    const s = makeSandbox();
    s.box.dispatchEvent(new Event('blur'));
    assert.deepStrictEqual(s.resetCalls, [true, 'shiftAdjust'],
        'keyboard.reset() must run before resetShiftAdjust()');
});

test('window blur (the Alt+Tab case -- this element never blurs) releases held keys', () => {
    const s = makeSandbox();
    s.win.dispatchEvent(new Event('blur'));
    assert.deepStrictEqual(s.resetCalls, [true, 'shiftAdjust']);
});

test('visibilitychange (tab backgrounded, which does not always blur) releases held keys', () => {
    const s = makeSandbox();
    s.doc.dispatchEvent(new Event('visibilitychange'));
    assert.deepStrictEqual(s.resetCalls, [true, 'shiftAdjust']);
});

test('no client/keyboard yet -- must not throw and must not call reset', () => {
    const s = makeSandbox();
    s.ctx.keyboard = null;
    assert.doesNotThrow(() => s.box.dispatchEvent(new Event('blur')));
    assert.deepStrictEqual(s.resetCalls, []);
});

test('a real blur genuinely emits a trace line naming the reason (opt-in tracing)', () => {
    const s = makeSandbox();
    s.box.dispatchEvent(new Event('blur'));
    assert.strictEqual(s.traceCalls.length, 1);
    assert.strictEqual(s.traceCalls[0][0], 'keyboard');
    assert.match(s.traceCalls[0][1], /focus lost/);
});

test('reconnecting (the block running a second time) removes the OLD listeners -- no double-fire, no stale handler', () => {
    const box = new FakeEventTarget();
    const win = new FakeEventTarget();
    const doc = new FakeEventTarget();
    const calls = [];
    // First "connect": keyboard1's reset must fire.
    const keyboard1 = { reset() { calls.push('keyboard1'); } };
    const ctx = vm.createContext({
        box, window: win, document: doc,
        keyboard: keyboard1, keyboardBlurHandler: null,
        resetShiftAdjust() {}, trace() {},
    });
    vm.runInContext(block, ctx);

    // Second "connect" (e.g. Disconnect then Connect again in the same page):
    // a fresh keyboard object, same box/window/document (they persist across
    // reconnects in the real page) -- re-running the block must remove the
    // FIRST handler before adding the new one.
    const keyboard2 = { reset() { calls.push('keyboard2'); } };
    ctx.keyboard = keyboard2;
    vm.runInContext(block, ctx);

    box.dispatchEvent(new Event('blur'));
    assert.deepStrictEqual(calls, ['keyboard2'],
        'only the CURRENT session\'s keyboard must be reset -- a leaked first-session ' +
        'handler firing here would call reset() on a stale keyboard object, or fire twice');
});
