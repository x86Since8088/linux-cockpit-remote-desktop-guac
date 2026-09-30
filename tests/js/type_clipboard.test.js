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
    const sendGuestKeyEvent = (down, ks) => calls.push([down ? 'down' : 'up', ks]);
    const ctx = vm.createContext({ sendGuestKeyEvent });
    vm.runInContext(block, ctx);
    return { ctx, calls };
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

test('keysymForCodePoint: C0 controls map via the |0xFF00 convention (e.g. Tab), including the 0x1F boundary', () => {
    const s = makeSandbox();
    assert.strictEqual(s.ctx.keysymForCodePoint(0x09), 0xFF09);   // Tab
    assert.strictEqual(s.ctx.keysymForCodePoint(0x08), 0xFF08);   // Backspace
    assert.strictEqual(s.ctx.keysymForCodePoint(0x1b), 0xFF1b);   // Escape
    assert.strictEqual(s.ctx.keysymForCodePoint(0x1F), 0xFF1F);   // Unit Separator: exact C0 upper boundary
});

test('keysymForCodePoint: the C1 control range (0x7F-0x9F) ALSO maps via |0xFF00, not as a direct keysym', () => {
    // An earlier draft of this function treated 0x7F-0x9F (DEL plus the C1
    // block -- plausible from a Windows-1252-as-Latin-1 mis-decode, or a
    // terminal copy) as direct-value keysyms. The vendored Guacamole.Keyboard's
    // own codepoint-to-keysym function does NOT: it explicitly carves this
    // range out into the same "function key" convention as the C0 controls.
    // Caught by adversarial review; verified against the real vendored
    // function in guacamole-common-js/all.min.js.
    const s = makeSandbox();
    assert.strictEqual(s.ctx.keysymForCodePoint(0x7F), 0xFF7F, 'DEL');
    assert.strictEqual(s.ctx.keysymForCodePoint(0x80), 0xFF80, 'first C1 control');
    assert.strictEqual(s.ctx.keysymForCodePoint(0x85), 0xFF85, 'NEL');
    assert.strictEqual(s.ctx.keysymForCodePoint(0x9F), 0xFF9F, 'last C1 control: exact upper boundary');
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
