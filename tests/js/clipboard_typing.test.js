#!/usr/bin/env node
// I70-I72: Type Clipboard policy -- control characters are dropped (I70), the
// pre-scan for characters the session cannot type (I71), and a run is bound to
// the session that started it and pauses in a hidden tab (I72). Runs the shipped
// TESTHOOK:TYPECLIP block. GUAC_JS may point at another guac-rdp.js copy.
'use strict';
const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(process.env.GUAC_JS ||
    path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');
const b = SRC.indexOf('// TESTHOOK:TYPECLIP:BEGIN'), e = SRC.indexOf('// TESTHOOK:TYPECLIP:END');
assert.ok(b !== -1 && e > b, 'TYPECLIP sentinels missing');
const block = SRC.slice(b, e);

function sandbox() {
    const keys = [], status = [], timers = [], listeners = [];
    const doc = { hidden: false,
        addEventListener: (t, f) => listeners.push([t, f]),
        removeEventListener: (t, f) => { const i = listeners.findIndex(x => x[1] === f); if (i >= 0) listeners.splice(i, 1); } };
    const ctx = vm.createContext({
        sendGuestKeyEvent: (down, ks) => keys.push([down ? 1 : 0, ks]),
        client: {}, keyboard: {}, document: doc,
        setStatus: (m, k) => status.push(m),
        setTimeout: (f) => timers.push(f),
    });
    vm.runInContext(block, ctx);
    return { ctx, keys, status, timers, listeners, doc,
        flush() { while (this.timers.length) this.timers.shift()(); },
        downs() { return this.keys.filter(k => k[0] === 1).map(k => k[1]); } };
}
const chars = (t) => Array.from(t);

// ---- I70
test('I70: DEL / 0x13 / 0x14 / ESC / C1 produce no Num_Lock/Pause/Scroll_Lock/Escape/keypad keysyms', () => {
    const s = sandbox();
    s.ctx.typeTextIntoSession('\x7f\x13\x14\x1b\x80\x95\x9f');
    assert.deepStrictEqual(s.keys, []);
});
test('I70: Tab, LF, CR, CRLF still type; Backspace does not', () => {
    const s = sandbox();
    s.ctx.typeTextIntoSession('\t\n\r\r\n\b');
    assert.deepStrictEqual(s.downs(), [0xFF09, 0xFF0D, 0xFF0D, 0xFF0D]);
});

// ---- I71
test('I71: ASCII-only text on wayland-vnc has nothing to warn about', () => {
    const s = sandbox();
    const a = s.ctx.analyzeTypeText(chars('Hello, World!\n\tok'), 'wayland-vnc', {});
    assert.strictEqual(a.blockedCount, 0);
});
test('I71: wayland-vnc blocks ALL non-ASCII, with count and distinct list', () => {
    const s = sandbox();
    const a = s.ctx.analyzeTypeText(chars('aé中中\u{1F600}b'), 'wayland-vnc', {});
    assert.strictEqual(a.blockedCount, 4);
    assert.deepStrictEqual(Array.from(a.blockedList), [0xE9, 0x4E2D, 0x1F600]);
    assert.match(s.ctx.typeWarnMessage(a, 'wayland-vnc'), /4 characters.*3 distinct.*ASCII keystrokes only/s);
});
test('I71: the x11vnc pool admits 17 distinct non-ASCII characters; the 18th is blocked; repeats are free', () => {
    const s = sandbox();
    let t = ''; for (let i = 0; i < 18; i++) t += String.fromCodePoint(0x4E00 + i);
    t += String.fromCodePoint(0x4E00);            // a repeat of an admitted one
    const a = s.ctx.analyzeTypeText(chars(t), 'isolated', {});
    assert.strictEqual(a.blockedCount, 1);
    assert.deepStrictEqual(Array.from(a.blockedList), [0x4E00 + 17]);
    assert.strictEqual(a.newPool.length, 17);
});
test('I71: the pool is per session -- already-used code points count against the 17', () => {
    const s = sandbox();
    const used = {}; for (let i = 0; i < 17; i++) used[0x4E00 + i] = true;
    const a = s.ctx.analyzeTypeText(chars('一倀'), 'virtual', used);
    assert.deepStrictEqual(Array.from(a.blockedList), [0x5000], 'known char fine, a NEW one blocked');
});
test('I71: lone surrogates are always unsupported', () => {
    const s = sandbox();
    assert.strictEqual(s.ctx.analyzeTypeText(['\uD800'], 'isolated', {}).blockedCount, 1);
});
test('I71: blocked characters are skipped and counted, never typed; the report is honest', () => {
    const s = sandbox();
    const a = s.ctx.analyzeTypeText(chars('AéB\x1b'), 'wayland-vnc', {});
    const st = {};
    s.ctx.typeTextIntoSession('AéB\x1b', st, a.blocked);
    assert.deepStrictEqual(s.downs(), [0x41, 0x42]);
    assert.deepStrictEqual([st.typed, st.controls, st.unsupported], [2, 1, 1]);
    const m = s.ctx.typeResultMessage(st, true);
    assert.match(m, /^Typed 2 characters; skipped 2 \(1 control character, 1 the session cannot type\)\.$/);
    assert.doesNotMatch(s.ctx.typeResultMessage({ typed: 3, controls: 0, unsupported: 0 }, true), /skipped/);
});
test('I71: the page confirms before typing when anything is blocked, and cancel types nothing', () => {
    assert.match(SRC, /if \(plan\.blockedCount\) \{[\s\S]*?window\.confirm\(typeWarnMessage\(plan, activeKey\)\)[\s\S]*?nothing was typed/);
    assert.doesNotMatch(SRC, /"Typed " \+ text\.length \+ " characters into the session\."/);
});

// ---- I72
test('I72: a run aborts, typing nothing more, when the session changes between chunks', () => {
    const s = sandbox();
    const text = 'x'.repeat(500);          // 3 chunks of <=200
    let result = null;
    s.ctx.typeClipboardChunked(chars(text), {}, (st, state) => { result = [st.typed, state]; });
    assert.strictEqual(s.downs().length, 200, 'first chunk typed synchronously');
    s.ctx.bumpClipSession();               // reconnect
    s.flush();
    assert.strictEqual(s.downs().length, 200, 'no keystrokes into the new session');
    assert.deepStrictEqual(result, [200, 'replaced']);
});
test('I72: an uninterrupted run completes', () => {
    const s = sandbox();
    let result = null;
    s.ctx.typeClipboardChunked(chars('x'.repeat(450)), {}, (st, state) => { result = [st.typed, state]; });
    s.flush();
    assert.deepStrictEqual(result, [450, 'done']);
});
test('I72: client gone mid-run reports "ended"', () => {
    const s = sandbox();
    let state = null;
    s.ctx.typeClipboardChunked(chars('x'.repeat(450)), {}, (st, st2) => { state = st2; });
    s.ctx.client = null; s.flush();
    assert.strictEqual(state, 'ended');
});
test('I72: a hidden tab pauses with a status message (no timer crawl) and resumes on visibility', () => {
    const s = sandbox();
    s.doc.hidden = true;
    let result = null;
    s.ctx.typeClipboardChunked(chars('x'.repeat(300)), {}, (st, state) => { result = [st.typed, state]; });
    assert.strictEqual(s.keys.length, 0);
    assert.strictEqual(s.timers.length, 0, 'no setTimeout polling while hidden');
    assert.match(s.status.join('|'), /Paused/);
    assert.strictEqual(s.listeners.length, 1);
    s.doc.hidden = false; s.listeners[0][1](); s.flush();
    assert.deepStrictEqual(result, [300, 'done']);
    assert.strictEqual(s.listeners.length, 0, 'visibility listener removed');
});
test('I72: a session replaced while paused is not typed into on return', () => {
    const s = sandbox();
    s.doc.hidden = true;
    let state = null;
    s.ctx.typeClipboardChunked(chars('x'.repeat(10)), {}, (st, st2) => { state = st2; });
    s.ctx.bumpClipSession(); s.doc.hidden = false; s.listeners[0][1]();
    assert.strictEqual(s.keys.length, 0);
    assert.strictEqual(state, 'replaced');
});
test('I72: connect and dispose bump the session generation', () => {
    assert.match(SRC, /lastRemoteClip = null; bumpClipSession\(\)/);
    assert.match(SRC, /lastRemoteClip = null;[^\n]*\n\s*bumpClipSession\(\)/);
});
