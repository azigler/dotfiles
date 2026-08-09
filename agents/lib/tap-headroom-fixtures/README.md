# tap-headroom fixtures — REAL responses, captured 2026-08-09

These three files are **verbatim bodies** from
`GET https://api.anthropic.com/api/oauth/usage`, captured on 2026-08-09 while
building `dotfiles-kecb`, against three real accounts. They are the evidence
`agents/lib/test-tap-headroom.sh` parses; nothing here was hand-written.

| file | account / condition | what it pins |
|---|---|---|
| `usage-primary-2026-08-09.json` | `~/.claude`, andrewzigler@gmail.com, Max 20x | the `limits[]` shape, and the model-scoped Fable entry at 81% while the unified weekly read 75% — the whole reason this endpoint had to be found |
| `usage-secondary-2026-08-09.json` | `~/.claude-secondary`, zig@zigler.ai, Max 20x, provisioned that evening | a genuinely EMPTY account: every window a measured `0`, which must stay distinguishable from "not measured" |
| `usage-401-expired-token-2026-08-09.json` | `~/.claude-work`, an access token ~12h past `expiresAt` | the failure body an expired credential actually returns — `authentication_error`, not an empty usage document |

**They contain no secrets.** The usage document carries utilization
percentages and reset timestamps only; no token, no key, no email. The request
that produced each one sent a bearer token, which was never written down.

**Do not hand-edit them.** A parser tested only on fixtures somebody invented is
a parser tested against its own author's assumptions — which is exactly how the
0-100 vs 0-1 scale difference (percent here, fraction in the gateway's captured
attributes) and the 401-is-an-expired-token case would have been missed. If the
document's shape changes, re-capture rather than adjust:

```bash
# prints the http code and the body; the token is read, never printed
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])")
curl -sS -w '\nhttp=%{http_code}\n' \
  -H "Authorization: Bearer $TOK" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "anthropic-version: 2023-06-01" \
  https://api.anthropic.com/api/oauth/usage
```

Scheme, traps and the sibling `/api/oauth/profile` endpoint:
`refs/probes/gateway-attribution-epoch3.md`.
