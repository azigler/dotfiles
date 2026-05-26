# claude-nightly-digest — systemd user units

Headless nightly digest of recent commits and open beads across the
operator's active repos. POSTs directly to CCR (`127.0.0.1:3456`) → local
pico models (Qwen3-Coder via llama-swap `:8090`) so the work doesn't burn
Anthropic tokens.

> **Transport note**: the script POSTs to CCR's Anthropic Messages
> endpoint with `curl`, not via `claude -p`. The original spec
> (`dotfiles-ukx.4`) called for `claude -p`, but empirically validated
> 2026-05-26 that `claude -p`'s baked-in `system[0]` (billing header) +
> `system[1]` (CC/SDK identifier) shape makes CCR's
> `<CCR-SUBAGENT-MODEL>` per-request routing tag unreachable (CCR parses
> the tag from `system[1].text.startsWith(...)`; `--append-system-prompt`
> lands at `system[2]`). The script's header comment has the full
> rationale. Routing intent + prompt are unchanged — only the transport
> is different.

- **Service:** `claude-nightly-digest.service` (`Type=oneshot`)
- **Timer:** `claude-nightly-digest.timer` (daily `03:00` local, `Persistent=true`)
- **Script:** `~/dotfiles/claude/scripts/nightly-digest.sh`
- **Prompt:** `~/dotfiles/claude/prompts/nightly-digest.md`
- **Output:** `~/.local/share/claude-digests/YYYY-MM-DD.md`
- **Logs:** `~/.local/share/claude-digests/logs/YYYY-MM-DD.log`
- **On failure:** appends a `-t note` bead to `~/dotfiles/.beads/`

## Install

CCR must already be running (`ccr status` → `Running`). See
`~/dotfiles/claude-code-router/README.md`.

```bash
# Symlink the unit files (preferred — keeps dotfiles as SSoT).
mkdir -p ~/.config/systemd/user
ln -sf ~/dotfiles/claude/systemd/claude-nightly-digest.service \
       ~/.config/systemd/user/claude-nightly-digest.service
ln -sf ~/dotfiles/claude/systemd/claude-nightly-digest.timer \
       ~/.config/systemd/user/claude-nightly-digest.timer

# Reload + enable the timer (also starts it now).
systemctl --user daemon-reload
systemctl --user enable --now claude-nightly-digest.timer

# Sanity check: timer should show next firing at next 03:00.
systemctl --user list-timers claude-nightly-digest.timer
```

## Verify (smoke test)

```bash
# One-shot manual run — bypasses the timer, runs the service immediately.
systemctl --user start claude-nightly-digest.service

# Watch live:
journalctl --user -u claude-nightly-digest.service -f

# Today's digest should now exist + be non-empty:
ls -lh ~/.local/share/claude-digests/$(date -u +%F).md
cat   ~/.local/share/claude-digests/$(date -u +%F).md
```

You can also run the script directly without systemd, useful when iterating
on the prompt:

```bash
bash ~/dotfiles/claude/scripts/nightly-digest.sh
```

## Confirming local routing (not Anthropic)

Three ways to confirm the work went to a local model:

1. **In the digest file** — the HTML comment at the top of each run records
   the served model:
   ```html
   <!-- run: YYYY-MM-DDTHH:MM:SSZ ccr=http://127.0.0.1:3456 served_model=mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit -->
   ```
   Anything starting with `mlx-community/` or matching the configured
   pico model is correct. If `served_model=claude-*`, routing fell back
   to Anthropic — investigate the CCR config.
2. **CCR log** — `tail -f ~/.claude-code-router/logs/ccr-*.log` during the
   run. You should see the `background` route fire and the upstream URL be
   `100.72.47.4:8090` (llama-swap on pico), not `api.anthropic.com`.
3. **llama-swap log on pico** — `ssh pico 'tail -f ~/.local/share/llama-swap/llama-swap.log'`
   should show a Qwen3-Coder completion around the run timestamp.

If the digest looks like it came from Claude (verbose, polished prose, long
preamble), that's a routing failure — check `ccr status` and the CCR log.

## Failure path

`set -euo pipefail` is on; any non-zero command aborts and triggers the
`on_failure` trap, which:

1. Writes a stderr tail to `~/.local/share/claude-digests/logs/$DATE.log`.
2. Files a `-t note` P3 bead in `~/dotfiles/.beads/` with the failure
   context (exit code, lineno, last command, log path, stderr tail).
3. Exits with the original non-zero code so `journalctl --user` shows red.

Recover by reading the bead, fixing the issue (most common: CCR daemon
down, pico unreachable, llama-swap not running), then re-run manually with
`systemctl --user start claude-nightly-digest.service`.

## Iterate on the prompt

The model is Qwen3-Coder, not Claude — it's literal and terse. To change
what's in the digest, edit `~/dotfiles/claude/prompts/nightly-digest.md`,
then run the script. No systemd reload needed (the service re-reads the
prompt every run).

## Tunables (environment variables)

| Variable | Default | What it does |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:3456` | CCR endpoint to POST to |
| `ANTHROPIC_AUTH_TOKEN` | `ccr-passthrough` | Token forwarded by CCR; ignored for local routes |
| `CLAUDE_NIGHTLY_DIGEST_MODEL` | `claude-haiku-4-5-20251001` | Model name that triggers CCR's `background` route. Override only if your CCR config maps a different model to a local route. |
| `CLAUDE_NIGHTLY_DIGEST_MAX_TOKENS` | `3000` | Cap on output tokens |
| `CLAUDE_DIGEST_DIR` | `~/.local/share/claude-digests` | Where digests land |
| `CLAUDE_DIGEST_LOG_DIR` | `~/.local/share/claude-digests/logs` | Per-day log files |

## Uninstall

```bash
systemctl --user disable --now claude-nightly-digest.timer
rm ~/.config/systemd/user/claude-nightly-digest.{service,timer}
systemctl --user daemon-reload
```

Output digests (`~/.local/share/claude-digests/`) are left in place — they
are operator data, not service state.
