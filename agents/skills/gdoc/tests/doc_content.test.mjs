// Unit tests for contentOfDoc — the segment resolver the renderer's read-back
// and `clear` both depend on.
// Run from the skill dir: node --test tests/doc_content.test.mjs
// (`node --test tests/` resolves the DIRECTORY as a module and errors.)
//
// The regression case is `body path (no tabId)`: `documents.get` with
// `includeTabsContent: true` leaves `doc.body` unpopulated, so the previous
// `doc.body?.content ?? []` returned [] on every body-path render — a false
// EMPTY read-back and a `clear` that silently no-oped (dotfiles-aoyz).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { contentOfDoc } from '../lib/doc_content.mjs';

const para = (t) => ({ endIndex: t.length + 1, paragraph: { elements: [{ textRun: { content: t } }] } });

// What documents.get({ includeTabsContent: true }) actually returns: no
// top-level body at all, every tab's content under tabs[].documentTab.body.
const tabbedDoc = {
  tabs: [
    { tabProperties: { tabId: 't.first', title: 'Tab 1' }, documentTab: { body: { content: [para('first tab text')] } } },
    { tabProperties: { tabId: 't.second', title: 'Tab 2' }, documentTab: { body: { content: [para('second tab text')] } } },
  ],
};

test('body path (no tabId) resolves to tab 0 under includeTabsContent, where doc.body is absent', () => {
  const content = contentOfDoc(tabbedDoc, {});
  assert.equal(content.length, 1, 'body path must not read as empty — this is the dotfiles-aoyz regression');
  assert.equal(content[0].paragraph.elements[0].textRun.content, 'first tab text');
});

test('body path with an explicitly empty scope object argument omitted entirely', () => {
  assert.deepEqual(contentOfDoc(tabbedDoc), contentOfDoc(tabbedDoc, {}));
});

test('explicit tabId returns that tab, not tab 0', () => {
  const content = contentOfDoc(tabbedDoc, { tabId: 't.second' });
  assert.equal(content[0].paragraph.elements[0].textRun.content, 'second tab text');
});

test('explicit tabId that does not exist returns [] — no silent fallback to tab 0', () => {
  assert.deepEqual(contentOfDoc(tabbedDoc, { tabId: 't.nope' }), []);
});

test('a genuinely empty first tab returns [] so the EMPTY guard can still fire', () => {
  const emptyFirstTab = {
    tabs: [{ tabProperties: { tabId: 't.first' }, documentTab: { body: { content: [] } } }],
  };
  assert.deepEqual(contentOfDoc(emptyFirstTab, {}), []);
  // …and the renderer's read-back sum over that content is 0, which is what
  // makes `if (!back) fail(...)` meaningful rather than permanently green.
  const chars = contentOfDoc(emptyFirstTab, {}).reduce(
    (n, el) => n + (el.paragraph?.elements ?? []).reduce((m, e) => m + (e.textRun?.content ?? '').length, 0),
    0,
  );
  assert.equal(chars, 0);
});

test('legacy shape: doc.body.content present (includeTabsContent false) is still returned', () => {
  const legacy = { body: { content: [para('legacy body text')] } };
  const content = contentOfDoc(legacy, {});
  assert.equal(content[0].paragraph.elements[0].textRun.content, 'legacy body text');
});

test('doc.body wins over tabs[0] when both are populated', () => {
  const both = { body: { content: [para('body wins')] }, ...tabbedDoc };
  assert.equal(contentOfDoc(both, {}).length, 1);
  assert.equal(contentOfDoc(both, {})[0].paragraph.elements[0].textRun.content, 'body wins');
});

test('a doc with neither body nor tabs returns [] rather than throwing', () => {
  assert.deepEqual(contentOfDoc({}, {}), []);
  assert.deepEqual(contentOfDoc(undefined, {}), []);
  assert.deepEqual(contentOfDoc({ tabs: [] }, {}), []);
});
