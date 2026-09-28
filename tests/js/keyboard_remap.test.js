#!/usr/bin/env node
// Unit tests for the keysym fix-up block in ../../guac-rdp.js (I45: parenleft/
// parenright/less need a keycode substitution; every digit/punctuation keysym
// needs its Shift state corrected to match the Xvfb "us" keymap regardless of
// what modifier the CLIENT's layout used to produce it). The block is
// extracted VERBATIM (between the TESTHOOK:KEYREMAP sentinels) and run
// standalone via `vm`, so this tests the actual shipped code, not a
// reimplementation.
//
// Covers both directions of the bug: a client holding Shift for a keysym the
// Xvfb keymap needs unshifted (e.g. French AZERTY digits, German ".") and a
// client NOT holding Shift for one the Xvfb keymap needs shifted (e.g. French
// AZERTY "(", German "|" via AltGr) -- see I45 / guac-rdp.js for the full
// reasoning, and docs/KNOWN_ISSUES.md.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(
    path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');

const BEGIN = '// TESTHOOK:KEYREMAP:BEGIN';
const END = '// TESTHOOK:KEYREMAP:END';
const beginIdx = SRC.indexOf(BEGIN);
const endIdx = SRC.indexOf(END);
assert.ok(beginIdx !== -1 && endIdx !== -1 && endIdx > beginIdx,
    'guac-rdp.js TESTHOOK:KEYREMAP sentinels not found -- did the keyboard ' +
    'remap block move or get renamed? Update this test to match.');
const block = SRC.slice(beginIdx, endIdx);

const SHIFT_L = 0xFFE1, SHIFT_R = 0xFFE2;

// Builds a fresh sandbox: a fake `client` recording every sendKeyEvent call,
// a fake `keyboard.pressed` map the test controls directly (standing in for
// Guacamole.Keyboard's real, DOM-event-driven modifier bookkeeping), and a
// `navigator` stub. Returns helpers to drive it.
function makeSandbox(opts) {
    opts = opts || {};
    const calls = [];
    const client = { sendKeyEvent(down, ks) { calls.push([down, ks]); } };
    const pressed = {};
    const keyboard = { pressed };
    const navigator = { platform: opts.platform || '', userAgent: opts.userAgent || '' };
    const ctx = vm.createContext({ client, keyboard, navigator });
    vm.runInContext(block, ctx);
    return {
        ctx, calls,
        setShift(down) { pressed[SHIFT_L] = !!down; },
        dropClient() { ctx.client = null; },
    };
}

// Keysyms that need a keycode substitution AND happen to need Shift at their
// target: parenleft->9, parenright->0, less->comma. (greater and bar resolve
// to an unambiguous keycode already and need no substitution -- only a Shift
// state fix, tested separately below.)
const SUBSTITUTED_SHIFTED = [[0x28, 0x39], [0x29, 0x30], [0x3c, 0x2c]];

test('US shape: real Shift already held for a key that needs it -> no adjustment', () => {
    for (const [ks, target] of SUBSTITUTED_SHIFTED.concat([[0x3e, 0x3e], [0x7c, 0x7c]])) {
        const s = makeSandbox();
        s.setShift(true);
        s.ctx.sendGuestKeyEvent(true, ks);
        assert.deepStrictEqual(s.calls, [[1, target]], `keydown 0x${ks.toString(16)}`);
        s.ctx.sendGuestKeyEvent(false, ks);
        assert.deepStrictEqual(s.calls, [[1, target], [0, target]],
            `keyup 0x${ks.toString(16)} must not touch Shift -- it was already real`);
    }
});

test('international shape: no real Shift for a key that needs it -> synthetic Shift added and released', () => {
    for (const [ks, target] of SUBSTITUTED_SHIFTED.concat([[0x3e, 0x3e], [0x7c, 0x7c]])) {
        const s = makeSandbox();
        // e.g. French AZERTY's unshifted "(", or "|" reached via AltGr (not Shift).
        s.ctx.sendGuestKeyEvent(true, ks);
        assert.deepStrictEqual(s.calls, [[1, SHIFT_L], [1, target]],
            `keydown 0x${ks.toString(16)} must inject a synthetic Shift first`);
        s.ctx.sendGuestKeyEvent(false, ks);
        assert.deepStrictEqual(
            s.calls, [[1, SHIFT_L], [1, target], [0, target], [0, SHIFT_L]],
            `keyup 0x${ks.toString(16)} must release exactly the Shift it added`);
    }
});

test('mirror-image (I45 follow-up): real Shift held for a key that needs NONE -> Shift suppressed and restored', () => {
    // e.g. French AZERTY holds Shift to type digits; German holds Shift for ".".
    // Xvfb's "us" keymap needs digits/period UNSHIFTED -- trusting the client's
    // real Shift would deliver the shifted symbol instead ("!" for "1", ">" for
    // ".", etc.), the exact mirror of the reported "<" -> ">" bug.
    for (const ks of [0x31, 0x2e, 0x2c, 0x3b]) {   // '1', period, comma, semicolon
        const s = makeSandbox();
        s.setShift(true);
        s.ctx.sendGuestKeyEvent(true, ks);
        assert.deepStrictEqual(s.calls, [[0, SHIFT_L], [1, ks]],
            `keydown 0x${ks.toString(16)} must suppress the client's real Shift`);
        s.ctx.sendGuestKeyEvent(false, ks);
        assert.deepStrictEqual(s.calls, [[0, SHIFT_L], [1, ks], [0, ks], [1, SHIFT_L]],
            `keyup 0x${ks.toString(16)} must restore Shift since the user is still holding it`);
    }
});

test('mirror-image: Shift released by the user before the suppressed key is released -> not restored', () => {
    const s = makeSandbox();
    s.setShift(true);
    s.ctx.sendGuestKeyEvent(true, 0x31);              // '1' on AZERTY: Shift held, needs suppressing
    assert.deepStrictEqual(s.calls, [[0, SHIFT_L], [1, 0x31]]);
    s.setShift(false);                                 // user releases the real Shift key first
    s.ctx.sendGuestKeyEvent(false, 0x31);
    assert.deepStrictEqual(s.calls, [[0, SHIFT_L], [1, 0x31], [0, 0x31]],
        'must not restore Shift the user no longer wants held');
});

test('overlapping presses (reviewer-identified desync): a real Shift pressed WHILE an added synthetic Shift is still active must not be killed on keyup', () => {
    // German-style: "<" (no real Shift, gets a synthetic Shift added) held while
    // the user starts pressing real Shift for an upcoming ">", THEN releases "<".
    const s = makeSandbox();
    s.ctx.sendGuestKeyEvent(true, 0x3c);              // less -> comma, synthetic Shift added
    assert.deepStrictEqual(s.calls, [[1, SHIFT_L], [1, 0x2c]]);
    s.setShift(true);                                  // real Shift now genuinely down (for the next key)
    s.ctx.sendGuestKeyEvent(false, 0x3c);             // finally release "<"
    assert.deepStrictEqual(s.calls, [[1, SHIFT_L], [1, 0x2c], [0, 0x2c]],
        'must NOT emit a Shift release here -- the user is now genuinely holding Shift');
});

test('key-repeat only applies the Shift adjustment once per press', () => {
    const s = makeSandbox();
    s.ctx.sendGuestKeyEvent(true, 0x3c);   // less, first keydown (no real shift)
    s.ctx.sendGuestKeyEvent(true, 0x3c);   // OS auto-repeat
    s.ctx.sendGuestKeyEvent(true, 0x3c);
    assert.deepStrictEqual(s.calls, [
        [1, SHIFT_L], [1, 0x2c],
        [1, 0x2c],
        [1, 0x2c],
    ]);
    s.ctx.sendGuestKeyEvent(false, 0x3c);
    assert.deepStrictEqual(s.calls.slice(-2), [[0, 0x2c], [0, SHIFT_L]]);
});

test('client going null mid-press does not throw and drops the pending adjustment', () => {
    const s = makeSandbox();
    s.ctx.sendGuestKeyEvent(true, 0x3c);
    assert.deepStrictEqual(s.calls, [[1, SHIFT_L], [1, 0x2c]]);
    s.dropClient();
    assert.doesNotThrow(() => s.ctx.sendGuestKeyEvent(false, 0x3c));
    assert.strictEqual(s.calls.length, 2);
    // resetShiftAdjust (called from teardown()) must clear the leaked entry so
    // a later session reusing this page instance doesn't inherit stale state.
    s.ctx.resetShiftAdjust();
    const client2 = { sendKeyEvent(down, ks) { s.calls.push([down, ks]); } };
    s.ctx.client = client2;
    s.ctx.sendGuestKeyEvent(true, 0x3c);
    assert.deepStrictEqual(s.calls.slice(-2), [[1, SHIFT_L], [1, 0x2c]],
        'a fresh press after reset must decide again, not reuse a stale flag');
});

test('passthrough keysyms (letters, Meta, unmanaged punctuation) go through remapKeysym unchanged', () => {
    const s = makeSandbox();
    s.ctx.sendGuestKeyEvent(true, 0xFFE7);   // Meta_L -> Super_L
    s.ctx.sendGuestKeyEvent(false, 0xFFE7);
    assert.deepStrictEqual(s.calls, [[1, 0xFFEB], [0, 0xFFEB]]);

    const s2 = makeSandbox();
    s2.ctx.sendGuestKeyEvent(true, 0x61);    // 'a': letters are Shift-invariant everywhere, untouched
    assert.deepStrictEqual(s2.calls, [[1, 0x61]]);
});

test('Mac Option (ISO_Level3_Shift) remaps to Alt_L only when navigator looks like a Mac', () => {
    const mac = makeSandbox({ platform: 'MacIntel' });
    mac.ctx.sendGuestKeyEvent(true, 0xFE03);
    assert.deepStrictEqual(mac.calls, [[1, 0xFFE9]]);

    const other = makeSandbox({ platform: 'Linux x86_64' });
    other.ctx.sendGuestKeyEvent(true, 0xFE03);
    assert.deepStrictEqual(other.calls, [[1, 0xFE03]],
        'non-Mac AltGr (ISO_Level3_Shift) must pass through unchanged');
});

test('KEYCODE_FIX and SHIFT_LEVEL match what was verified against the real Xvfb keymap', () => {
    const s = makeSandbox();
    assert.deepStrictEqual(Object.assign({}, s.ctx.KEYCODE_FIX), {
        0x28: 0x39, 0x29: 0x30, 0x3c: 0x2c,
    });
    const shiftLevel = Object.assign({}, s.ctx.SHIFT_LEVEL);
    // Spot-check the characters this bug and the review actually turned up;
    // the full table is generated from the keymap dump in the PR description.
    assert.strictEqual(shiftLevel[0x3e], true, 'greater needs Shift (AB09 level 1)');
    assert.strictEqual(shiftLevel[0x7c], true, 'bar needs Shift (BKSL level 1)');
    assert.strictEqual(shiftLevel[0x2c], false, 'comma is unshifted (AB08 level 0)');
    assert.strictEqual(shiftLevel[0x2e], false, 'period is unshifted (AB09 level 0)');
    for (let d = 0x30; d <= 0x39; d++) {
        assert.strictEqual(shiftLevel[d], false, `digit 0x${d.toString(16)} is unshifted on the Xvfb "us" keymap`);
    }
    // Letters must not appear in the table at all -- they're handled by passthrough.
    assert.strictEqual(shiftLevel[0x61], undefined, "'a' must not be in SHIFT_LEVEL");
    assert.strictEqual(shiftLevel[0x41], undefined, "'A' must not be in SHIFT_LEVEL");
});
