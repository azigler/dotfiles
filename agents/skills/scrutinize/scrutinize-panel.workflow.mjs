// Workflow script for /scrutinize panel mode. Invoked via:
//   Workflow({ scriptPath: "<home>/.claude/skills/scrutinize/scrutinize-panel.workflow.mjs",
//              args: { scope, files?, beadId?, criteria? } })
// .mjs extension is deliberate: Workflow scripts use top-level return
// (the runtime wraps the body in an async context), which standard JS
// linters reject in .js modules — lint-on-write only matches *.js.

export const meta = {
  name: 'scrutinize-panel',
  description: 'Multi-lens adversarial review of an impl wave: parallel hunters per failure dimension, then a refuter per finding, then a verdict',
  whenToUse: 'Invoked by /scrutinize for substantial impl waves. args = { scope, files?, beadId?, criteria? }',
  phases: [
    { title: 'Hunt', detail: 'one read-only hunter per failure dimension' },
    { title: 'Verify', detail: 'one adversarial refuter per finding' },
  ],
}

const scope = args?.scope || 'the most recent impl wave (discover via git log)'
const files = args?.files || []
const criteria = args?.criteria || ''
const fileHint = files.length ? `Primary files: ${files.join(', ')}.` : 'Discover the touched files via git log/diff first.'

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'number' },
          severity: { type: 'string', enum: ['critical', 'major', 'minor'] },
          evidence: { type: 'string', description: 'file:line evidence and the exact reason this is a real problem' },
        },
        required: ['title', 'severity', 'evidence'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    isReal: { type: 'boolean' },
    reasoning: { type: 'string' },
  },
  required: ['isReal', 'reasoning'],
}

const DIMENSIONS = [
  { key: 'stub-bodies', prompt: 'Hunt for stub implementations: empty bodies after directives, functions returning {}/""/null/passthroughs, adapter modules that never import their underlying SDK, bodies shorter than the tests that verify them.' },
  { key: 'mock-the-unit', prompt: 'Hunt for tests that mock the unit under test: assertions that only exercise the mock, missing delegation-assertion tests, tests that would pass against an empty implementation.' },
  { key: 'acceptance-criteria', prompt: `Verify each acceptance criterion is ACTUALLY met by reading the code, not the self-report.${criteria ? ` Criteria:\n${criteria}` : ' Pull criteria from the bead / commit messages.'}` },
  { key: 'runtime-claims', prompt: 'Hunt for unverified runtime claims: "server starts", "endpoint works", "renders correctly" asserted without evidence. Where cheap and safe (build, curl a dev server, run the test suite read-only), reproduce the claim; otherwise flag it as unevidenced.' },
  { key: 'composition', prompt: 'Hunt for composition gaps: components built but never imported/wired into the entry point, routes defined but not registered, config written but never read. The parts can all be real while the whole is a skeleton.' },
]

phase('Hunt')
log(`Scrutinizing: ${scope}`)

const results = await pipeline(
  DIMENSIONS,
  (d) =>
    agent(
      `You are a read-only adversarial reviewer. Your job is to disprove "done" for: ${scope}. ${fileHint}\n\n${d.prompt}\n\nReport ONLY findings you can evidence with file:line. "No findings" (empty array) is a valid, honest result — do not invent issues to look thorough. Severity: critical = the shipped thing does not actually work / criterion unmet; major = works but a claim is false or a guard is missing; minor = cosmetic.`,
      { label: `hunt:${d.key}`, phase: 'Hunt', schema: FINDINGS_SCHEMA, agentType: 'Explore' }
    ),
  (review, d) =>
    parallel(
      (review?.findings || []).map((f) => () =>
        agent(
          `Adversarially REFUTE this code-review finding if you can. Finding (from the ${d.key} lens): "${f.title}" — ${f.evidence}${f.file ? ` (${f.file}${f.line ? `:${f.line}` : ''})` : ''}.\n\nRead the actual code. The finding is REAL only if the evidence holds up on inspection. Default to isReal=false when the evidence is vague, the code actually handles it, or the claim is opinion rather than defect.`,
          { label: `verify:${(f.file || f.title).slice(0, 40)}`, phase: 'Verify', schema: VERDICT_SCHEMA, agentType: 'Explore' }
        ).then((v) => ({ ...f, dimension: d.key, verdict: v }))
      )
    )
)

const all = results.filter(Boolean).flat().filter(Boolean)
const confirmed = all.filter((f) => f.verdict?.isReal)
const refuted = all.filter((f) => f.verdict && !f.verdict.isReal)

const hasCritical = confirmed.some((f) => f.severity === 'critical')
const verdict = hasCritical ? 'REJECT' : confirmed.length ? 'FIX-FIRST' : 'SHIP'

log(`Verdict: ${verdict} — ${confirmed.length} confirmed (${refuted.length} refuted) across ${DIMENSIONS.length} lenses`)

return {
  verdict,
  confirmed: confirmed.map((f) => ({ dimension: f.dimension, severity: f.severity, title: f.title, file: f.file, line: f.line, evidence: f.evidence })),
  refutedCount: refuted.length,
  lenses: DIMENSIONS.map((d) => d.key),
}
