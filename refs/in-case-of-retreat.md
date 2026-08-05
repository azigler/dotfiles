# IN CASE OF RETREAT — the canonical copy

**This file is the canonical copy of the marketing-vps retreat plan.** It was
replicated from `~/.in-case-of-retreat.txt` on **zig-computer** (user `ubuntu`)
and has been tracked here since **2026-08-05** (`dotfiles-oj2s`). Before that it
was untracked, lived on exactly one machine, and was invisible to any session not
on zig-computer.

Edit it **here**. `zig-computer:~/.in-case-of-retreat.txt` now carries a pointer to
this path; if the two ever disagree, this one wins. The body below is reproduced
verbatim — byte-for-byte, including its ASCII section rules and anything that looks
like a typo. Its steps get executed; do not reword it.

```text
IN CASE OF RETREAT — removing Zig's debris from marketing-vps
=============================================================
Written 2026-08-04 by a session running ON marketing-vps; streamlined the same day
after Zig reviewed the first draft. NOT smoke-tested — no step here has been run.
Verify facts live before acting on them. Companion: ~/dotfiles/agents/infra.md.

This is a CLEANUP, not an incident response. Zig is withdrawing from a company box he
no longer needs. Nothing here is urgent and nothing here is a breach.


ALREADY DECIDED BY ZIG — do not re-litigate, do not re-add
----------------------------------------------------------
1. NO CREDENTIAL ROTATION. He is not worried about the credentials being compromised.
   The credential files are debris like everything else: delete them with the rest of
   the home. Do NOT open a rotation workstream, do NOT tell him to revoke tokens, do
   NOT treat the shared-box exposure as a finding. (The first draft of this doc had a
   whole revoke phase. He removed it. Leave it removed.)
2. THE GITHUB ARCHIVE STAYS, INTACT. His memories and transcripts live in
   azigler/claude-memory and azigler/claude-transcripts, and the sessions from
   marketing-vps are in there because that is simply how the sync works — they all get
   pushed into the same box. He WANTS them to keep existing. So:
     - NO history rewrite. NO selective purge of marketing-vps-origin sessions.
     - Remove only the LOCAL copies on the VPS.
     - Corollary, and it is the load-bearing step of the whole plan: RUN A FINAL VAULT
       SYNC BEFORE DELETING ~/.claude, so anything that only exists on that box reaches
       GitHub first. Delete-then-discover-it-never-synced is the one unrecoverable
       mistake available here.
3. HE KNOWS AN ACCOUNT CANNOT DELETE ITSELF. Do not explain it to him. Just route that
   one step to the `ubuntu` account or the box owner, and say which.


0. THE ONE WAY THIS GOES WRONG
------------------------------
You destroy something that was never replicated, or you cut your own access before you
are finished. The phase order below is the entire defense. Do not reorder it: the
zig-computer-side key deletion and the sudoers drop-in come LAST, because every
destructive step needs both.

marketing-vps is a SHARED BOX — accounts: ubuntu, kevin (Kevin Fayle), andrew, mike
(Mike Noel), ben (Ben Lloyd Pearson). Touch nothing outside /home/andrew except the one
sudoers file named in Phase 4.


1. WHAT IS THERE (measured 2026-08-04 — re-verify, do not trust)
----------------------------------------------------------------
  /home/andrew          12G, of which ~/.claude is 6.7G (216 project slugs,
                        7,927 .jsonl transcripts)
  ~/.claude/vaults/     memory.git + transcripts.git — the push targets for the
                        GitHub archive that STAYS (see decision 2)
  repos                 ~/dotfiles · ~/linearb + submodules (imc-aug26, imc-july26,
                        agent-factory, weekly-reporting, lb-granola, pipeline-website,
                        dashboard-dev-interrupted)
  ~/work 11M · ~/bin · ~/marketing-vps · setup scripts (audit.sh, grant-nopasswd.sh,
                        dogfood-remote.sh, verify2.sh, vps-peer-bootstrap.sh,
                        vps-phase2-symlinks.sh)
  tmux                  session `work`, 5 windows, alive since Jul 28

  ⚠ ~/marketing-vps IS NOT A GIT REPO and holds its OWN .beads/ store — 6 rows in
    issues.jsonl plus a beads.db, last touched 2026-07-20, no remote, not in the
    dotfiles store. Replicated NOWHERE. Wiping that directory destroys them.

  TIMERS (user scope): claude-gateway-tunnel · lb-granola-pull (2min) · imc-pull
    (10min) · vps-repo-refresh (hourly) · claude-vault-sync (*:15)
  ⚠ Linger=yes — these run with nobody logged in. Disabling timers alone is not enough.

  TUNNELS: two outbound `ssh -L` from marketing-vps to zig-computer —
    127.0.0.1:7100 -> lb-fleet here · 127.0.0.1:17017 -> pico's agentgateway

  SSH TRUST, BOTH DIRECTIONS (people forget the second one):
    zig-computer -> marketing-vps : ~/.ssh/local Host block, IdentityFile
      ~/.ssh/id_ed25519 (comment `zig-computer-build@andrewzigler3`). Referenced by NO
      other Host block here — verified — so it is safe to delete outright. Its public
      half is the only line in marketing-vps:~/.ssh/authorized_keys.
    marketing-vps -> zig-computer : marketing-vps:~/.ssh/id_zig_computer, authorized
      HERE as the line commented `marketing-vps -> zig-computer (agent)`,
      source-restricted from="15.204.114.210". This is what lets it open the tunnels.

  DRIVEN FROM THIS BOX: 7 units ExecStart pulse-dispatch-remote.sh against it —
    pulse-di-{monday,tuesday,wednesday,thursday,friday}, pulse-weekly-report,
    pulse-biweekly-content.


THE PULSE MIGRATION — the real work hiding inside this retreat
-------------------------------------------------------------
Zig's decision (2026-08-04): the seven rows do NOT stop. They MOVE here and run
DIRECTLY on zig-computer.

Today this box is a CONDUIT. A timer here fires pulse-dispatch-remote.sh, which ssh's
to the VPS, runs the tick in a `work:<row>` window inside the VPS's `pulse-dispatch`
session, and ships the bell / AskUserQuestion BACK to the shared `work:pulse` window
here. After the migration there is no conduit and no relay: each row gets its OWN
durable window on this box — `di-monday`, `di-tuesday`, `di-wednesday`, `di-thursday`,
`di-friday`, `weekly-report`, `biweekly-content` — the tick runs here, and the surface
is simply already where Zig is. `work:pulse` stops being a conduit for these rows.

This RESTORES the original design rather than inventing one. From
~/linearb/.claude/skills/vps/SKILL.md: "di-monday and news-planning were originally
kept local because both must ring a bell to Zig, and a dialog on an unattended shared
box is worthless." Moving them remote (Zig, 2026-07-27) is precisely what forced the
surface_request round-trip into existence. Migrating back deletes that mechanism for
these rows instead of maintaining it.

WHAT DOES NOT CHANGE: the rows themselves. They are defined in each project's
refs/pulse.md — ~/linearb/dashboard-dev-interrupted/refs/pulse.md (di-monday,
di-tuesday, di-wednesday, di-thursday, di-friday, biweekly-content) and
~/linearb/weekly-reporting/refs/pulse.md (weekly-report) — and those files already live
HERE, in repos that are present and on `main`. Migration changes DELIVERY ONLY. Do not
rewrite the routing tables.

THE UNIT EDIT, one per row. From the remote form:
  ExecStart=/bin/bash -c '. %h/.secrets; exec %h/dotfiles/agents/scheduler/pulse-dispatch-remote.sh \
      --loop %p --row di-monday --dir %h/linearb/dashboard-dev-interrupted --with-fleet-token --fresh'
to the local form every native loop here already uses (copy the exact flag shape from a
working one: `systemctl --user cat pulse-dive.service`):
  ExecStart=%h/dotfiles/agents/scheduler/pulse-inject.sh \
      --loop %p --fresh --dir %h/linearb/dashboard-dev-interrupted \
      --session zig-computer --window di-monday --cmd "/pulse tick"
Note `--row` disappears entirely: row selection stops being an argument and becomes the
day-guard already in pulse.md's condition column (`date +%u = 1`). VERIFY that on one
row and watch it fire before converting the other six.

WHAT SIMPLIFIES AWAY once all seven are converted — this is the point of the exercise:
  - pulse-dispatch-remote.sh (~2,300 lines) loses every caller
  - `. %h/.secrets` + `--with-fleet-token`: fleet-creds.sh brokering exists ONLY to get
    tokens across an ssh boundary. A local tick reads ~/.secrets directly.
  - vps-preflight.sh gating, vps-repo-refresh.sh, and the vps-repo-manifest.txt lines
    for these repos
  - the deferred-surface queue / surface_request round-trip, for these rows
  - the VPS's `pulse-dispatch` session and its ~/work run dirs

PREREQUISITES — CHECK BEFORE MOVING ANYTHING. This is NOT the credential-rotation
workstream Zig killed (decision 1). It is the different question of whether the
DESTINATION has what the work needs:
  - repos: PRESENT, all six on `main` (verified 2026-08-04)
  - ~/linearb/pipeline-website/.env.local: PRESENT here (STRAPI_*, SLACK_*)
  - GOOGLE SERVICE ACCOUNT: PRESENT, and nothing needs copying off the VPS.
    CORRECTED 2026-08-04 — an earlier draft of this doc claimed it was missing here and
    told you to rescue it. That was a bad `find`: the file is dot-prefixed AND one level
    deeper than the depth searched. It is at BOTH of gdoc.sh's repo candidates,
    ~/linearb/agent-factory/agents/lb-agent-{product,accounts}/.google-service-account.json,
    byte-identical to the VPS copy (sha256 620d47ef…, 2368 bytes, identity
    lb-agent-accounts@linearb-marketing).
    ⚠ The real fragility is different: both repo copies are UNTRACKED and GITIGNORED
      inside the agent-factory submodule, so a re-clone or `git clean -xfd` would erase
      the key from this box entirely. So a durable third copy now sits OUTSIDE any repo
      at ~/.config/gcloud/service-account.json (0600, dir 0700) — which is gdoc.sh's own
      third candidate, so it resolves with zero config if the repo copies ever vanish.
      Verified 2026-08-04 by simulating their absence; resolution order is unchanged
      while they exist. Nothing further to do here.


2. PHASE 1 — RESCUE (nothing destructive; do not skip)
------------------------------------------------------
  # 1a. FINAL VAULT SYNC FIRST — this is decision 2's corollary and the highest-value
  #     step in the plan. Everything else is deletable; an unsynced transcript is not.
  ssh marketing-vps 'systemctl --user start claude-vault-sync.service; sleep 60;
      tail -3 ~/.claude/vault-sync-ledger.jsonl'
  Confirm the last rows report a SUCCESSFUL push for BOTH tiers (memory and
  transcripts). That script is deliberately loud about deferrals — a "deferred" row is
  not a push. Re-run until both are clean.

  # 1b. every repo pushed? prove against the REMOTE (that box stranded 4 commits once)
  ssh marketing-vps 'for r in ~/dotfiles ~/linearb ~/linearb/*/; do
      [ -e "$r/.git" ] || continue
      printf "%-46s dirty=%-3s unpushed=%s\n" "$r" \
        "$(git -C $r status --porcelain | wc -l)" \
        "$(git -C $r log --oneline @{u}..HEAD 2>/dev/null | wc -l)"; done'
  At writing: ~/linearb 2 dirty, ~/linearb/imc-aug26 1 dirty, 0 unpushed anywhere, no
  stashes. Resolve dirty files before Phase 3 — commit+push or copy off.

  # 1c. the orphan beads (replicated nowhere — see §1)
  scp marketing-vps:'~/marketing-vps/.beads/issues.jsonl' ~/retreat-rescue-mvps-beads.jsonl

  # 1d. live tmux panes hold context that exists nowhere else
  ssh -t marketing-vps 'tmux ls'

  # 1e. NOTHING TO DO — deliberately left as a tombstone so it is not "restored".
  #     This step used to copy the Google service-account key off the VPS. The key was
  #     already on zig-computer (twice), and a durable third copy was placed outside any
  #     repo at ~/.config/gcloud/service-account.json on 2026-08-04. See PREREQUISITES.
  #     Note ~/.secrets is a DIRECTORY on marketing-vps but a FILE on zig-computer
  #     (every unit does `. ~/.secrets`), so ~/.secrets/anything is not a valid
  #     destination here — which is why the copy lives under ~/.config/gcloud/.


3. PHASE 2 — STOP THE RECURRING
--------------------------------
  # 2a. ON ZIG-COMPUTER — stop driving the box. Do this ONLY after the seven rows
  #     are converted and at least one has fired locally (see THE PULSE MIGRATION);
  #     otherwise you have not moved the work, you have stopped it.
  systemctl --user disable --now pulse-di-{monday,tuesday,wednesday,thursday,friday}.timer \
                                 pulse-weekly-report.timer pulse-biweekly-content.timer

  # 2b. ON MARKETING-VPS — its own timers
  ssh marketing-vps 'systemctl --user disable --now \
      claude-gateway-tunnel.timer lb-granola-pull.timer imc-pull.timer \
      vps-repo-refresh.timer claude-vault-sync.timer'

  # 2c. tunnels, tmux, and the lingering user manager
  ssh marketing-vps 'pkill -u andrew -f "ssh .*-L 127.0.0.1:(7100|17017)"; \
      tmux kill-server; loginctl disable-linger andrew'

  # 2d. confirm quiet
  ssh marketing-vps 'systemctl --user list-timers --all --no-pager;
      ss -tlnp | grep -E "7100|17017"; pgrep -u andrew -a ssh'


4. PHASE 3 — WIPE THE HOME
---------------------------
Only after Phase 1. No rotation step — the credential files below are just debris
(decision 1): ~/.secrets/, ~/.config/gh/, ~/linearb/pipeline-website/.env.local,
~/.claude.json, ~/.gnupg. They go with everything else.

  ssh marketing-vps 'rm -rf ~/.claude ~/.claude-harness-backup ~/.claude.json* \
      ~/.config/gh ~/.secrets ~/work ~/linearb ~/dotfiles ~/marketing-vps ~/bin \
      ~/.gnupg ~/.zsh_history ~/.bash_history'
  Then the tooling remainder (~/.cache ~/.local ~/.npm ~/.nvm ~/.rustup ~/.cargo ~/.bun
  ~/.oh-my-zsh ~/.antigen and the ~/.* rc files) — or leave it for `userdel -r`.

  ⚠ Once ~/dotfiles is gone, the "two writers, one working tree" hazard in AGENTS.md no
    longer applies to this pair. Note it in infra.md so future sessions stop defending
    against a second writer that does not exist.


5. PHASE 4 — SEVER THE TRUST, THEN THE SUDO GRANT
--------------------------------------------------
  # 4a. ON MARKETING-VPS FIRST (needs the connection that 4b/4c destroy)
  ssh marketing-vps 'rm -f ~/.ssh/id_zig_computer* ~/.ssh/known_hosts* ~/.ssh/local; \
      : > ~/.ssh/authorized_keys'

  # 4b. ON ZIG-COMPUTER — remove the inbound authorization (match the COMMENT, not a
  #     line number)
  cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak.$(date +%F)
  grep -v 'marketing-vps -> zig-computer' ~/.ssh/authorized_keys.bak.$(date +%F) \
      > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

  # 4c. ON ZIG-COMPUTER — the outbound key + Host block. RE-CHECK nothing else uses it:
  #     grep -B4 id_ed25519 ~/.ssh/config ~/.ssh/local
  rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
  # delete the `Host marketing-vps` block from ~/.ssh/local
  ssh-keygen -R 15.204.114.210
  ⚠ AFTER 4b+4c YOU CANNOT GET BACK IN.

  # 4d. LAST — the sudo grant (/etc/sudoers.d/90-andrew-nopasswd, installed by
  #     ~/grant-nopasswd.sh, contents `andrew ALL=(ALL) NOPASSWD:ALL`)
  ssh marketing-vps 'sudo rm -f /etc/sudoers.d/90-andrew-nopasswd && sudo visudo -c'
  Validate sudoers after the change. A malformed /etc/sudoers.d locks EVERY account out
  of sudo, including the team's. Highest blast radius in the plan, on someone else's box.


6. PHASE 5 — THE ACCOUNT (routes to someone else)
--------------------------------------------------
Hand to the box owner, or run from the `ubuntu` account:
    sudo loginctl disable-linger andrew
    sudo pkill -u andrew ; sudo userdel -r andrew
Alternative end state, equally valid and REVERSIBLE: leave the account in place,
emptied and quiet after Phases 2-4. Prefer this if the retreat might be temporary.


7. DO NOT TOUCH
---------------
  - /home/{ubuntu,kevin,mike,ben} or anything they own
  - sshd config, firewall, any system service other than the one sudoers file in 4d
  - the GitHub repos (azigler/claude-*, lb-marketing/*) — decision 2
  - lb-granola's presence there was deliberate (bead dotfiles-hi81). If retreat reverses
    it, say so against that bead rather than deleting quietly.
  - the 2026-08-03 hostname rename (vps-8a9eb245 -> marketing-vps, /etc/hosts aliases,
    /etc/cloud/cloud.cfg preserve_hostname) — leaving it is harmless; reverting is a
    courtesy. Either way, say which. Do not do it silently.


8. HOW YOU KNOW YOU'RE OUT
--------------------------
  ssh -o BatchMode=yes -o ConnectTimeout=8 marketing-vps true    # MUST fail
  systemctl --user list-timers --all | grep -E 'pulse-di-|weekly-report|biweekly'  # empty
  grep -c 'marketing-vps' ~/.ssh/authorized_keys                 # 0
Then the paperwork that always gets forgotten: strip marketing-vps from
agents/infra.md (demesne table, its section, the two-writers warnings), neutralize
vps-preflight.sh / vps-repo-refresh.sh / fleet-creds.sh's peer, fix this box's
~/.break-glass.txt cross-references, and file a `-t decision` bead recording what was
removed and what was deliberately left.


=====================================================================
9. START HERE — THE CONVERSATION TO HAVE WITH ZIG
=====================================================================

A. ASK HIM THESE FIVE. Nothing else is genuinely his call; everything else has a
   correct answer already in this doc. Lead with your recommendation.

   Q1. THE SEVEN PULSE ROWS — confirm the SHAPE, not whether to do it.
       Already decided (Zig, 2026-08-04): they move here and run directly, one durable
       window per row, and work:pulse stops being a conduit. See THE PULSE MIGRATION.
       What actually needs his answer:
         - convert all seven at once, or pilot ONE first?
           -> Recommend: pilot di-monday, watch it fire on its real schedule, then
              convert the remaining six.
         - does the retreat wait on the migration proving out?
           -> Recommend: YES. A converted row that has never fired is not migrated,
              and Phase 2a is the point of no return for the old path.

   Q2. HOW FAR? Emptied-but-present account, or fully deleted?
       -> Recommend emptied-but-present unless he is certain. It is reversible, it is
          quiet, and full deletion needs the box owner anyway.

   Q3. THE FIVE LIVE TMUX WINDOWS — kill them now, or let them finish?
       They have been up since Jul 28 and hold context that exists nowhere else.
       -> Recommend: capture what matters, then kill. Do not wait indefinitely.

   Q4. UNCOMMITTED WORK — ~/linearb (2 files) and ~/linearb/imc-aug26 (1 file) are
       dirty. Commit and push, or discard?
       -> Recommend: show him the diff, then push. Cheap, and it is the one thing
          Phase 3 cannot undo.

   Q5. THE 6 ORPHAN BEADS in ~/marketing-vps/.beads — replicated nowhere. Do they move
       into a surviving store, or get closed?
       -> Recommend: rescue the file first regardless (Phase 1c costs nothing), decide
          the destination after he has seen the titles.

B. THEN PROPOSE THIS, AND WALK IT WITH HIM ONE PHASE AT A TIME.
   Stop at each checkpoint and show the output — do not batch phases together.

   Step 1  Phase 1 RESCUE. Show him: the vault-sync ledger rows proving BOTH tiers
           pushed, the per-repo dirty/unpushed table, the rescued beads file, and
           `tmux ls`. (1e is a no-op — the service-account key is already safe here in
           three places.) CHECKPOINT: he confirms nothing is left behind.
   Step 2  THE MIGRATION. Convert ONE row (recommend di-monday) from the remote form to
           the local form, leave the other six alone, and WAIT for it to fire on its own
           schedule. Show him the new unit, the window it created here, and its ledger
           row. CHECKPOINT: a row ran end-to-end on zig-computer with no VPS involved.
           Then convert the remaining six the same way.
           ⚠ Do not skip the wait. A converted row that has never fired is not migrated,
           and Step 3 is the point of no return for the old path.
   Step 3  Phase 2 STOP. Show `list-timers` empty of the remote units, no tunnel
           sockets, no ssh processes, Linger=no. CHECKPOINT: the box is quiet and
           stays quiet, and the seven rows are still running — here.
   Step 4  Phase 3 WIPE. Show `du -sh ~` before and after, and `ls -A ~`.
           CHECKPOINT: home is empty of his work.
   Step 5  Phase 4 SEVER, in the order 4a -> 4b -> 4c -> 4d. Warn him explicitly before
           4b that access ends there. CHECKPOINT: the `ssh … true` probe fails.
   Step 6  Phase 5 ACCOUNT — only if Q2 said full deletion. Hand off to the box owner
           with the exact two commands; do not attempt it as andrew.
   Step 7  PAPERWORK (§8), plus the migration's own cleanup: pulse-dispatch-remote.sh,
           vps-preflight.sh, vps-repo-refresh.sh, fleet-creds.sh and vps-repo-manifest.txt
           now have no callers. Delete or archive them deliberately and say which.
           File the decision bead. This is part of the job, not a follow-up.

C. DO NOT ASK HIM ABOUT — decided 2026-08-04, in this doc's header:
   credential rotation (there is none), deleting anything from the GitHub archive
   (there is none of that either), or whether an account can delete itself (he knows).
```
