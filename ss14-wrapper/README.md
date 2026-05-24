# ss14-wrapper

PROXY-protocol-aware UDP+TCP wrapper that sits between nginx (running
on zig-computer) and SS14's Robust.Server (running on pico). Built per
spec `dotfiles-9g1` (Approach C2: nginx + wrapper-pair + minimal
Robust.Server patches).

**Status**: TDD test surface (this directory) is complete. The
implementation has NOT landed yet — `go test ./...` fails by design,
since stubs return `wrapper.ErrNotImplemented`. The `/impl` wave fills
the stubs in.

## Layout

| Path | What it is | Status |
|---|---|---|
| `go.mod` | Module root | scaffold |
| `main.go` | Daemon entrypoint | stub — exits non-zero (`ErrNotImplemented`) |
| `wrapper/config.go` | Env-loader for SS14_WRAPPER_* vars | stub |
| `wrapper/proxy.go` | UDP+TCP listener + PROXY-header parse | stub |
| `wrapper/session.go` | 5-tuple session map + TTL eviction | stub |
| `wrapper/api.go` | UDS LOOKUP / ENUMERATE / HEALTH | stub |
| `wrapper/*_test.go` | Go unit tests (TDD-style; fail at assertions) | **complete** |
| `integration_test.sh` | End-to-end nginx-stream PROXY-emit test | **complete** |
| `docs/ss14-patch-tests.md` | C# test design sketch for the SS14 fork patches | **complete** |

## Running the tests

Unit tests (every test currently fails — that's the point of TDD; the
impl agent's job is making them pass):

```bash
cd ss14-wrapper
go test ./...
```

Integration test — stands up a synthetic nginx stream config on `:11212`
(NEVER `:1212` — live SS14 runs there), sends UDP datagrams through it
to a stub UDP sniffer, verifies the PROXY v1 text header arrives intact
with real source IP+port preserved, then rolls back. Requires `sudo -n`
for nginx config writes + reload:

```bash
sudo -v   # cache sudo creds first
bash integration_test.sh
```

Exit code 0 = full success (only after /impl lands a wrapper binary at
one of the candidate paths). Exit code 1 = expected pre-impl failure
at the "verify wrapper received PROXY-headered packet" stage; rollback
still completes cleanly.

Set `KEEP_EVIDENCE=1` to preserve `/tmp/ss14-wrapper-evidence.*.txt`
and `/tmp/ss14-wrapper-sniffer.*.log` for triage.

## Production-safety guarantees

The integration test:

1. Aborts before doing anything if live SS14 isn't already listening on
   `:1212` (verifies via `ss -tunap`).
2. Snapshots `/etc/nginx` to a tarball before any write.
3. Uses ports `:11212` and `:11213` (test convention from /check
   `dotfiles-9cj`) — never touches `:1212`.
4. Rollback runs via `trap EXIT INT TERM` — removes the test nginx
   config + reloads nginx + verifies the snapshot matches post-test
   state, EVEN ON CRASH.
5. Final safety check: SS14 `:1212` listener count is verified before,
   during, and after the test.

## See also

- Spec: `br show dotfiles-9g1`
- /check artifact: `br show dotfiles-9cj` — empirical PROXY v1 evidence
- Parent: `br show dotfiles-52c` — Approach C2 rationale
- Test bead: `br show dotfiles-qts` — this work
