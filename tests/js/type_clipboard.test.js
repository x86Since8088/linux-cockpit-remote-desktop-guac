#!/usr/bin/env node
// Unit tests for the "Type Clipboard" keystroke-injection helpers in
// ../../guac-rdp.js -- a workaround for the confirmed upstream guacd/x11vnc bug
// that silently drops the browser->remote clipboard push (see
// docs/KNOWN_ISSUES.md and memory cockpit-guac-rdp-send-clip-investigation).
// Instead of the native clipboard channel, this types the local clipboard's
// text into the session one keysym at a time over the same key-event path
// real keystrokes already use.
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

// Builds a fresh sandbox: a fake `keyboard` recording every press/release call
// in order, standing in for Guacamole.Keyboard's real press()/release() (which
// this project already verified route to sendGuestKeyEvent -- see
// keyboard_remap.test.js -- so this test only needs to check WHICH keysyms and
// in what order, not that wiring again).
function makeSandbox() {
    const calls = [];
    const keyboard = {
        press(ks) { calls.push(['press', ks]); },
        release(ks) { calls.push(['release', ks]); },
    };
    const ctx = vm.createContext({ keyboard });
    vm.runInContext(block, ctx);
    return { ctx, calls };
}

function pressRelease(ks) { return [['press', ks], ['release', ks]]; }

test('keysymForCodePoint: Latin-1 range is the direct code point', () => {
    const s = makeSandbox();
    assert.strictEqual(s.ctx.keysymForCodePoint(0x20), 0x20);   // space
    assert.strictEqual(s.ctx.keysymForCodePoint(0x41), 0x41);   // 'A'
    assert.strictEqual(s.ctx.keysymForCodePoint(0x7e), 0x7e);   // '~'
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

test('keysymForCodePoint: other C0 controls map via the |0xFF00 convention (e.g. Tab)', () => {
    const s = makeSandbox();
    assert.strictEqual(s.ctx.keysymForCodePoint(0x09), 0xFF09);   // Tab
    assert.strictEqual(s.ctx.keysymForCodePoint(0x08), 0xFF08);   // Backspace
    assert.strictEqual(s.ctx.keysymForCodePoint(0x1b), 0xFF1b);   // Escape
});

test('keysymForCodePoint: anything above Latin-1 is the Unicode keysym plane', () => {
    const s = makeSandbox();
    assert.strictEqual(s.ctx.keysymForCodePoint(0x20AC), 0x010020AC);   // '€'
    assert.strictEqual(s.ctx.keysymForCodePoint(0x4E2D), 0x01004E2D);   // '中'
    assert.strictEqual(s.ctx.keysymForCodePoint(0x1F600), 0x0101F600);  // an emoji (astral plane)
});

test('typeTextIntoSession: plain ASCII text presses and releases each character in order', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('Ab1');
    assert.strictEqual(n, 3);
    assert.deepStrictEqual(s.calls, [
        ...pressRelease(0x41), ...pressRelease(0x62), ...pressRelease(0x31),
    ]);
});

test('typeTextIntoSession: a bare LF (Linux-style clipboard text) types one Return', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('a\nb');
    assert.strictEqual(n, 3);
    assert.deepStrictEqual(s.calls, [
        ...pressRelease(0x61), ...pressRelease(0xFF0D), ...pressRelease(0x62),
    ]);
});

test('typeTextIntoSession: a CRLF pair (Windows-style clipboard text) types exactly one Return, not two', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('a\r\nb');
    assert.strictEqual(n, 3, 'CRLF must count as a single typed character');
    assert.deepStrictEqual(s.calls, [
        ...pressRelease(0x61), ...pressRelease(0xFF0D), ...pressRelease(0x62),
    ], 'CRLF must not produce two Return presses');
});

test('typeTextIntoSession: a lone trailing CR with nothing after it does not throw', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('a\r');
    assert.strictEqual(n, 2);
    assert.deepStrictEqual(s.calls, [...pressRelease(0x61), ...pressRelease(0xFF0D)]);
});

test('typeTextIntoSession: a surrogate-pair character (astral plane) is typed as ONE keystroke, not two', () => {
    const s = makeSandbox();
    const text = '\u{1F600}';   // a single emoji, encoded as a UTF-16 surrogate pair
    assert.strictEqual(text.length, 2, 'sanity: this character is 2 UTF-16 code units');
    const n = s.ctx.typeTextIntoSession(text);
    assert.strictEqual(n, 1, 'must count as one typed character, not two');
    assert.deepStrictEqual(s.calls, pressRelease(0x0101F600));
});

test('typeTextIntoSession: mixed multi-line, multi-script text end to end', () => {
    const s = makeSandbox();
    const n = s.ctx.typeTextIntoSession('Hi €5\r\n中文');
    assert.strictEqual(n, 8, 'H i space euro 5 Return(CRLF collapsed) 中 文');
    assert.deepStrictEqual(s.calls, [
        ...pressRelease(0x48), ...pressRelease(0x69), ...pressRelease(0x20),
        ...pressRelease(0x010020AC), ...pressRelease(0x35),
        ...pressRelease(0xFF0D),
        ...pressRelease(0x01004E2D), ...pressRelease(0x01006587),
    ]);
});
