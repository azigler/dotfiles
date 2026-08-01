import { readFileSync } from 'fs';
import { google } from 'googleapis';

const key = JSON.parse(readFileSync(process.env.HOME + '/linearb/agent-factory/agents/lb-agent-product/.google-service-account.json', 'utf-8'));
const auth = new google.auth.GoogleAuth({
  credentials: key,
  scopes: ['https://www.googleapis.com/auth/documents', 'https://www.googleapis.com/auth/drive'],
});
const docs = google.docs({ version: 'v1', auth });
const drive = google.drive({ version: 'v3', auth });

const ID = '1uiStzU698ivaPBHQC8s1j8TboyGd1kP0wcHoHM0CVnw';
const TAB = 't.ho9jxnpkvaoy';

const OLD = "What I didn't expect was how much the trip would change how I think about cost. I walked in thinking about tokens as a line on an invoice. Two days of watching people optimize tokens per dollar, tokens per second, and tokens per watt showed me how much engineering sits under that number for the people who own the machines, and how little of it the rest of us ever see.";

const NEW = "The trip changed how I think about cost. I walked in seeing a token as a line on an invoice. I walked out seeing it as an engineered output, priced by how well the machines are tuned, how many tokens per second they serve, and how much power they burn doing it. The people who own the hardware work all three of those like a physical system. The rest of us only ever see the bill.";

const d = await docs.documents.get({
  documentId: ID, includeTabsContent: true, suggestionsViewMode: 'PREVIEW_WITHOUT_SUGGESTIONS',
});
const tab = (d.data.tabs || []).find((t) => t.tabProperties.tabId === TAB);
let s = '';
for (const el of tab.documentTab.body.content || []) {
  if (el.paragraph) for (const pe of el.paragraph.elements || []) if (pe.textRun) s += pe.textRun.content;
}

if (!s.includes(OLD)) {
  console.log('TARGET NOT FOUND. Nearest context:');
  const i = s.indexOf('walked in');
  console.log(JSON.stringify(s.slice(Math.max(0, i - 200), i + 400)));
  process.exit(1);
}

const res = await docs.documents.batchUpdate({
  documentId: ID,
  requestBody: {
    requests: [{
      replaceAllText: {
        containsText: { text: OLD, matchCase: true },
        replaceText: NEW,
        tabsCriteria: { tabIds: [TAB] },
      },
    }],
  },
});
const n = (res.data.replies || []).reduce((x, r) => x + ((r.replaceAllText && r.replaceAllText.occurrencesChanged) || 0), 0);
console.log('paragraph replaced, occurrences=' + n);

const cl = await drive.comments.list({
  fileId: ID, pageSize: 100,
  fields: 'comments(id,resolved,author/displayName,content)',
});
const target = (cl.data.comments || []).find((c) => !c.resolved && /run on|run-on/i.test(c.content || ''));
if (target) {
  const reply = [
    'Fixed. You were right on both counts: it was a run-on, and "that number" had no antecedent.',
    'The token is now named as the thing being priced, the three factors read as a clean list',
    'instead of a pile-up, and the paragraph lands on "the rest of us only ever see the bill" so it',
    'sets up the two-sided equation the piece is built on. Also killed a repeated "Two days" that',
    'was running back-to-back with the previous paragraph.',
  ].join(' ');
  await drive.replies.create({
    fileId: ID, commentId: target.id,
    requestBody: { content: reply, action: 'resolve' },
  });
  console.log('resolved run-on comment ' + target.id);
} else {
  console.log('run-on comment not found (already resolved?)');
}
