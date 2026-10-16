#!/usr/bin/env node
// Structural guard for ../../index.html: every tab panel must be a TOP-LEVEL
// <section>. A panel nested inside another one is hidden whenever its parent
// is, so the tab renders blank -- and no behavioural test notices, because the
// markup still parses and every handler still binds.
//
// Added for PR #42 review r1: the hand-resolved merge of the Dependencies and
// Update panels left panel-deps unclosed, nesting Update, Self Tests and
// Architecture inside it. run_tests.sh and every other JS test still passed.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const HTML = fs.readFileSync(path.join(__dirname, '..', '..', 'index.html'), 'utf8');

function sections(html) {
  const re = /<section\b([^>]*)>|<\/section\s*>/gi;
  const out = [];
  let depth = 0, m;
  while ((m = re.exec(html)) !== null) {
    if (m[1] !== undefined) {
      const id = (/\bid="([^"]+)"/.exec(m[1]) || [])[1] || null;
      const panel = /\bclass="[^"]*\bpanel\b/.test(m[1]);
      out.push({ id, panel, depth });
      depth++;
    } else {
      depth--;
      assert.ok(depth >= 0, 'a </section> closes more sections than were opened');
    }
  }
  return { list: out, finalDepth: depth };
}

test('every <section> is closed', () => {
  assert.strictEqual(sections(HTML).finalDepth, 0,
    'unbalanced <section> tags in index.html (an unclosed panel nests every later panel inside it)');
});

test('every tab panel is a top-level section, never nested in another panel', () => {
  for (const s of sections(HTML).list.filter(s => s.panel)) {
    assert.strictEqual(s.depth, 0, `panel ${s.id} is nested ${s.depth} level(s) deep`);
  }
});

test('every tab button points at an existing top-level panel', () => {
  const panels = new Set(sections(HTML).list.filter(s => s.panel && s.depth === 0).map(s => s.id));
  const targets = [...HTML.matchAll(/class="tab"[^>]*\bdata-panel="([^"]+)"/g)].map(m => m[1]);
  assert.ok(targets.length > 0, 'found no tab buttons');
  for (const t of targets) assert.ok(panels.has(t), `tab targets ${t}, which is not a top-level panel`);
});
