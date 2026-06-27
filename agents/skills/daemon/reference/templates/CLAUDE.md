# <project>

**<project>** = "<what the name means>." A <event-source> **ingress** that is
really the front door for a <coaching/curating/acting> agent. The daemon is the
heartbeat; the agent is the organism. Driven mostly through interactive Claude
Code sessions, with `/pulse` timer loops giving it a proactive, daemon-like life.

Read this first, then `refs/` for the knowledge base. Global agent conventions
(`~/.claude/CLAUDE.md`) still apply.

## North star
<What the user actually wants — the JOB, not the features. What they explicitly
do NOT want. Why the obvious off-the-shelf thing fails them.>

## The threads
1. **<core thread> (low-risk).** <Fully-sanctioned, build first.>
2. **<secondary thread> (handle with care).** <ToS-gray / risky? Default posture.>

## Architecture (the iceberg)
- **Daemon (tip):** <ingress> → verify → ack fast → <hydrate> → <store>. LLM-free.
- **Store:** <SQLite(WAL) / DuckDB lens — see refs/data-posture.md>.
- **Intelligence:** Claude Code (interactive + `/pulse`), NOT the daemon.
- **Memory:** MEMORY.md + beads (qualitative judgment).

## Decisions (locked <date>)
- **Daemon language = <Go pure-static / …>** — <why>.
- **Run location = <co-located with harness / …>** — <why>.
- **Data layer = <SQLite core + DuckDB lens / …>** — <why>.
- **<risk-surface> = <human-in-the-loop / …>** — <why>.

## Infra (detail in refs/topology.md)
<Box, public IP/DNS, the free port, the go-live gate, secret keys, sibling
consumers of shared resources.>

## Conventions
Orchestrator/subagent pattern · beads prefix `<project>` · gitmoji + `Bead:`
trailer · refs/ = reference material · MEMORY.md = coaching memory · scale
ceremony to the change (the daemon's contract deserves real tests).

## refs/ index
<one line per ref doc>

## Status
<where things are; what's next>
