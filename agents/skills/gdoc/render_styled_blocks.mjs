// render_styled_blocks.mjs — drop richly-formatted, THEME-styled content into a
// Google Doc tab (or the doc body) with full control over color/size/weight,
// bullets, hyperlinks, and horizontal rules.
//
// This is the "design-system" path. Content declares blocks by ROLE (kicker,
// title, label, body, bullet, itemTitle, rule, ...); a THEME (themes/<name>.json)
// maps every role to a concrete style + palette. Swap the theme, keep the
// content, get a new look. It goes beyond `gdoc.sh write <tabId>` (standard
// Arial/heading contract) by giving each role its own palette color + size.
//
// Technique: INSERT-ALL-THEN-STYLE. Insert the plain text once, then batch
// updateTextStyle / updateParagraphStyle / createParagraphBullets over computed
// char ranges. NEVER hand-write markdown via a bare insertText — it renders as a
// literal wall of text (`**`, `#`, colons don't stand out).
//
// Usage:
//   SA_KEY=/path/sa.json bun render_styled_blocks.mjs spec.json
// spec.json:
//   {
//     "docId": "1AbC...",
//     "tabId": "t.xxxx",              // OR "tabTitle": "Digest 2026-07-15" (find-or-create)
//     "theme": "editorial",           // themes/editorial.json  (or inline "themeDef": {...})
//     "clear": true,                  // wipe the tab first (default true)
//     "blocks": [
//       { "role": "kicker",   "text": "DEV INTERRUPTED  ·  RESEARCH DIGEST" },
//       { "role": "title",    "text": "Research Digest" },
//       { "role": "sectionRule" },
//       { "role": "itemTitle","runs": [ {"role":"itemNumber","text":"1.  "}, {"text":"AI Writes Faster..."} ] },
//       { "role": "link",     "text": "https://arxiv.org/abs/2607.01904", "link": "https://arxiv.org/abs/2607.01904" },
//       { "role": "label",    "text": "Summary" },
//       { "role": "bullet",   "text": "A quantitative case study ..." },
//       { "role": "body",     "text": "The strongest data yet ..." }
//     ]
//   }
// A block may override any role field inline (size/color/bold/italic/underline/link/upper/sa/sb).
// A run may carry its own "role" plus inline overrides. color = palette key OR raw hex.
// Note: Docs indices are UTF-16 code units; JS string .length matches for BMP text.
// Avoid astral chars (emoji) inside styled runs or offsets drift.
import { readFileSync } from 'fs';
import { google } from 'googleapis';

const spec = JSON.parse(readFileSync(process.argv[2], 'utf-8'));
const theme = spec.themeDef
  ? spec.themeDef
  : JSON.parse(readFileSync(new URL(`./themes/${spec.theme || 'editorial'}.json`, import.meta.url), 'utf-8'));
const PAL = theme.palette || {};
const hex = (h) => ({ red: ((h >> 16) & 255) / 255, green: ((h >> 8) & 255) / 255, blue: (h & 255) / 255 });
const rgb = (c) => hex(parseInt(PAL[c] || c, 16));
const PT = (m) => ({ magnitude: m, unit: 'PT' });
const role = (r) => (r ? theme.roles?.[r] || {} : {});

// Resolve a block into { paragraph:{sa,sb,bullet,rule}, runs:[{t,size,bold,italic,underline,color,link}] }
function resolveBlock(blk) {
  const R = role(blk.role);
  const para = {
    sa: blk.sa ?? R.sa ?? 0,
    sb: blk.sb ?? R.sb ?? 6,
    bullet: blk.bullet ?? R.bullet ?? false,
    rule: blk.rule ?? R.rule ?? null,
  };
  if (para.rule) return { para, runs: [{ t: '' }] };
  const baseRun = { size: R.size, bold: R.bold, italic: R.italic, underline: R.underline, color: R.color, upper: R.upper };
  const mk = (src, ownRole) => {
    const RR = ownRole ? role(ownRole) : {};
    const s = { ...baseRun, ...RR };
    for (const k of ['size', 'bold', 'italic', 'underline', 'color', 'link', 'upper']) if (src[k] !== undefined) s[k] = src[k];
    let t = src.text ?? '';
    if (s.upper) t = t.toUpperCase();
    return { t, size: s.size, bold: s.bold, italic: s.italic, underline: s.underline, color: s.color, link: s.link };
  };
  const runs = blk.runs ? blk.runs.map((r) => mk(r, r.role)) : [mk(blk)];
  return { para, runs };
}

const key = JSON.parse(readFileSync(process.env.SA_KEY, 'utf-8'));
const auth = new google.auth.GoogleAuth({ credentials: key, scopes: ['https://www.googleapis.com/auth/documents'] });
const docs = google.docs({ version: 'v1', auth });
const docId = spec.docId;

let tabId = spec.tabId || null;
let doc = (await docs.documents.get({ documentId: docId, includeTabsContent: true })).data;
const byTitle = (t) => (doc.tabs ?? []).find((x) => x.tabProperties?.title === t);
if (!tabId && spec.tabTitle) {
  let tab = byTitle(spec.tabTitle);
  if (!tab) {
    await docs.documents.batchUpdate({ documentId: docId, requestBody: { requests: [{ addDocumentTab: { tabProperties: { title: spec.tabTitle } } }] } });
    doc = (await docs.documents.get({ documentId: docId, includeTabsContent: true })).data;
    tab = byTitle(spec.tabTitle);
  }
  tabId = tab.tabProperties.tabId;
}
const scope = tabId ? { tabId } : {};

let text = '', idx = 1;
const textReqs = [], paraReqs = [], bulletRanges = [];
let bStart = null;
const flush = (end) => { if (bStart != null) { bulletRanges.push([bStart, end]); bStart = null; } };

for (const blk of spec.blocks) {
  const { para, runs } = resolveBlock(blk);
  const pStart = idx;
  for (const r of runs) {
    const rStart = idx;
    text += r.t; idx += r.t.length;
    if (r.t.length) {
      const st = {}, f = [];
      if (r.color) { st.foregroundColor = { color: { rgbColor: rgb(r.color) } }; f.push('foregroundColor'); }
      if (r.bold) { st.bold = true; f.push('bold'); }
      if (r.italic) { st.italic = true; f.push('italic'); }
      if (r.underline) { st.underline = true; f.push('underline'); }
      if (r.size) { st.fontSize = PT(r.size); f.push('fontSize'); }
      if (theme.font) { st.weightedFontFamily = { fontFamily: theme.font }; f.push('weightedFontFamily'); }
      if (r.link) { st.link = { url: r.link }; f.push('link'); }
      if (f.length) textReqs.push({ updateTextStyle: { range: { startIndex: rStart, endIndex: idx, ...scope }, textStyle: st, fields: f.join(',') } });
    }
  }
  text += '\n'; idx += 1;
  const ps = { namedStyleType: 'NORMAL_TEXT', spaceAbove: PT(para.sa), spaceBelow: PT(para.sb) };
  const pf = ['namedStyleType', 'spaceAbove', 'spaceBelow'];
  if (para.rule) { ps.borderBottom = { width: PT(1), padding: PT(2), dashStyle: 'SOLID', color: { color: { rgbColor: rgb(para.rule) } } }; pf.push('borderBottom'); }
  paraReqs.push({ updateParagraphStyle: { range: { startIndex: pStart, endIndex: idx, ...scope }, paragraphStyle: ps, fields: pf.join(',') } });
  if (para.bullet) { if (bStart == null) bStart = pStart; } else flush(pStart);
}
flush(idx);
const bulletReqs = bulletRanges.map(([s, e]) => ({ createParagraphBullets: { range: { startIndex: s, endIndex: e, ...scope }, bulletPreset: 'BULLET_DISC_CIRCLE_SQUARE' } }));

const tab = tabId ? (doc.tabs ?? []).find((x) => x.tabProperties?.tabId === tabId) : null;
const content = (tab ? tab.documentTab?.body?.content : doc.body?.content) ?? [];
const end = content.reduce((m, e) => Math.max(m, e.endIndex ?? 0), 1);
if ((spec.clear ?? true) && end > 2) await docs.documents.batchUpdate({ documentId: docId, requestBody: { requests: [{ deleteContentRange: { range: { startIndex: 1, endIndex: end - 1, ...scope } } }] } });
await docs.documents.batchUpdate({ documentId: docId, requestBody: { requests: [{ insertText: { location: { index: 1, ...scope }, text } }] } });
await docs.documents.batchUpdate({ documentId: docId, requestBody: { requests: [...paraReqs, ...textReqs, ...bulletReqs] } });

console.log('STYLED_TAB=https://docs.google.com/document/d/' + docId + (tabId ? '/edit?tab=' + tabId : '/edit'));
console.log(`theme=${theme.name} blocks=${spec.blocks.length} chars=${text.length} textReqs=${textReqs.length} bulletGroups=${bulletReqs.length}`);
