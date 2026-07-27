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
// TRANSPORT — local service-account key OR the fleet proxy
// -------------------------------------------------------
// The styling logic below emits raw Docs `batchUpdate` requests, so WHERE those
// requests are posted is a transport detail. Two transports exist:
//
//   GDOC_TRANSPORT=auto (default) — probe the fleet proxy, fall back to direct
//   GDOC_TRANSPORT=proxy          — proxy only; a dead proxy is a hard failure
//   GDOC_TRANSPORT=direct         — googleapis + $SA_KEY, exactly as before
//
//   FLEET_URL        default http://localhost:7100 (matches every DI skill)
//   FLEET_API_TOKEN  bearer for the proxy (required for the proxy transport)
//   GDOC_AGENT_NAME  X-Agent-Name on writes, default zig-agent-copy
//   SA_KEY           service-account key path (required for direct only)
//
// This matters because the DI pulse ticks are moving to `marketing-vps`, a box
// that deliberately holds NO credentials and reaches this machine's fleet proxy
// over a reverse SSH tunnel — so `http://localhost:7100` is a valid address in
// both places, while `$SA_KEY` exists in only one. Same convention as
// `dashboard-dev-interrupted/scripts/gdoc_proxy.mjs`.
//
// Loudness contract: every failure prints the HTTP status + body on stderr and
// exits non-zero. Diagnostics go to stderr; stdout still carries only the
// `STYLED_TAB=<url>` line + the one-line summary that callers parse.
//
// Usage:
//   SA_KEY=/path/sa.json node render_styled_blocks.mjs spec.json     # direct
//   GDOC_TRANSPORT=proxy node render_styled_blocks.mjs spec.json     # no creds
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

// ---------------------------------------------------------------------------
// Config + loudness
// ---------------------------------------------------------------------------

const MODE = process.env.GDOC_TRANSPORT || 'auto';
const FLEET_URL = (process.env.FLEET_URL || 'http://localhost:7100').replace(/\/+$/, '');
const AGENT_NAME = process.env.GDOC_AGENT_NAME || 'zig-agent-copy';
const PROBE_TIMEOUT_MS = Number(process.env.GDOC_PROBE_TIMEOUT_MS || 2500);

const warn = (msg) => process.stderr.write(`render_styled_blocks: ${msg}\n`);
function fail(msg, code = 1) {
  process.stderr.write(`render_styled_blocks: ERROR: ${msg}\n`);
  process.exit(code);
}

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

// ---------------------------------------------------------------------------
// Transports
//
// Both expose the same four operations the renderer needs:
//   listTabs()          -> [{ tabId, title }]
//   addTab(title)       -> tabId
//   segmentEnd(scope)   -> the end index of the target segment (body or tab)
//   batch(requests)     -> post raw Docs requests
//   readBackChars(scope)-> chars currently in the target (post-write proof)
// ---------------------------------------------------------------------------

async function probeProxy() {
  if (!process.env.FLEET_API_TOKEN) {
    return { ok: false, reason: 'FLEET_API_TOKEN is not set in the environment' };
  }
  try {
    const res = await fetch(`${FLEET_URL}/api/health`, { signal: AbortSignal.timeout(PROBE_TIMEOUT_MS) });
    if (!res.ok) return { ok: false, reason: `${FLEET_URL}/api/health returned ${res.status}` };
    return { ok: true };
  } catch (err) {
    return { ok: false, reason: `${FLEET_URL} unreachable (${err.message})` };
  }
}

async function pickTransportName() {
  if (MODE === 'direct') return 'direct';
  if (MODE !== 'auto' && MODE !== 'proxy') {
    fail(`GDOC_TRANSPORT must be one of auto|proxy|direct (got "${MODE}")`);
  }
  const p = await probeProxy();
  if (MODE === 'proxy') {
    if (!p.ok) {
      fail(
        `GDOC_TRANSPORT=proxy but the fleet proxy is not usable: ${p.reason}. ` +
          'Refusing to fall back to the local service-account key — that would hide the failure this mode exists to catch.',
      );
    }
    return 'proxy';
  }
  if (p.ok) return 'proxy';
  warn(`proxy unusable (${p.reason}) — falling back to the direct service-account path`);
  return 'direct';
}

// -- proxy ------------------------------------------------------------------

// Comfortably past Google's ~1.02M-character document ceiling, and small enough
// to stay a plain int32 (the API rejects absurd magnitudes differently).
const PROBE_INDEX = 2_000_000;

function makeProxyTransport() {
  const call = async (path, { method = 'GET', body, tolerate400 = false } = {}) => {
    const headers = { Authorization: `Bearer ${process.env.FLEET_API_TOKEN}` };
    if (method !== 'GET') {
      headers['X-Agent-Name'] = AGENT_NAME;
      headers['Content-Type'] = 'application/json';
    }
    let res;
    try {
      res = await fetch(`${FLEET_URL}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (err) {
      return fail(`${method} ${path} failed to connect: ${err.message}`);
    }
    const text = await res.text();
    if (!res.ok) {
      if (tolerate400) return { httpError: res.status, text };
      return fail(`${method} ${path} -> HTTP ${res.status}: ${text.slice(0, 2000)}`);
    }
    try {
      const json = JSON.parse(text);
      return json.data === undefined ? json : json.data;
    } catch {
      return fail(`${method} ${path} -> HTTP ${res.status} but the body is not JSON: ${text.slice(0, 500)}`);
    }
  };

  return {
    name: 'proxy',

    async listTabs(docId) {
      const tabs = await call(`/api/gdoc/docs/${docId}/tabs`);
      if (!Array.isArray(tabs)) fail(`tab listing for ${docId} is not an array: ${JSON.stringify(tabs).slice(0, 300)}`);
      if (tabs.length === 0) {
        fail(
          `tab listing for ${docId} came back EMPTY. Every Google Doc has at least one tab, ` +
            'so this is an access or API failure, not "no tabs".',
          3,
        );
      }
      return tabs;
    },

    async addTab(docId, title) {
      const created = await call(`/api/gdoc/docs/${docId}/tabs`, { method: 'POST', body: { title } });
      if (!created?.tabId) fail(`creating tab "${title}" on ${docId} returned no tabId`);
      return created.tabId;
    },

    /**
     * The fleet proxy has no raw `documents.get` route (tracked as bd-2ntm), so
     * the segment's end index — which `deleteContentRange` needs — is recovered
     * from the Docs API's own out-of-bounds error, which names it:
     *
     *   Invalid requests[0].insertText: Index 2000000 must be less than the end
     *   index of the referenced segment, 2.
     *
     * The probe is non-destructive by construction: an insert at an index past
     * the segment end can never apply, and Docs `batchUpdate` is atomic, so the
     * rejected batch changes nothing. If the message shape ever drifts this
     * fails LOUDLY rather than guessing an index and deleting the wrong range.
     */
    async segmentEnd(docId, scope) {
      const r = await call(`/api/gdoc/docs/${docId}/batch`, {
        method: 'POST',
        tolerate400: true,
        body: { requests: [{ insertText: { location: { index: PROBE_INDEX, ...scope }, text: 'x' } }] },
      });
      if (!r?.httpError) {
        fail(
          `the segment-end probe was ACCEPTED (inserting at index ${PROBE_INDEX} should be impossible). ` +
            'Refusing to continue — the document may now hold a stray "x".',
        );
      }
      const m = /end index of the referenced segment,\s*(\d+)/.exec(r.text);
      if (!m) {
        fail(
          `could not recover the segment end index from the proxy's error response. ` +
            `Expected Google's "end index of the referenced segment, <n>" message; got HTTP ${r.httpError}: ${r.text.slice(0, 800)}`,
        );
      }
      return Number(m[1]);
    },

    async batch(docId, requests) {
      if (requests.length === 0) return;
      await call(`/api/gdoc/docs/${docId}/batch`, { method: 'POST', body: { requests } });
    },

    async readBackChars(docId, scope) {
      const q = scope.tabId ? `?tabId=${encodeURIComponent(scope.tabId)}` : '';
      const data = await call(`/api/gdoc/docs/${docId}${q}`);
      return (data?.markdown ?? '').length;
    },
  };
}

// -- direct (local service-account key) -------------------------------------

async function makeDirectTransport() {
  if (!process.env.SA_KEY) {
    fail(
      'the direct transport needs $SA_KEY (a Google service-account key path). ' +
        'Set it, or run where the fleet proxy is reachable (GDOC_TRANSPORT=proxy).',
    );
  }
  let google;
  try {
    ({ google } = await import('googleapis'));
  } catch (err) {
    return fail(`the direct transport needs the googleapis package: ${err.message}`);
  }
  const key = JSON.parse(readFileSync(process.env.SA_KEY, 'utf-8'));
  const auth = new google.auth.GoogleAuth({ credentials: key, scopes: ['https://www.googleapis.com/auth/documents'] });
  const docs = google.docs({ version: 'v1', auth });

  const getDoc = async (docId) =>
    (await docs.documents.get({ documentId: docId, includeTabsContent: true })).data;

  const contentOf = (doc, scope) => {
    if (!scope.tabId) return doc.body?.content ?? [];
    const tab = (doc.tabs ?? []).find((x) => x.tabProperties?.tabId === scope.tabId);
    return tab?.documentTab?.body?.content ?? [];
  };

  return {
    name: 'direct',

    async listTabs(docId) {
      const doc = await getDoc(docId);
      return (doc.tabs ?? []).map((t) => ({ tabId: t.tabProperties?.tabId, title: t.tabProperties?.title }));
    },

    async addTab(docId, title) {
      await docs.documents.batchUpdate({
        documentId: docId,
        requestBody: { requests: [{ addDocumentTab: { tabProperties: { title } } }] },
      });
      const doc = await getDoc(docId);
      const tab = (doc.tabs ?? []).find((x) => x.tabProperties?.title === title);
      if (!tab) fail(`creating tab "${title}" on ${docId} returned no tabId`);
      return tab.tabProperties.tabId;
    },

    async segmentEnd(docId, scope) {
      const content = contentOf(await getDoc(docId), scope);
      return content.reduce((m, e) => Math.max(m, e.endIndex ?? 0), 1);
    },

    async batch(docId, requests) {
      if (requests.length === 0) return;
      await docs.documents.batchUpdate({ documentId: docId, requestBody: { requests } });
    },

    async readBackChars(docId, scope) {
      const content = contentOf(await getDoc(docId), scope);
      let n = 0;
      for (const el of content) {
        for (const e of el.paragraph?.elements ?? []) n += (e.textRun?.content ?? '').length;
      }
      return n;
    },
  };
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

const transportName = await pickTransportName();
warn(`transport=${transportName}${transportName === 'proxy' ? ` (${FLEET_URL})` : ''}`);
const T = transportName === 'proxy' ? makeProxyTransport() : await makeDirectTransport();

const docId = spec.docId;
if (!docId) fail('spec.docId is required');

let tabId = spec.tabId || null;
if (!tabId && spec.tabTitle) {
  const tabs = await T.listTabs(docId);
  const existing = tabs.find((t) => t.title === spec.tabTitle);
  tabId = existing ? existing.tabId : await T.addTab(docId, spec.tabTitle);
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

const end = await T.segmentEnd(docId, scope);
warn(`segment end index=${end} (clear=${spec.clear ?? true})`);
if ((spec.clear ?? true) && end > 2) {
  await T.batch(docId, [{ deleteContentRange: { range: { startIndex: 1, endIndex: end - 1, ...scope } } }]);
}
await T.batch(docId, [{ insertText: { location: { index: 1, ...scope }, text } }]);
await T.batch(docId, [...paraReqs, ...textReqs, ...bulletReqs]);

// Proof, not trust: a write that Google accepts but that leaves the target
// empty is the failure mode this whole path exists to avoid.
if (text.trim()) {
  const back = await T.readBackChars(docId, scope);
  if (!back) fail('the write was accepted but the target is EMPTY on re-read — nothing landed', 4);
  warn(`verified: sent ${text.length} chars, read back ${back}`);
}

console.log('STYLED_TAB=https://docs.google.com/document/d/' + docId + (tabId ? '/edit?tab=' + tabId : '/edit'));
console.log(`theme=${theme.name} blocks=${spec.blocks.length} chars=${text.length} textReqs=${textReqs.length} bulletGroups=${bulletReqs.length}`);
