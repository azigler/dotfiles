# Session handoff — 2026-05-24 beb8609d

## State at offboard

- **Current branch**: main
- **Last commit**: `f9f8873 :bug: tmux/com.zig.tmux.plist: use HOSTNAME_PLACEHOLDER token (fixup of 7ec840c)`
- **Open beads**:
  - `dotfiles-406` (note): zig laptop deferred from tailnet at user's discretion — stays open as a tracker
  - All other in-session beads (dotfiles-phe, dotfiles-x0v, dotfiles-qix, dotfiles-tyj, dotfiles-3ec, dotfiles-tc1, dotfiles-s4t, dotfiles-jdi + many more) → CLOSED
- **In-flight subagents**: none
- **Dirty files**: none
- **Markers**: `.offboard-pending` not present (clean)
- **Working tree**: clean both repos (dotfiles + explore)

## What happened this session (major arcs)

This was a marathon session that took zig-zone from "spec idea" to "Phase 1 complete + mesh live + Tailscale SSH working bidirectionally." The arc:

1. **Spec authoring (`/spec` → `/check` → 3× `/scrutinize`)**. Wrote `dotfiles-phe` with 18 test cases + 7 OQs across Prerequisites + Phases 0–5. Three /scrutinize rounds caught a CRITICAL mac.setup.sh typo (`xtools-select`), a CRITICAL ACL semantics bug (`autogroup:member` is src-only), 7 HIGH bugs (silently-dropped services, postgres bridge networking on macOS, vs14/ss14 timers, --advertise-tags chicken-and-egg, IPv6 hand-wave, etc.), plus MEDIUM/LOW polish. All addressed across rev 1 → rev 2 → rev 3. SHIPped.

2. **Dotfiles impl wave (bead dotfiles-x0v)**. Delivered: `tailscale/acl.jsonc`, `tailscale/README.md`, `agents/skills/zig-zone/SKILL.md`, mac.setup.sh + ubuntu.setup.sh edits. Then user flagged the zig-zone SKILL as too sensitive for dotfiles' /distribute path; we relocated it to `~/explore/.claude/skills/zig-zone/SKILL.md` (dotfiles-aoa + explore-et9).

3. **Operational migration: Prerequisites + Phase 0 + Phase 1**.
   - Pico bootstrapped from fresh macOS install (xcode-select, Homebrew, dotfiles clone, mac.setup.sh — with the typo fix).
   - All 4 user-active devices joined the tailnet: zig-computer, pico, metis, iPhone (zig laptop deferred per dotfiles-406).
   - Tailnet named "zig-zone" (display name) — actual DNS suffix is `tailfb4637.ts.net` (free tier can't customize DNS suffix).
   - ACL pasted; tag:server applied to zig-computer + pico.
   - Tailscale SSH enabled on both servers; verified bidirectional (zig-computer → pico AND pico → zig-computer).

4. **Live discovery: 5 more Tailscale gotchas added to the runbook**:
   - #10: `tailscale up --hostname=X` resets all other flags (use `tailscale set` or full-flag `tailscale up`)
   - #11: Tag-apply race produces misleading "access controls don't allow anyone" warning
   - #12: **THE BIG ONE** — macOS Tailscale variants are mutually exclusive: brew formula = SSH server YES, MagicDNS NO; GUI variants (App Store / Standalone / cask) = MagicDNS YES, SSH server NO. Pico cycled through formula → cask → Standalone → back-to-formula before we figured this out.
   - #13: Standalone .pkg leaves stale shims at `/usr/local/bin/tailscale` after .app removal (clean up before re-installing formula)
   - Plus: `check` SSH action requires user identity (gotcha #9); server-to-server SSH needs `accept`

5. **Spec --notes appends** to dotfiles-phe documenting the post-spec refinements (server-to-server SSH rule + macOS variant architectural finding). Spec --description stays read-only per /beads immutability discipline.

6. **Tooling cleanups**:
   - `.servers.bash_aliases` mechanism removed (was dead — file untracked in git, sync.sh tried to copy nothing). Replaced with `ssh-zig` / `ssh-pico` aliases using `tailscale ip -4 <host>` lookups (bypass DNS, works regardless of variant).
   - `tmux/com.zig.tmux.plist` LaunchAgent committed to dotfiles + wired into `mac.setup.sh` with HOSTNAME_PLACEHOLDER + sed substitution at install time.
   - mac.setup.sh comment block explaining Tailscale variant trade-off for future Mac bootstraps.

7. **Nerdfont diagnostic — UNRESOLVED**: user reported broken glyphs in zsh airline prompt from iPhone Termius on BOTH zig-computer and pico. Glyphs were rendering correctly via Termius → zig-computer's public IP for months prior; broke this session. NOT a client-side font issue (Termius font is correctly configured + verified via another iOS app). The correlated change: **the Termius host destination was updated to point at the tailnet address (instead of the public IP)**, which means the connection path is now Termius → Tailscale SSH server (Go reimplementation) instead of Termius → OpenBSD sshd. Tailscale SSH likely handles PTY/TERM forwarding differently. Real diagnostic test for next session: have user add a parallel Termius host entry pointing at `51.81.33.136` (the public IP), connect, see if glyphs render. If YES → confirms Tailscale SSH PTY-handling regression; mitigations exist (set "Report terminal as" per-host in Termius, or disable `--ssh` on zig-computer for this path). If NO → keep digging.

## What's next (Phase 2 first thing)

**Phase 2 — Ollama + Phoenix → pico**. See `~/explore/.claude/skills/zig-zone/SKILL.md` Phase 2 section. Concrete steps:

1. **On pico (user)**: verify Ollama is bound to pico's tailnet IP (`lsof -iTCP:11434 -sTCP:LISTEN`); if not, `launchctl setenv OLLAMA_HOST "$(tailscale ip -4):11434"` + `sudo brew services restart ollama`. Pull models: `ollama pull llama3.2:3b qwen2.5:7b`.
2. **On pico (user)**: install Phoenix (`pip install arize-phoenix` or `uv pip install arize-phoenix`); start it bound to tailnet IP on `:4317` (gRPC) + `:6006` (UI).
3. **On zig-computer (orchestrator)**: verify `curl http://pico:11434/api/tags` and `:6006` succeed via tailnet. Stop + disable `ollama.service` + `lb-phoenix.service`. Verify localhost endpoints refuse. Update any OTEL env vars or agentic loop configs to point at pico.

Verifies TC07–TC09.

After Phase 2: Phase 3 (vs14 + postgres + obs + reef-router + timers — the chunky one), then Phase 4 (SS14 conditional with the feasibility test), then Phase 5 (end-state verification).

## Open follow-ups (non-blocking)

- **Nerdfont glyph rendering on iPhone Termius via tailnet** — Tailscale SSH PTY handling likely differs from OpenBSD sshd. Diagnostic test in handoff item #7 above. Real follow-up if confirmed: file or work around the Tailscale SSH terminal-handling regression.
- **zig laptop join** — tracked in `dotfiles-406`, on hold per user.

## Warnings / watch-outs for next session

- **Don't run `tailscale up` on pico without the FULL flag set** — gotcha #10. Always include `--ssh --advertise-tags=tag:server --hostname=pico --accept-routes --accept-dns` (or use `tailscale set` for surgical changes).
- **Tag-apply race** — after `tailscale up --advertise-tags=...`, wait 5s and verify with `tailscale status --json` before acting on the "access controls don't allow" warning (gotcha #11).
- **macOS DNS for outbound from pico** — broken by architectural constraint. Use `ssh-zig` alias OR the `/etc/hosts` shim (the runbook section documents both). Don't waste time chasing this as a bug.
- **Heredoc / br update gotcha** — `br update --description "$(cat /tmp/file)"` in a chained command (`&& br close`) silently truncates the description. Always run `br update --description` as a STANDALONE command, verify with `br show | grep -c "Section"`, then chain the close.
- **Pre-bead-close hook is strict on `bug` type beads** — requires `## Steps to Reproduce` section in --description. On `task`/`spec` beads, requires `## Acceptance Criteria`. Plan your bead descriptions accordingly.
