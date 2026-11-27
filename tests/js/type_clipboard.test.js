#!/usr/bin/env node
// Unit tests for the "Type Clipboard" keystroke-injection helpers in
// ../../guac-rdp.js -- a workaround for the confirmed upstream guacd/x11vnc bug
// that silently drops the browser->remote clipboard push (see
// docs/KNOWN_ISSUES.md and memory cockpit-guac-rdp-send-clip-investigation).
// Instead of the native clipboard channel, this types the local clipboard's
// text into the session one keysym at a time via sendGuestKeyEvent -- the
// same key-event path real keystrokes already use (deliberately NOT
// keyboard.press()/release(), which an adversarial review found shares state
// with real physical keystrokes -- see the block's own header comment).
//
// The block is extracted VERBATIM (between the TESTHOOK:TYPECLIP sentinels)
// and run standalone via `vm`, so this tests the actual shipped code, not a
// reimplementation.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(
    path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');

const BEGIN = '// TESTHOOK:TYPECLIP:BEGIN';
const END = '// TESTHOOK:TYPECLIP:END';
const beginIdx = SRC.indexOf(BEGIN);
const endIdx = SRC.indexOf(END);
assert.ok(beginIdx !== -1 && endIdx !== -1 && endIdx > beginIdx,
    'guac-rdp.js TESTHOOK:TYPECLIP sentinels not found -- did the Type ' +
    'Clipboard block move or get renamed? Update this test to match.');
const block = SRC.slice(beginIdx, endIdx);

// Builds a fresh sandbox: a fake `sendGuestKeyEvent` recording every
// (down, keysym) call in order. This is the SAME function real physical
// keystrokes call (see keyboard_remap.test.js, which tests its KEYCODE_FIX/
// SHIFT_LEVEL corrections directly) -- this test only needs to check WHICH
// keysyms this block sends and in what order, not that wiring again.
function makeSandbox() {
    const calls = [];
    const shifts = [];   // the forceShift argument of each call (I65), parallel to calls
    const sendGuestKeyEvent = (down, ks, sh) => { calls.push([down ? 'down' : 'up', ks]); shifts.push(sh); };
    const ctx = vm.createContext({ sendGuestKeyEvent });
    vm.runInContext(block, ctx);
    return { ctx, calls, shifts };
}

function tap(ks) { return [['down', ks], ['up', ks]]; }

test('keysymForCodePoint: Latin-1 range (excluding C1 controls) is the direct code point', () => {
    const s = makeSandbox();
    assert.strictEqual(s.ctx.keysymForCodePoint(0x20), 0x20);   // space
    assert.strictEqual(s.ctx.keysymForCodePoint(0x41), 0x41);   // 'A'
    assert.strictEqual(s.ctx.keysymForCodePoint(0x7e), 0x7e);   // '~'
    assert.strictEqual(s.ctx.keysymForCodePoint(0xa0), 0xa0);   // first char after the C1 block
    assert.strictEqual(s.ctx.keysymForCodePoint(0xe9), 0xe9);   // 'é'
    assert.strictEqual(s.ctx.keysymForCodePoint(0xff), 0xff);
});

test('keysymForCodePoint: LF and CR both force the real Return keysym, not Linefeed', () => {
    // Guacamole.Keyboard's own vendored .type() maps "\n" to Linefeed (0xFF0A),
    // a keysym with no key on the Xvfb "us" keymap (verified with a standalone
    // vm probe against the real vendored library) -- typing a bare LF would
    // silently do nothing. This project deliberately overrides both to 0xFF0D,
    // the same keysym a physical Enter key sends.
    const s = makeSandbox();
    assert.strictEqual(s.ctx.keysymForCodePoint(0x0A), 0xFF0D);
    assert.strictEqual(s.ctx.keysymForCodePoint(0x0D), 0xFF0D);
});

// I70: these two tests used to pin PARITY with the vendored Guacamole.Keyboard
// ("|0xFF00" for every C0/C1 control and DEL). That parity was the defect: DEL
// became Num_Lock, 0x13/0x14 Pause/Scroll_Lock, 0x1B Escape, 0x95-0x9F keypad
// navigation -- a stray control byte in clipboard text toggled lock keys or hit
// Escape in the guest. Only Tab and LF/CR (Return) are typed now; everything else
// maps to 0 (= dropped and counted by typeTextIntoSession).
test('keysymForCodePoint: Tab is the only typed control besides Return; every other C0 control is dropped (0)', () => {
    const s = makeSandbox();
    assert.strictEqual(s.ctx.keysymForCodePoint(0x09), 0xFF09);   // Tab
    for (let cp = 0; cp <= 0x1F; cp++) {
        if (cp === 0x09 || cp === 0x0A || cp === 0x0D) continue;
        assert.strictEqual(s.ctx.keysymForCodePoint(cp), 0, 'C0 0x' + cp.toString(16));
    }
});

test('keysymForCodePoint: DEL and the whole C1 range (0x7F-0x9F) are dropped (0), never Num_Lock/keypad keys', () => {
    const s = makeSandbox();
    for (let cp = 0x7F; cp <= 0x9F; cp++) {
        assert.strictEqual(s.ctx.keysymForCodePoint(cp), 0, 'cp 0x' + cp.toString(16));
    }
    assert.notStrictEqual(s.ctx.keysymForCodePoint(0x7F), 0xFF7F, 'DEL must not be Num_Lock');
});

test('typeTextIntoSession: control characters send NO key events and are counted as skipped', () => {
    const s = makeSandbox();
    const st = {};
    const n = s.ctx.typeTextIntoSession('a\x13\x14\x1b\x7f\x08\x95b\t', st);
    assert.strictEqual(n, 3);
    assert.deepStrictEqual(s.calls, [...tap(0x61), ...tap(0x62), ...tap(0xFF09)]);
    assert.strictEqual(st.typed, 3);
    assert.strictEqual(st.controls, 6);
});

test('keysymForCodePoint: anything above Latin-1 is the Unicode keysym plane, including the 0x100 boundary', () => {
    const s = makeSandbox();
    assert.strictEqual(s.ctx.keysymForCodePoint(0x100), 0x01000100);    // 'Ā', first code point above Latin-1
    assert.strictEqual(s.ctx.keysymForCodePoint(0x20AC), 0x010020AC);   // '€'
    assert.strictEqual(s.ctx.keysymForCodePoint(0x4E2D), 0x01004E2D);   // '中'
    assert.strictEqual(s.ctx.keysymForCodePoint(0x1F600), 0x0101F600);  // an emoji (astral plane)
});

test('typeTextIntoSession: empty string types nothing and returns 0', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('');
    assert.strictEqual(n, 0);
    assert.deepStrictEqual(s.calls, []);
});

test('typeTextIntoSession: plain ASCII text presses and releases each character in order', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('Ab1');
    assert.strictEqual(n, 3);
    assert.deepStrictEqual(s.calls, [...tap(0x41), ...tap(0x62), ...tap(0x31)]);
});

test('typeTextIntoSession: a bare LF (Linux-style clipboard text) types one Return', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('a\nb');
    assert.strictEqual(n, 3);
    assert.deepStrictEqual(s.calls, [...tap(0x61), ...tap(0xFF0D), ...tap(0x62)]);
});

test('typeTextIntoSession: a CRLF pair (Windows-style clipboard text) types exactly one Return, not two', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('a\r\nb');
    assert.strictEqual(n, 3, 'CRLF must count as a single typed character');
    assert.deepStrictEqual(s.calls, [...tap(0x61), ...tap(0xFF0D), ...tap(0x62)],
        'CRLF must not produce two Return presses');
});

test('typeTextIntoSession: a lone trailing CR with nothing after it does not throw', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('a\r');
    assert.strictEqual(n, 2);
    assert.deepStrictEqual(s.calls, [...tap(0x61), ...tap(0xFF0D)]);
});

test('typeTextIntoSession: CR followed by a non-LF control character types BOTH -- the collapse is exact, not a range', () => {
    // A looser collapse condition (e.g. "next char <= 0x0A" instead of
    // "=== 0x0A") would silently swallow whatever follows a CR that isn't
    // itself a newline. Caught by adversarial review (mutation survived the
    // original suite).
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('\r\t');
    assert.strictEqual(n, 2, 'Return AND Tab must both be typed');
    assert.deepStrictEqual(s.calls, [...tap(0xFF0D), ...tap(0xFF09)]);
});

test('typeTextIntoSession: repeated CRLFs and bare CR-CR (no LF) each collapse/pass through independently', () => {
    const s1 = makeSandbox();
    assert.strictEqual(s1.ctx.typeTextIntoSession('\r\n\r\n'), 2);
    assert.deepStrictEqual(s1.calls, [...tap(0xFF0D), ...tap(0xFF0D)]);

    const s2 = makeSandbox();
    assert.strictEqual(s2.ctx.typeTextIntoSession('\r\r'), 2, 'two bare CRs must type two Returns, not merge');
    assert.deepStrictEqual(s2.calls, [...tap(0xFF0D), ...tap(0xFF0D)]);
});

test('typeTextIntoSession: a surrogate-pair character (astral plane) is typed as ONE keystroke, not two', () => {
    const s = makeSandbox();
    const text = '\u{1F600}';   // a single emoji, encoded as a UTF-16 surrogate pair
    assert.strictEqual(text.length, 2, 'sanity: this character is 2 UTF-16 code units');
    const n = s.ctx.typeTextIntoSession(text);
    assert.strictEqual(n, 1, 'must count as one typed character, not two');
    assert.deepStrictEqual(s.calls, tap(0x0101F600));
});

test('typeTextIntoSession: a lone/unpaired high surrogate does not throw (pins current behavior)', () => {
    // Clipboard text truncated mid-emoji, or from a lossy encoding conversion,
    // can contain a high surrogate with no matching low surrogate.
    // codePointAt() then returns the bare surrogate code unit; this is not a
    // valid Unicode scalar value and has no defined meaning to x11vnc, but the
    // important behavioral guarantee is that it is handled deterministically
    // (typed as its own "keysym" and moved past) rather than throwing or
    // getting the parser stuck.
    const s = makeSandbox();
    assert.doesNotThrow(() => {
        const n = s.ctx.typeTextIntoSession('\uD800X');
        assert.strictEqual(n, 2, 'the lone surrogate and the following X are each typed once');
    });
    assert.deepStrictEqual(s.calls, [...tap(0x0100D800), ...tap(0x58)]);
});

test('typeTextIntoSession: mixed multi-line, multi-script text end to end', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('Hi €5\r\n中文');
    assert.strictEqual(n, 8, 'H i space euro 5 Return(CRLF collapsed) 中 文');
    assert.deepStrictEqual(s.calls, [
        ...tap(0x48), ...tap(0x69), ...tap(0x20),
        ...tap(0x010020AC), ...tap(0x35),
        ...tap(0xFF0D),
        ...tap(0x01004E2D), ...tap(0x01006587),
    ]);
});

// ---- I65: letter case. Injected text has no physical Shift, and x11vnc
// -nomodtweak presses the lowest-level keycode with whatever modifiers the
// client holds, so 'A' arrived as 'a'. The block now passes the wanted Shift
// state to sendGuestKeyEvent; the second half drives the REAL
// sendGuestKeyEvent (KEYREMAP block) and checks the wire events.

test('letterShift: upper-case letters need Shift, lower-case must not, others untouched', () => {
    const s = makeSandbox();
    for (const c of 'ABCXYZ') assert.strictEqual(s.ctx.letterShift(c.codePointAt(0)), true, c);
    for (const c of 'abcxyz') assert.strictEqual(s.ctx.letterShift(c.codePointAt(0)), false, c);
    for (const c of 'ÀÉÖØÞÅ') assert.strictEqual(s.ctx.letterShift(c.codePointAt(0)), true, c);
    for (const c of 'àéöøþßÿå') assert.strictEqual(s.ctx.letterShift(c.codePointAt(0)), false, c);
    assert.strictEqual(s.ctx.letterShift(0xD7), undefined, 'multiplication sign');
    assert.strictEqual(s.ctx.letterShift(0xF7), undefined, 'division sign');
    for (const c of '0123456789 !"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~') {
        assert.strictEqual(s.ctx.letterShift(c.codePointAt(0)), undefined, JSON.stringify(c));
    }
    assert.strictEqual(s.ctx.letterShift(0x0A), undefined);
    assert.strictEqual(s.ctx.letterShift(0x4E2D), undefined, 'caseless CJK');
    assert.strictEqual(s.ctx.letterShift(0x20AC), undefined, 'euro sign');
    assert.strictEqual(s.ctx.letterShift(0x1F600), undefined, 'emoji');
    assert.strictEqual(s.ctx.letterShift(0x0416), undefined, 'above Latin-1: keysym carries the case itself');
    assert.strictEqual(s.ctx.letterShift(0x0436), undefined);
});

test('typeTextIntoSession: passes the wanted Shift state with every letter press AND release', () => {
    const s = makeSandbox();
    s.ctx.typeTextIntoSession('Hi!');
    assert.deepStrictEqual(s.shifts, [true, true, false, false, undefined, undefined]);
});

// Real sendGuestKeyEvent + injected block, wire-level.
function makeWire() {
    const rm = fs.readFileSync(path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');
    const a = rm.indexOf('// TESTHOOK:KEYREMAP:BEGIN'), b = rm.indexOf('// TESTHOOK:KEYREMAP:END');
    assert.ok(a !== -1 && b > a);
    const wire = [];
    const pressed = {};
    const ctx = vm.createContext({
        client: { sendKeyEvent(d, ks) { wire.push([d, ks]); } },
        keyboard: { pressed }, navigator: { platform: '', userAgent: '' },
    });
    vm.runInContext(rm.slice(a, b), ctx);
    vm.runInContext(block, ctx);
    return { ctx, wire, pressed };
}
const SHIFT = 0xFFE1;
const wireTap = (ks) => [[1, ks], [0, ks]];

test('wire: an upper-case letter is typed with Shift held, then Shift released', () => {
    const w = makeWire();
    w.ctx.typeTextIntoSession('H');
    assert.deepStrictEqual(w.wire, [[1, SHIFT], [1, 0x48], [0, 0x48], [0, SHIFT]]);
});

test('wire: "Hello World" -- Shift brackets exactly the capitals, lower-case gets none', () => {
    const w = makeWire();
    w.ctx.typeTextIntoSession('Hello World');
    const exp = [];
    for (const c of 'Hello World') {
        const ks = c.codePointAt(0);
        if (c >= 'A' && c <= 'Z') exp.push([1, SHIFT], ...wireTap(ks), [0, SHIFT]);
        else exp.push(...wireTap(ks));
    }
    assert.deepStrictEqual(w.wire, exp);
});

test('wire: upper-case while the user physically holds Shift -> no extra Shift traffic', () => {
    const w = makeWire();
    w.pressed[SHIFT] = true;
    w.ctx.typeTextIntoSession('H');
    assert.deepStrictEqual(w.wire, wireTap(0x48));
});

test('wire: lower-case while the user physically holds Shift -> Shift released around the key, then restored', () => {
    const w = makeWire();
    w.pressed[SHIFT] = true;
    w.ctx.typeTextIntoSession('h');
    assert.deepStrictEqual(w.wire, [[0, SHIFT], [1, 0x68], [0, 0x68], [1, SHIFT]]);
});

test('wire: punctuation/digits keep the I45 behaviour (table-driven, unchanged by I65)', () => {
    const w = makeWire();
    w.ctx.typeTextIntoSession('1(,');
    assert.deepStrictEqual(w.wire, [
        ...wireTap(0x31),
        [1, SHIFT], ...wireTap(0x39), [0, SHIFT],     // '(' -> Shift+9
        ...wireTap(0x2c),
    ]);
    const w2 = makeWire(); w2.pressed[SHIFT] = true;
    w2.ctx.typeTextIntoSession('1');
    assert.deepStrictEqual(w2.wire, [[0, SHIFT], ...wireTap(0x31), [1, SHIFT]]);
});

test('wire: Latin-1 upper-case is Shifted, lower-case is not; control keys untouched', () => {
    const w = makeWire();
    w.ctx.typeTextIntoSession('Éé\t');
    assert.deepStrictEqual(w.wire, [[1, SHIFT], ...wireTap(0xC9), [0, SHIFT], ...wireTap(0xE9), ...wireTap(0xFF09)]);
});

test('wire: injected typing never touches keyboard.pressed and leaves no stale shiftAdjust', () => {
    const w = makeWire();
    w.ctx.typeTextIntoSession('AbC(');
    assert.deepStrictEqual(Object.keys(w.pressed), []);
    // a second run from a clean state must behave identically (no leaked entries)
    const first = w.wire.slice(); w.wire.length = 0;
    w.ctx.typeTextIntoSession('AbC(');
    assert.deepStrictEqual(w.wire, first);
});
