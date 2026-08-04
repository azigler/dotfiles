// lib/doc_content.mjs — pure readers over a Docs `documents.get` payload.
//
// A SEPARATE MODULE ON PURPOSE: render_styled_blocks.mjs is a script, not a
// library — it parses `process.argv[2]` and awaits network calls at module
// scope, so importing it from a test performs a render. Anything that needs a
// unit test therefore lives here, where the import has no side effects.
//
// And in `lib/` ON PURPOSE: `.gitignore` ignores `agents/skills/gdoc/*.mjs`
// (ad-hoc scratch scripts) with a single negation for render_styled_blocks.mjs,
// so a new top-level .mjs here would be silently untracked — absent from a fresh
// clone, with the renderer importing it. Subdirectories are not matched.
/**
 * The structural elements of the segment a render targets.
 *
 * @param {object} doc                a `documents.get` response body
 * @param {{tabId?: string}} [scope]  `{}` (or no tabId) means the body path
 * @returns {Array<object>}           structural elements; `[]` when absent
 */
export function contentOfDoc(doc, scope = {}) {
  const tabs = doc?.tabs ?? [];
  if (!scope?.tabId) {
    // `includeTabsContent: true` relocates ALL content into `tabs[]` and
    // leaves `doc.body` unpopulated — so reading only `doc.body.content` here
    // reported every body-path render as empty (dotfiles-aoyz): a false EMPTY
    // failure on the read-back, and a silently no-op `clear` that made a
    // re-render prepend instead of replace.
    //
    // The write side is the invariant: a body-path request carries no `tabId`
    // in `location`/`range`, which Docs resolves to the FIRST TAB. The read
    // must resolve to the first tab too. `doc.body` stays first so an
    // `includeTabsContent: false` caller keeps working.
    return doc?.body?.content ?? tabs[0]?.documentTab?.body?.content ?? [];
  }
  // A named tabId that does not exist returns `[]` DELIBERATELY — no fallback
  // to tab 0. The caller's guard then fails loudly instead of quietly reading
  // (or clearing) the wrong tab.
  const tab = tabs.find((x) => x?.tabProperties?.tabId === scope.tabId);
  return tab?.documentTab?.body?.content ?? [];
}
