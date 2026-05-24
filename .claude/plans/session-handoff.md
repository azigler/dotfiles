# Session handoff — 2026-05-24 0da5df73

## State at offboard

- **Branch**: main, clean working tree (after the cutover rollback)
- **Last commit**: `9598003 :bug: orchestrator: recovery worktree must symlink .beads/ (gap caught)`
- **SS14 production**: BACK ON ZIG-COMPUTER (rolled back from mid-cutover). Round 19, 0 players, /status responsive. Pre-cutover state restored.
- **In-flight subagents**: none (all returned + merged + cleaned up)
- **Open beads** (in_progress): 4
  - `dotfiles-52c` (study) — parent C2 exploration umbrella
  - `dotfiles-9g1` (spec) — C2 spec, stays open until cutover ships
  - `dotfiles-oxe` (task) — live cutover playbook, PAUSED mid-step-8 (see --notes for full pause state)
  - `dotfiles-jc5` (bug, P1) — NEW: wrapper-impl bug surfaced live during cutover
- **Markers**: `.offboard-pending` cleared by this commit
- **Deferred**: dotfiles-st2 (iPhone Termius nerdfonts), dotfiles-406 (zig laptop tailnet)

## What happened this session (massive arc — the whole C2 cycle)

### Pre-C2 prep
- A1111 stable-diffusion-webui set up on pico (rp0/43l/lus/npc) — tailnet+LAN bind, --no-half for SDXL inpaint MPS, --api for household Claudes, handoff doc delivered to iPhone via Taildrop
- ssh-pico-via-tailnet host alias landed (~/.ssh/local pattern, gitignored)

### TPROXY/GRE exploration (research agent)
- Both ruled out: TPROXY-to-macOS = no clean asymmetric routing; GRE/IPIP = tailscale#14006 blocks non-TCP/UDP/ICMP over WireGuard
- 52c reframed → led to C2 (Approach C: wrapper-pair with minimal Robust.Server patches)

### C2 — full pipeline
- `dotfiles-9g1` spec written (subagent, ~21KB, 18 test cases, 13 OQs) + revised post-/check (55.8KB)
- `dotfiles-9cj` /check walked all 3 P1 OQs (OQ-03 NEEDS-WORK = PROXY v1 not v2; OQ-01 ACCEPT proxy_timeout 120s; OQ-02 ACCEPT stateless wrapper)
- `dotfiles-qts` test wave: 35 Go test functions + Bash integration test + SS14 C# test design sketch
- `dotfiles-1bi` impl: ss14-wrapper Go daemon, 35/35 PASS, /scrutinize SHIP
- `dotfiles-xx9` integration test extended past wrapper-present gate, end-to-end verified
- `dotfiles-b9o` deploy artifacts (build.sh, plist, README, deploy.sh, mac.setup.sh extension)
- `vs-4h1` SS14 C# patches: IRemoteAddressOverride + Ss14WrapperRemoteAddressOverride + 2 patch sites + cvars + 30 tests (vacation-station-14 + RobustToolbox submodule)
- /scrutinize on vs-4h1 = FIX-FIRST: caught CRITICAL F1 auth-bypass (3rd patch site at NetManager.ServerAuth.cs:49 missed by spec) + F2/F3 test weaknesses
- `vs-q7m` fix wave: F1+F2+F3 all addressed with real oracles, /scrutinize SHIP
- Cross-repo dispatch lessons → orchestrator skill updated TWICE (first attempt wrong about cwd persistence; second corrected with worktree-recovery + .beads symlink pattern)
- RobustToolbox forked to azigler/RobustToolbox, .gitmodules flipped, branch ss14-fork/wrapper-remote-address-vs-4h1 pushed

### Cutover (dotfiles-oxe) — PARTIALLY EXECUTED + ROLLED BACK
- Pre-flight: SS14 was empty (0 players); pico vs14 updated; Content.Server published with FullRelease + osx-arm64; rsync to watchdog instance bin/
- Steps 1-7 worked (cvar config, watchdog load, synthetic UDP test, nginx stream block + reload, zig watchdog stop)
- Step 8 (real client) FAILED — handshake timeout
- Root cause: **wrapper-impl bug** — nginx emits PROXY-protocol on UDP ONCE per src-tuple session, but wrapper expects it per-datagram. First handshake packet succeeded, subsequent dropped → Lidgren timeout.
- The /check OQ-03 finding ("PROXY on every datagram") was wrong — generalized from a synthetic test that used different src ports.
- Filed `dotfiles-jc5` (P1 bug) with full diagnosis + fix sketch (need `LookupBySrcTuple` on session store).
- Rolled back to zig cleanly: nginx stream block removed, zig watchdog re-enabled, Robust.Server back on :1212.

### Tailnet infrastructure side-quests
- Pico untagged from tag:server → user-owned (azigler@github) to enable native Taildrop with iPhone/metis (gotcha #23)
- Tailscale SSH grammar has NO syntax for tag-src → user-owned-dst (exhausted all variants); workaround = macOS sshd alt-port :2222 via /Library/LaunchDaemons/com.zig.sshd-alt-port.plist (gotcha runbook section)
- Tailscale `--force-reauth` doesn't re-publish SSH host keys to control plane → `tailscale set --ssh=false/true` toggle is the actual fix (gotcha #24 in runbook)
- File-transfer "nexus" route documented in runbook: zig → pico via :2222+key auth, pico → user-devices via native same-user Taildrop

### Misc
- Orchestrator skill cross-repo dispatch rule: documented the subagent-self-recovery pattern (with .beads/ symlink fix caught mid-session by user)

## What's next

1. **Fix `dotfiles-jc5`** (P1 bug — wrapper PROXY-per-session handling):
   - /fix dispatch in dotfiles worktree: add `LookupBySrcTuple` to session.go; UDP loop fallback path when parse fails
   - Extend integration test to cover the multi-datagram-per-src-port case (currently only tested one-datagram-per-src-port like the /check synthetic)
   - /scrutinize before close
   - Then RESUME `dotfiles-oxe` cutover from Step 1 (pico's config is still wrapper-aware, just need fresh binary + retry)
2. **Spec dotfiles-9g1 §3.8 correction** — append note that PROXY headers arrive once per session (not per datagram) post-jc5
3. **Cutover re-attempt** — once jc5 SHIPs, re-execute oxe Steps 1-11. Should land cleanly given the rest of the pipeline worked.
4. **Bonus**: nginx-stream `:1212` HTTP /status routing weirdness — currently using *:1213 wildcard binding (overly permissive on tailnet). Worth tightening post-cutover.

## Warnings / watch-outs

- **pico has cutover-time config STILL in place**: config.toml has [net] bindto=127.0.0.1 + port=1213 + use_wrapper_remote_address=true; [status] bind=*:1213; watchdog appsettings ApiPort=1213. These DON'T affect anything as long as the pico watchdog stays unloaded (it's the wrapper standalone now). When re-cutting over, the config is ready — just reload watchdog. If you ever want pico's SS14 to run STANDALONE (no wrapper) again, revert config.toml [status] bind back to *:1212 + watchdog ApiPort back to 1212 + remove [net] bindto + port + cvars.
- **pico's wrapper LaunchAgent is still loaded + listening on 100.72.47.4:11214** — harmless (no traffic routes to it now) but using ~25MB RAM. Could `launchctl unload` if you want to clean up.
- **pico's vs14 is at the NEW commit** (45c708940 + submodule at 85982545e). The patched binaries are deployed at /Users/pico/ss14-watchdog/instances/vacation-station/bin/. So once jc5 fixes the wrapper, re-cutover is just: kickstart wrapper (new binary) → load pico watchdog → add nginx stream block on zig → stop zig watchdog. Everything else is in place.
- **RobustToolbox submodule** is now pointed at azigler/RobustToolbox (a fork). Fresh clones of vs14 will pull the fork. To pull future RobustToolbox upstream changes: `cd RobustToolbox && git fetch upstream && git rebase upstream/master` (or similar).
- **Orchestrator skill cross-repo rule** went through two revisions (f6a7397 wrong, a589e9f correct, 9598003 added .beads symlink fix). The recovery snippet in the prompt is now load-bearing for any future dotfiles → vs14 / explore / etc. dispatches. Trust the worked example from vs-q7m.
- **`.offboard-pending` from prior session** in vacation-station-14 is STILL present (not mine to clear; it's the vs14 maintainer's marker from their last orphan session — next vs14 /onboard handles it).
- **Cost tracking** not enabled for dotfiles — `.claude/plans/cost-tracking.md` absent. Skip Step 4 of /offboard.
