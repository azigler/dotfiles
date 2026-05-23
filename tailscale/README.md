# tailscale/

zig-zone tailnet policy + topology + recovery procedures.

## Files

- **`acl.jsonc`** — source of truth for the Tailscale ACL. Paste into Tailscale admin → Access Controls when changed. JSONC (comments allowed).

## Tailnet

`zig-zone.ts.net` (aspirational — fall back to whatever Tailscale's picker offers if taken).

### Devices

| Device | Role | OS | Tag | Tailnet IP | Public IP |
|---|---|---|---|---|---|
| `zig-computer` | workshop + edge | Ubuntu 25.10 | `tag:server` | (assigned by Tailscale) | `51.81.33.136` (OVH) |
| `pico` | server farm | macOS (M1 Max 64GB) | `tag:server` | (assigned by Tailscale) | — (home LAN) |
| `metis` | client | macOS | (untagged → `autogroup:member`) | (assigned by Tailscale) | — |
| `zig` | client (work) | macOS | (untagged → `autogroup:member`) | (assigned by Tailscale) | — |
| iPhone | client (Termius) | iOS | (untagged → `autogroup:member`) | (assigned by Tailscale) | — |

## ACL paste workflow

When `acl.jsonc` changes:

1. Open https://login.tailscale.com/admin/acls/file
2. Replace the policy with the contents of this file
3. "Preview" — verify no compile errors
4. Save

Tailscale validates JSONC + ACL semantics before letting you save. If invalid, the editor highlights the line.

## Recovery procedures

Full procedures live in the zig-zone skill at `~/explore/.claude/skills/zig-zone/SKILL.md` (read by path — not auto-loaded; kept out of dotfiles because it names sensitive operational details). The headline cases:

| Lockout | Recovery path |
|---|---|
| Tailscale coordination server down | Fall back to public `ssh ubuntu@51.81.33.136` on port 22 (LIMITed, fail2ban-protected; still works) |
| Public SSH also dead | OVH KVM web console → log in directly as user — verified-working as a Prerequisites step |
| pico unreachable (Mac asleep / crashed) | Visit pico physically; check power, reboot if needed. `autorestart` is enabled to recover from power loss automatically |
| ACL push breaks all access | Tailscale admin keeps the prior policy in the changelog; one-click revert |

## Reference

- **Spec**: bead `dotfiles-phe` in the dotfiles repo (closed; read with `br show dotfiles-phe`)
- **Skill / runbook**: `~/explore/.claude/skills/zig-zone/SKILL.md` (read by path; not auto-loaded outside `~/explore/`)
- **Tailscale docs**: https://tailscale.com/kb
- **OVH KVM access**: documented in personal password manager, NOT in this repo
