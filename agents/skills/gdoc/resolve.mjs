import { readFileSync } from 'fs';
import { google } from 'googleapis';

const key = JSON.parse(readFileSync(process.env.HOME + '/linearb/agent-factory/agents/lb-agent-product/.google-service-account.json', 'utf-8'));
const auth = new google.auth.GoogleAuth({
  credentials: key,
  scopes: ['https://www.googleapis.com/auth/drive'],
});
const drive = google.drive({ version: 'v3', auth });
const ID = '1uiStzU698ivaPBHQC8s1j8TboyGd1kP0wcHoHM0CVnw';

const cl = await drive.comments.list({
  fileId: ID, pageSize: 100,
  fields: 'comments(id,resolved,author/displayName,content)',
});
const target = (cl.data.comments || []).find((c) => !c.resolved && /run on|run-on/i.test(c.content || ''));
if (!target) { console.log('no matching open comment'); process.exit(0); }
console.log('target=' + target.id + ' author=' + (target.author && target.author.displayName));

const reply = 'Fixed. You were right on both counts: it was a run-on, and "that number" had no antecedent. The token is now named as the thing being priced, the three factors read as a clean list instead of a pile-up, and the paragraph lands on "the rest of us only ever see the bill" so it sets up the two-sided equation. Also killed a repeated "Two days" that was running back-to-back with the previous paragraph.';

try {
  const r = await drive.replies.create({
    fileId: ID, commentId: target.id,
    fields: 'id,action',
    requestBody: { content: reply, action: 'resolve' },
  });
  console.log('OK resolved, reply=' + r.data.id + ' action=' + r.data.action);
} catch (e) {
  console.log('RESOLVE FAILED: ' + (e.code || '') + ' ' + e.message);
  if (e.errors) console.log(JSON.stringify(e.errors));
  // fall back: post the reply without the resolve action so the note is at least recorded
  try {
    const r2 = await drive.replies.create({
      fileId: ID, commentId: target.id, fields: 'id',
      requestBody: { content: reply },
    });
    console.log('posted reply without resolve: ' + r2.data.id);
  } catch (e2) {
    console.log('REPLY ALSO FAILED: ' + (e2.code || '') + ' ' + e2.message);
  }
}
