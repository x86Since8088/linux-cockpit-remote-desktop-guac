#!/usr/bin/env node
// Unit tests for the focus-loss key-release wiring in ../../guac-rdp.js.
//
// Live-reported bug: a held modifier (classically Alt, via Alt+Tab) "sticks"
// -- the guest OS keeps believing it is held for the ENTIRE time the session
// is unfocused (any mouse click/drag/scroll during that window arrives at the
// guest as an Alt-combo), not just the operator's very next keystroke on
// return. Root cause: the browser only delivers `keyup` to whatever element
// currently holds DOM focus, and losing focus never synthesizes one.
// Guacamole.Keyboard DOES self-correct stale modifier state by comparing its
// own tracked state against the browser's live event.altKey/etc flags, but
// only reactively, on the NEXT keyboard event it sees -- so the guest sees
// that correction (Alt released, THEN the new key) only once the operator
// starts typing again, not for anything that happened while away. The fix
// calls keyboard.reset() (a real Guacamole.Keyboard API that fires a genuine
// onkeyup for every keysym it still believes is pressed) the moment focus is
// lost, instead of waiting for that reactive correction.
//
// Known, accepted trade-off (found by adversarial review, not fixed): a
// modifier held THROUGH a focus round-trip without ever being physically
// released (e.g. holding Ctrl, clicking a different in-page tab, then typing
// Ctrl+C while still holding Ctrl) gets spuriously released by this same
// reset() call, since the browser never re-fires a keydown for a key that was
// never actually released -- the next physical press of that same modifier
// key restores it. Releasing a key that is still genuinely held is far safer
// than the original bug (a key stuck down for an unbounded time, silently
// modifying everything until something coincidentally corrects it), so this
// is accepted rather than "fixed" -- reviewed and rejected: also resetting
// Guacamole.Keyboard's own modifier-flag state does not reliably help and
// re-introduces exactly the "trust a possibly-stale browser flag" problem
// this whole feature exists to correct for.
//
// Two blocks are extracted VERBATIM (between the TESTHOOK:KEYBLUR and
// TESTHOOK:KEYBLUR_TEARDOWN sentinels) and run standalone via `vm`, so this
// tests the actual shipped wiring -- both the connect()-time setup and the
// teardown()-time cleanup -- not a reimplementation of either.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(
    path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');

function extract(beginSentinel, endSentinel) {
    const b = SRC.indexOf(beginSentinel);
    const e = SRC.indexOf(endSentinel);
    assert.ok(b !== -1 && e !== -1 && e > b,
        'guac-rdp.js ' + beginSentinel + ' sentinels not found -- did the ' +
        'block move or get renamed? Update this test to match.');
    return SRC.slice(b, e);
}

const block = extract('// TESTHOOK:KEYBLUR:BEGIN', '// TESTHOOK:KEYBLUR:END');
const teardownBlock = extract('// TESTHOOK:KEYBLUR_TEARDOWN:BEGIN', '// TESTHOOK:KEYBLUR_TEARDOWN:END');

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

    // All three event sources, not just box: a leaked handler on window or
    // document would double-fire reset() (adversarial review found the
    // original version of this test only dispatched box blur, so a leak on
    // EITHER of the other two survived undetected -- both are now checked).
    // Note what actually leaks, precisely: keyboardBlurHandler closes over the
    // OUTER `keyboard` variable, not a snapshot of it, so a leaked handler
    // calls reset() on the CURRENT keyboard (keyboard2) same as the correctly-
    // registered one -- it does NOT operate on a stale/torn-down keyboard
    // object. The observable harm of a leak is a redundant, idempotent second
    // reset() and a duplicate trace line per event, not incorrect targeting.
    box.dispatchEvent(new Event('blur'));
    assert.deepStrictEqual(calls, ['keyboard2'], 'box blur must fire the CURRENT handler exactly once');
    win.dispatchEvent(new Event('blur'));
    assert.deepStrictEqual(calls, ['keyboard2', 'keyboard2'], 'window blur must fire exactly once, not leak from the first connect');
    doc.dispatchEvent(new Event('visibilitychange'));
    assert.deepStrictEqual(calls, ['keyboard2', 'keyboard2', 'keyboard2'], 'visibilitychange must fire exactly once, not leak from the first connect');
});

// --- teardown()'s own cleanup (TESTHOOK:KEYBLUR_TEARDOWN) -------------------
// A real Disconnect (or an error/tunnel-close path) must remove all three
// listeners AND null keyboardBlurHandler -- otherwise a later connect() in
// the SAME page sees a truthy keyboardBlurHandler left over from a session
// that already tore down, and (per the block above) removes ITS OWN listener
// registration for a handler that was never actually attached this time,
// leaving the truly-stale one from teardown still firing.

test('teardown() removes the listener from the display element, window, and document', () => {
    const box = new FakeEventTarget();
    const win = new FakeEventTarget();
    const doc = new FakeEventTarget();
    const calls = [];
    const handler = () => calls.push('fired');
    box.addEventListener('blur', handler, true);
    win.addEventListener('blur', handler);
    doc.addEventListener('visibilitychange', handler);

    const ctx = vm.createContext({ lockBox: box, window: win, document: doc, keyboardBlurHandler: handler });
    vm.runInContext(teardownBlock, ctx);

    box.dispatchEvent(new Event('blur'));
    win.dispatchEvent(new Event('blur'));
    doc.dispatchEvent(new Event('visibilitychange'));
    assert.deepStrictEqual(calls, [], 'none of the three must still fire after teardown');
    assert.strictEqual(ctx.keyboardBlurHandler, null, 'keyboardBlurHandler must be nulled so a later connect() never sees a stale truthy value');
});

test('teardown() with no lockBox (display element already gone) still clears window/document and does not throw', () => {
    const win = new FakeEventTarget();
    const doc = new FakeEventTarget();
    const calls = [];
    const handler = () => calls.push('fired');
    win.addEventListener('blur', handler);
    doc.addEventListener('visibilitychange', handler);

    const ctx = vm.createContext({ lockBox: null, window: win, document: doc, keyboardBlurHandler: handler });
    assert.doesNotThrow(() => vm.runInContext(teardownBlock, ctx));

    win.dispatchEvent(new Event('blur'));
    doc.dispatchEvent(new Event('visibilitychange'));
    assert.deepStrictEqual(calls, []);
});

test('teardown() with no handler ever registered is a safe no-op', () => {
    const ctx = vm.createContext({ lockBox: null, window: new FakeEventTarget(), document: new FakeEventTarget(), keyboardBlurHandler: null });
    assert.doesNotThrow(() => vm.runInContext(teardownBlock, ctx));
    assert.strictEqual(ctx.keyboardBlurHandler, null);
});

test('reconnecting after a real teardown never leaves a stale handler firing', () => {
    // The scenario the two blocks together exist to prevent: connect, fully
    // disconnect (teardown), connect again -- box/window/document persist
    // across all of it in the real page.
    const box = new FakeEventTarget();
    const win = new FakeEventTarget();
    const doc = new FakeEventTarget();
    const calls = [];
    const keyboard1 = { reset() { calls.push('keyboard1'); } };
    const setupCtx = vm.createContext({
        box, window: win, document: doc,
        keyboard: keyboard1, keyboardBlurHandler: null,
        resetShiftAdjust() {}, trace() {},
    });
    vm.runInContext(block, setupCtx);          // connect #1

    const teardownCtx = vm.createContext({ lockBox: box, window: win, document: doc, keyboardBlurHandler: setupCtx.keyboardBlurHandler });
    vm.runInContext(teardownBlock, teardownCtx);   // teardown #1

    const keyboard2 = { reset() { calls.push('keyboard2'); } };
    const reconnectCtx = vm.createContext({
        box, window: win, document: doc,
        keyboard: keyboard2, keyboardBlurHandler: teardownCtx.keyboardBlurHandler,   // null, correctly
        resetShiftAdjust() {}, trace() {},
    });
    vm.runInContext(block, reconnectCtx);      // connect #2

    box.dispatchEvent(new Event('blur'));
    assert.deepStrictEqual(calls, ['keyboard2'],
        'only connect #2\'s keyboard may be reset -- a stale connect #1 handler surviving ' +
        'the teardown in between would fire here too');
});
