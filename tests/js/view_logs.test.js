#!/usr/bin/env node
// Unit tests for the "Logs…" viewer's journalctl-line parsing in
// ../../guac-rdp.js. The block is extracted VERBATIM (between the
// TESTHOOK:PARSEJOURNAL sentinels) and run standalone via `vm`, so this tests
// the actual shipped code, not a reimplementation.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(
    path.join(__dirname, '..', '..', 'guac-rdp.js'), 'utf8');

const BEGIN = '// TESTHOOK:PARSEJOURNAL:BEGIN';
const END = '// TESTHOOK:PARSEJOURNAL:END';
const beginIdx = SRC.indexOf(BEGIN);
const endIdx = SRC.indexOf(END);
assert.ok(beginIdx !== -1 && endIdx !== -1 && endIdx > beginIdx,
    'guac-rdp.js TESTHOOK:PARSEJOURNAL sentinels not found -- did the Logs ' +
    'viewer block move or get renamed? Update this test to match.');
const block = SRC.slice(beginIdx, endIdx);

function makeSandbox() {
    const ctx = vm.createContext({});
    vm.runInContext(block, ctx);
    return ctx;
}

test('parseJournal: a single short-iso line splits into timestamp and message', () => {
    const ctx = makeSandbox();
    const out = ctx.parseJournal(
        '2026-09-30T16:15:28-0500 edt1 edy-rdp-guacd[1058111]: guacd[612]: ERROR: Error handling message from VNC server.',
        'guacd');
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].unit, 'guacd');
    assert.strictEqual(out[0].message,
        'edt1 edy-rdp-guacd[1058111]: guacd[612]: ERROR: Error handling message from VNC server.');
    assert.strictEqual(out[0].time, Date.parse('2026-09-30T16:15:28-0500'));
});

test('parseJournal: multiple lines, blank lines skipped, order preserved', () => {
    const ctx = makeSandbox();
    const raw = [
        '2026-09-30T16:14:38-0500 edt1 edy-rdp-guacd[1]: first',
        '',
        '2026-09-30T16:14:42-0500 edt1 edy-rdp-guacd[1]: second',
        '',
    ].join('\n');
    const out = ctx.parseJournal(raw, 'relay');
    assert.strictEqual(out.length, 2);
    assert.strictEqual(out[0].message, 'edt1 edy-rdp-guacd[1]: first');
    assert.strictEqual(out[1].message, 'edt1 edy-rdp-guacd[1]: second');
    assert.ok(out[0].time < out[1].time);
    assert.strictEqual(out[0].unit, 'relay');
});

test('parseJournal: empty/whitespace-only input returns an empty array, not a throw', () => {
    // Note: a plain deepStrictEqual(result, []) would fail here even on
    // correct behavior -- vm.createContext() gives the sandbox its own
    // realm, so an array built inside it has a DIFFERENT Array.prototype
    // than a literal [] written in this test file, and deepStrictEqual
    // checks prototype identity. Checking .length sidesteps that entirely.
    const ctx = makeSandbox();
    assert.strictEqual(ctx.parseJournal('', 'relay').length, 0);
    assert.strictEqual(ctx.parseJournal(null, 'relay').length, 0);
    assert.strictEqual(ctx.parseJournal(undefined, 'relay').length, 0);
});

test('parseJournal: a line with no whitespace at all (unparseable timestamp) does not throw, keeps the whole line as the message', () => {
    const ctx = makeSandbox();
    const out = ctx.parseJournal('not-a-real-journal-line', 'guacd');
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].time, 0);
    // no whitespace at all means the regex's \s+ never matches at all, so the
    // whole-line fallback applies: the ENTIRE line becomes the message rather
    // than being silently dropped -- a readable, unsplit message beats losing
    // the line altogether.
    assert.strictEqual(out[0].message, 'not-a-real-journal-line');
});

test('parseJournal: a message containing multiple spaces is kept whole, not re-split', () => {
    const ctx = makeSandbox();
    const out = ctx.parseJournal(
        '2026-09-30T16:15:28-0500 CLOSE after 50.3s session=f661c7b3 up={key:170} down={clipboard:1}',
        'relay');
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].message,
        'CLOSE after 50.3s session=f661c7b3 up={key:170} down={clipboard:1}');
});

test('parseJournal: a multi-line journal entry (e.g. a traceback) merges into one row, not fragmenting into bogus rows', () => {
    const ctx = makeSandbox();
    const raw = [
        '2026-09-30T16:15:28-0500 edt1 edy-rdp-relay[1]: Traceback (most recent call last):',
        '  File "relay.py", line 42, in handle',
        '    raise ValueError("oops")',
        'ValueError: oops',
        '2026-09-30T16:15:29-0500 edt1 edy-rdp-relay[1]: next entry',
    ].join('\n');
    const out = ctx.parseJournal(raw, 'relay');
    assert.strictEqual(out.length, 2);
    assert.strictEqual(out[0].message,
        'edt1 edy-rdp-relay[1]: Traceback (most recent call last):\n' +
        '  File "relay.py", line 42, in handle\n' +
        '    raise ValueError("oops")\n' +
        'ValueError: oops');
    assert.strictEqual(out[0].time, Date.parse('2026-09-30T16:15:28-0500'));
    assert.strictEqual(out[1].message, 'edt1 edy-rdp-relay[1]: next entry');
});

test('parseJournal: CRLF-terminated lines still parse their timestamp correctly', () => {
    const ctx = makeSandbox();
    const raw = '2026-09-30T16:15:28-0500 edt1 edy-rdp-relay[1]: hello\r\n' +
                '2026-09-30T16:15:29-0500 edt1 edy-rdp-relay[1]: world\r\n';
    const out = ctx.parseJournal(raw, 'relay');
    assert.strictEqual(out.length, 2);
    assert.strictEqual(out[0].message, 'edt1 edy-rdp-relay[1]: hello');
    assert.strictEqual(out[0].time, Date.parse('2026-09-30T16:15:28-0500'));
    assert.strictEqual(out[1].message, 'edt1 edy-rdp-relay[1]: world');
});
