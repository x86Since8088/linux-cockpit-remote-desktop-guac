#!/usr/bin/env node
// I73-I77: clipboard policy in ../../guac-rdp.js -- wayland-vnc UTF-8 encoding,
// Send-clip status/warnings, the error-515 explanation, per-scenario Clipboard
// auto-sync defaults, and lastRemoteClip hygiene. Pure logic is extracted
// verbatim from the TESTHOOK:CLIPPOLICY block; guacdValues and the teardown
// bits are checked by slicing the shipped source. GUAC_JS may point at another
// copy of guac-rdp.js (used to prove the tests fail against main).
'use strict';
const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(process.env.GUAC_JS ||
    path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');

function hook() {
    const b = SRC.indexOf('// TESTHOOK:CLIPPOLICY:BEGIN'), e = SRC.indexOf('// TESTHOOK:CLIPPOLICY:END');
    assert.ok(b !== -1 && e > b, 'TESTHOOK:CLIPPOLICY block missing from guac-rdp.js');
    const ctx = vm.createContext({});
    vm.runInContext(SRC.slice(b, e), ctx);
    return ctx;
}
function guacdValues(scenario, audio) {
    const m = /    function guacdValues\([^)]*\) \{[\s\S]*?\n    \}\n/.exec(SRC);
    assert.ok(m, 'guacdValues not found');
    const ctx = vm.createContext({
        $: (id) => id === 'opt-audio' ? { checked: !!audio } : null,
        trace() {},
    });
    // clipboardEncodingParam lives in the policy block
    const b = SRC.indexOf('// TESTHOOK:CLIPPOLICY:BEGIN'), e = SRC.indexOf('// TESTHOOK:CLIPPOLICY:END');
    if (b !== -1 && e > b) vm.runInContext(SRC.slice(b, e), ctx);
    vm.runInContext(m[0] + '\nthis.guacdValues = guacdValues;', ctx);
    return ctx.guacdValues(scenario);
}

// ---- I73
test('I73: wayland-vnc negotiates clipboard-encoding=UTF-8', () => {
    assert.strictEqual(guacdValues('wayland-vnc')['clipboard-encoding'], 'UTF-8');
});
test('I73: every other scenario keeps guacd\'s default (no clipboard-encoding sent)', () => {
    for (const k of ['isolated', 'virtual', 'console', 'greeter', 'remote', 'vnc'])
        assert.strictEqual(guacdValues(k)['clipboard-encoding'], undefined, k);
});
test('I73: enable-audio is unaffected', () => {
    assert.strictEqual(guacdValues('wayland-vnc', true)['enable-audio'], 'true');
});
test('I73: connect passes the scenario into guacdValues', () => {
    assert.ok(/values:\s*guacdValues\(key\)/.test(SRC));
});

// ---- I74
test('I74: Send clip never claims success outright and says the session may not accept it', () => {
    const h = hook();
    const m = h.sendClipboardMessage(h.analyzeSendClipboard('hello', 'isolated'));
    assert.match(m, /^Sent 5 characters \(the session may not accept it/);
    assert.doesNotMatch(m, /paste inside the session\.$/);
});
test('I74: over 256 KiB warns (bytes, not UTF-16 units)', () => {
    const h = hook();
    assert.strictEqual(h.analyzeSendClipboard('a'.repeat(262144), 'isolated').tooBig, false);
    assert.strictEqual(h.analyzeSendClipboard('a'.repeat(262145), 'isolated').tooBig, true);
    // 100k CJK chars = 300k bytes, though only 100k UTF-16 units
    assert.strictEqual(h.analyzeSendClipboard('中'.repeat(100000), 'wayland-vnc').tooBig, true);
    assert.match(h.sendClipboardMessage(h.analyzeSendClipboard('a'.repeat(300000), 'wayland-vnc')), /256 KiB/);
});
test('I74: non-Latin-1 warns on Latin-1 scenarios, not on wayland-vnc (UTF-8)', () => {
    const h = hook();
    for (const k of ['isolated', 'virtual', 'console', 'greeter', 'remote', 'vnc']) {
        const r = h.analyzeSendClipboard('café 中文', k);
        assert.strictEqual(r.nonLatin1, 2, k);
        assert.match(h.sendClipboardMessage(r), /Latin-1/);
    }
    assert.strictEqual(h.analyzeSendClipboard('café 中文', 'wayland-vnc').nonLatin1, 0);
    assert.strictEqual(h.analyzeSendClipboard('café', 'isolated').warnings.length, 0, 'plain Latin-1 is fine');
});

// ---- I75
test('I75: a 515 after a connected session / clipboard activity explains the large-clipboard cause', () => {
    const h = hook();
    assert.match(h.upstream515Hint(515, true, false), /very large clipboard on the remote side/);
    assert.match(h.upstream515Hint(515, false, true), /reconnect/);
});
test('I75: other codes and a connect-time 515 with no clipboard activity get no hint', () => {
    const h = hook();
    assert.strictEqual(h.upstream515Hint(519, true, true), '');
    assert.strictEqual(h.upstream515Hint(515, false, false), '');
    assert.strictEqual(h.upstream515Hint(undefined, true, true), '');
});
test('I75: the error handler appends the hint and never auto-reconnects on an error', () => {
    assert.match(SRC, /msg \+= upstream515Hint\(e && e\.code,/);
    // explain() sets errored, and shouldFollowGreeterDrop refuses to follow an errored drop
    assert.match(SRC, /return scenario === "greeter" && !errored/);
});

// ---- I76
test('I76: auto-sync defaults on only for managed scenarios, off for remote and vnc', () => {
    const h = hook();
    for (const k of ['console', 'greeter', 'isolated', 'virtual', 'headless', 'wayland-vnc'])
        assert.strictEqual(h.clipboardAutoDefault(k, {}), true, k);
    for (const k of ['remote', 'vnc', 'something-new'])
        assert.strictEqual(h.clipboardAutoDefault(k, {}), false, k);
});
test('I76: a remembered per-scenario choice wins, in both directions, and only for that scenario', () => {
    const h = hook();
    assert.strictEqual(h.clipboardAutoDefault('vnc', { vnc: true }), true);
    assert.strictEqual(h.clipboardAutoDefault('isolated', { isolated: false }), false);
    assert.strictEqual(h.clipboardAutoDefault('remote', { vnc: true }), false);
    assert.strictEqual(h.clipboardAutoDefault('vnc', { vnc: 'yes' }), false, 'non-boolean is ignored');
});
test('I76: the Clipboard checkbox is no longer hard-coded checked in index.html', () => {
    const html = fs.readFileSync(path.join(__dirname, '..', '..', 'index.html'), 'utf8');
    assert.doesNotMatch(html, /id="opt-clipboard"[^>]*checked/);
});
test('I76: connect applies the scenario default before connecting', () => {
    assert.match(SRC, /activeKey = key;\s*applyClipboardDefault\(key\);/);
});

// ---- I77
test('I77: lastRemoteClip is cleared on dispose and at connect', () => {
    const d = /function dispose\(\) \{[\s\S]*?\n        \}/.exec(SRC);
    assert.ok(d && /lastRemoteClip = null/.test(d[0]), 'dispose() must clear lastRemoteClip');
    assert.match(SRC, /client = new Guacamole\.Client\(tunnel\);\s*lastRemoteClip = null;/);
});
