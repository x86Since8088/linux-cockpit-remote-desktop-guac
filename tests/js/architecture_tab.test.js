#!/usr/bin/env node
// The Architecture tab is static markup plus a TAB_NAMES entry. This checks
// the page actually ships the tab, that selectTab knows the name, and that the
// login-screen notes still say a dropped connection reattaches to the existing
// desktop rather than starting a new login.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const js = fs.readFileSync(path.join(root, 'guac-rdp.js'), 'utf8');
const css = fs.readFileSync(path.join(root, 'guac-rdp.css'), 'utf8');

test('Architecture tab is wired into the page and the tab list', () => {
    assert.match(html, /id="tab-architecture"/);
    assert.match(html, /id="panel-architecture"/);
    assert.match(html, /id="panel-architecture" class="panel" hidden/);
    assert.match(js, /TAB_NAMES = \[[^\]]* "architecture"\]/);
    assert.match(js, /\$\("tab-architecture"\)\.addEventListener\("click"/);
    assert.match(css, /\.arch h2/);
});

test('Architecture tab describes the doors and the existing-desktop reattach', () => {
    const start = html.indexOf('id="panel-architecture"');
    const end = html.indexOf('<footer', start);
    assert.ok(start !== -1 && end > start);
    const panel = html.slice(start, end);
    assert.match(panel, /127\.0\.0\.1:3390/);
    assert.match(panel, /127\.0\.0\.1:3389/);
    assert.match(panel, /33000 \+ \(uid − 1000\)/);
    assert.match(panel, /34000 \+ \(uid − 1000\)/);
    assert.match(panel, /SO_PEERCRED/);
    assert.match(panel, /xfreerdp3/);
    assert.match(panel, /desktop you already signed into/);
    assert.match(panel, /session stays logged in/);
    assert.match(panel, /Opening this tab leaves a live connection/);
});
