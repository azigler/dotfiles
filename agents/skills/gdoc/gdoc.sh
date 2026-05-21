#!/usr/bin/env bash
# Google Doc shim — reads/writes via lb-agent-factory Google connector
#
# Prerequisites:
#   - lb-agent-factory at ~/linearb/agent-factory/
#   - Service account key (auto-detected from standard locations)
#   - bun installed
#
# Usage:
#   gdoc.sh read <docId> [tabId]              — read doc as markdown
#   gdoc.sh tabs <docId>                      — list tabs
#   gdoc.sh write <docId> <markdown_file> [tabId] — update doc content
#   gdoc.sh comments <docId>                  — read comments
#   gdoc.sh add-tab <docId> <title>           — create a new tab

set -euo pipefail

# Auto-detect agent dir and service account key
AGENT_DIR="${GDOC_AGENT_DIR:-$HOME/linearb/agent-factory/agents/lb-agent-di}"
SA_KEY="${GDOC_SA_KEY:-}"

if [[ -z "$SA_KEY" ]]; then
  for candidate in \
    "$HOME/linearb/agent-factory/agents/lb-agent-product/.google-service-account.json" \
    "$HOME/linearb/agent-factory/agents/lb-agent-accounts/.google-service-account.json" \
    "$HOME/.config/gcloud/service-account.json"; do
    if [[ -f "$candidate" ]]; then
      SA_KEY="$candidate"
      break
    fi
  done
fi

if [[ -z "$SA_KEY" || ! -f "$SA_KEY" ]]; then
  echo "Error: No service account key found. Set GDOC_SA_KEY or place key in a standard location." >&2
  exit 1
fi

CMD="${1:?Usage: gdoc.sh <read|tabs|write|comments|add-tab> <docId> ...}"
DOC_ID="${2:?Missing docId}"

case "$CMD" in
  read)
    TAB_ID="${3:-}"
    cd "$AGENT_DIR" && bun -e "
      import { createGoogleClientFromServiceAccount } from './connectors/google/auth.ts';
      import { readDocAsMarkdown } from './connectors/google/docs/read.ts';
      import { readFileSync } from 'fs';
      const client = createGoogleClientFromServiceAccount({ serviceAccountKey: readFileSync('$SA_KEY', 'utf-8') });
      const content = await readDocAsMarkdown(client, '$DOC_ID', '$TAB_ID' || undefined);
      console.log(content.body);
    "
    ;;
  tabs)
    cd "$AGENT_DIR" && bun -e "
      import { createGoogleClientFromServiceAccount } from './connectors/google/auth.ts';
      import { listTabs } from './connectors/google/docs/read.ts';
      import { readFileSync } from 'fs';
      const client = createGoogleClientFromServiceAccount({ serviceAccountKey: readFileSync('$SA_KEY', 'utf-8') });
      const tabs = await listTabs(client, '$DOC_ID');
      console.log(JSON.stringify(tabs, null, 2));
    "
    ;;
  write)
    MD_FILE="${3:?Missing markdown file path}"
    TAB_ID="${4:-}"
    cd "$AGENT_DIR" && bun -e "
      import { createGoogleClientFromServiceAccount } from './connectors/google/auth.ts';
      import { updateDoc } from './connectors/google/docs/write.ts';
      import { readFileSync } from 'fs';
      const client = createGoogleClientFromServiceAccount({ serviceAccountKey: readFileSync('$SA_KEY', 'utf-8') });
      const markdown = readFileSync('$MD_FILE', 'utf-8');
      const result = await updateDoc(client, { docId: '$DOC_ID', markdown, tabId: '$TAB_ID' || undefined });
      console.log(JSON.stringify(result, null, 2));
    "
    ;;
  comments)
    cd "$AGENT_DIR" && bun -e "
      import { readFileSync } from 'fs';
      import { google } from 'googleapis';
      const key = JSON.parse(readFileSync('$SA_KEY', 'utf-8'));
      const auth = new google.auth.GoogleAuth({ credentials: key, scopes: ['https://www.googleapis.com/auth/drive'] });
      const drive = google.drive({ version: 'v3', auth });
      const res = await drive.comments.list({ fileId: '$DOC_ID', fields: '*', includeDeleted: false });
      console.log(JSON.stringify(res.data.comments ?? [], null, 2));
    "
    ;;
  reply)
    COMMENT_ID="${3:?Missing commentId}"
    REPLY_TEXT="${4:?Missing reply text}"
    cd "$AGENT_DIR" && bun -e "
      import { readFileSync } from 'fs';
      import { google } from 'googleapis';
      const key = JSON.parse(readFileSync('$SA_KEY', 'utf-8'));
      const auth = new google.auth.GoogleAuth({ credentials: key, scopes: ['https://www.googleapis.com/auth/drive'] });
      const drive = google.drive({ version: 'v3', auth });
      const res = await drive.replies.create({
        fileId: '$DOC_ID',
        commentId: '$COMMENT_ID',
        fields: 'id,content,author',
        requestBody: { content: $(printf '%s' "$REPLY_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))') },
      });
      console.log(JSON.stringify({ replyId: res.data.id, content: res.data.content }));
    "
    ;;
  comment)
    TEXT="${3:?Missing comment text}"
    cd "$AGENT_DIR" && bun -e "
      import { readFileSync } from 'fs';
      import { google } from 'googleapis';
      const key = JSON.parse(readFileSync('$SA_KEY', 'utf-8'));
      const auth = new google.auth.GoogleAuth({ credentials: key, scopes: ['https://www.googleapis.com/auth/drive'] });
      const drive = google.drive({ version: 'v3', auth });
      const res = await drive.comments.create({
        fileId: '$DOC_ID',
        fields: 'id,content,author',
        requestBody: { content: $(printf '%s' "$TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))') },
      });
      console.log(JSON.stringify({ commentId: res.data.id, content: res.data.content }));
    "
    ;;
  add-tab)
    TITLE="${3:?Missing tab title}"
    cd "$AGENT_DIR" && bun -e "
      import { readFileSync } from 'fs';
      import { google } from 'googleapis';
      const key = JSON.parse(readFileSync('$SA_KEY', 'utf-8'));
      const auth = new google.auth.GoogleAuth({ credentials: key, scopes: ['https://www.googleapis.com/auth/documents'] });
      const docs = google.docs({ version: 'v1', auth });
      const res = await docs.documents.batchUpdate({
        documentId: '$DOC_ID',
        requestBody: {
          requests: [{ addDocumentTab: { tabProperties: { title: '$TITLE' } } }],
        },
      });
      const replies = res.data.replies ?? [];
      for (const r of replies) {
        if (r.addDocumentTab?.tabId) {
          console.log(JSON.stringify({ tabId: r.addDocumentTab.tabId, title: '$TITLE' }));
          break;
        }
      }
    "
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    echo "Usage: gdoc.sh <read|tabs|write|comments|comment|reply|add-tab> <docId> ..." >&2
    exit 1
    ;;
esac
