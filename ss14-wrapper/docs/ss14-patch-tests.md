# SS14 patch test design sketch

> **Scope**: this document describes the C# test surface that
> `~/vacation-station-14/` will need when the Robust.Server patches
> from spec `dotfiles-9g1` §4.3 land. It is **NOT** actual test code
> — that's written by the dispatch that follows this one, inside
> `~/vacation-station-14/`. This file is the planning artifact the
> next test-writing agent reads to know what to build.
>
> **Lives in dotfiles** rather than vacation-station-14 because the
> tests don't exist yet and a docs sketch in the spec-owning repo is
> the cleanest cross-repo handoff (per task constraints: SS14-side
> test files are STAGED here as a docs sketch only).

## Test inventory

Three concentric layers, mirroring spec §4.3's three patch sites.

### Layer 1 — Interface contract tests (`IRemoteAddressOverride`)

**Location** (when written): `RobustToolbox/Robust.UnitTesting/Shared/Network/IRemoteAddressOverrideTests.cs`

**Surface under test**:

```csharp
// RobustToolbox/Robust.Shared/Network/IRemoteAddressOverride.cs
public interface IRemoteAddressOverride
{
    IPEndPoint? Lookup(string protocol, IPEndPoint observedEndpoint);
}
```

**Contract tests** (NUnit; one `[TestFixture]` with these `[Test]` methods):

| Test name | Setup | Assertion |
|---|---|---|
| `Lookup_PassThroughOverride_ReturnsNull` | Implementation: `class PassThrough : IRemoteAddressOverride { public IPEndPoint? Lookup(...) => null; }` | `new PassThrough().Lookup("udp", anyEP)` returns `null` → caller falls back to raw |
| `Lookup_StubOverride_ReturnsConstantIP` | Stub returns fixed `203.0.113.5:54321` | Returned endpoint equals the stub's constant |
| `Lookup_ProtocolStringDifferentiates` | Stub branches on `protocol == "udp"` vs `"tcp"` | Lookup with `"udp"` returns endpoint A, `"tcp"` returns endpoint B |
| `Lookup_NullObservedEndpoint_DoesNotThrow` | Stub returns whatever; observed=null | Implementation must not NPE; either returns null or surface a typed exception (decide in /impl) |
| `Lookup_ObservedEndpointIsLoopback_StillCalls` | Stub records every invocation | When NetChannel reads RemoteEndPoint with observed=`127.0.0.1:1234`, the stub Lookup is invoked (NOT skipped on loopback) |

**Why this layer matters**: the interface itself doesn't ship logic, but
the CONTRACT is what every implementation (real + test doubles) must
honor. The pass-through default (null = use raw) is the
fork-fail-safe per spec §3.9.

### Layer 2 — `Ss14WrapperRemoteAddressOverride` implementation tests

**Location** (when written): `Content.Server.Tests/Connection/Ss14WrapperRemoteAddressOverrideTests.cs`

**Surface under test**: spec §4.3 sketch

```csharp
public sealed class Ss14WrapperRemoteAddressOverride : IRemoteAddressOverride
{
    public IPEndPoint? Lookup(string protocol, IPEndPoint observed)
    {
        // UDS connect → "LOOKUP <proto> <port>\n" → parse reply
    }
}
```

The class talks to a Unix Domain Socket at the path the cvar
`net.wrapper_socket` points to. Tests stand up a **stub UDS server**
in-process (using `System.Net.Sockets.UnixDomainSocketEndPoint` —
.NET 6+ supports this natively) that responds with canned replies.

**Test cases** (NUnit, `[TestFixture]`):

| Test name | Stub UDS behavior | Expected `Lookup` return |
|---|---|---|
| `Lookup_HappyPath_Returns_ParsedEndpoint` | Accept; read `"LOOKUP udp 33000\n"`; reply `"OK 203.0.113.5:54321\n"` | `new IPEndPoint(IPAddress.Parse("203.0.113.5"), 54321)` |
| `Lookup_MissReply_ReturnsNull` | Accept; reply `"MISS\n"` | `null` |
| `Lookup_GarbledReply_ReturnsNull_LogsWarning` | Accept; reply `"GARBLED-RESPONSE-DATA\n"` | `null`; verify Sawmill warning recorded |
| `Lookup_ConnectFails_ReturnsNull_LogsWarning` | Don't start the stub server — leave the socket path absent | `null`; warning recorded with `Err` field non-empty |
| `Lookup_SocketTimeout_ReturnsNull` | Accept connection but never reply; client must time out | `null`; no exception escapes |
| `Lookup_ReplyTooLong_Truncated_StillSafe` | Reply 100KB of `A` followed by `\n` | `null` or parsed endpoint, NEVER a thrown exception |
| `Lookup_ConcurrentInvocations_Serialize` | 10 concurrent Lookup calls; stub accepts each, replies with port-encoded IP | All 10 return distinct endpoints; no cross-contamination |
| `Lookup_RequestWireFormat_MatchesSpec` | Stub records the exact bytes received from each connection | Recorded bytes equal `"LOOKUP udp 33000\n"` byte-for-byte (NOT `"LOOKUP UDP 33000\r\n"` or similar) — case-sensitive, LF not CRLF, single space separator |
| `Lookup_TcpProtocolBranch` | Stub replies differently for `udp` vs `tcp` requests | Calling with `protocol="tcp"` produces the tcp-branch endpoint |

**Stub UDS server skeleton** (sketch — NOT actual code; the next agent
writes this):

```csharp
// sketch
private async Task<UnixDomainSocketServer> StartStub(
    Func<string, string> replyFor,
    Action<string> recordRequest = null)
{
    var path = Path.Combine(Path.GetTempPath(),
        $"ss14-test-{Guid.NewGuid()}.sock");
    var server = new UnixDomainSocketServer(path);
    server.OnConnection = async (client) =>
    {
        var req = await ReadLine(client);   // up to "\n"
        recordRequest?.Invoke(req);
        var reply = replyFor(req);
        await client.WriteAsync(Encoding.ASCII.GetBytes(reply));
    };
    await server.Start();
    return server;
}
```

The point is to assert wire-protocol contract WITHOUT spinning up
the real Go wrapper. `Ss14WrapperRemoteAddressOverride` and the
wrapper are kept honest by both reading from spec §4.2's wire
protocol.

### Layer 3 — Integration with `NetChannel` construction

**Location** (when written): `RobustToolbox/Robust.UnitTesting/Shared/Network/NetChannelOverrideIntegrationTests.cs`

The two patch sites (spec §4.3 Patches 1 + 2) live INSIDE
`NetManager.NetChannel.RemoteEndPoint` (a `get` accessor) and
`NetManager.ServerAuth.cs` line 231. Tests must drive a real
NetChannel through construction with an `IRemoteAddressOverride`
injected into the parent NetManager, and assert RemoteEndPoint
reflects the override.

**Challenge**: NetChannel is `sealed` and its constructor takes a
Lidgren `NetConnection`. Tests must either:
- (a) Stand up a real Lidgren `NetServer` + `NetClient` pair, send
  a handshake datagram, then read RemoteEndPoint on the resulting
  server-side NetChannel.
- (b) Use reflection to construct a NetChannel with a fake
  NetConnection — brittle but doesn't need a network loop.

**Recommended**: (a) — the existing
`RobustToolbox/Robust.UnitTesting/Shared/Network/RobustIntegrationTest.cs`
spins up real Lidgren pairs for other tests; follow that pattern.

**Test cases**:

| Test name | Setup | Assertion |
|---|---|---|
| `NetChannel_RemoteEndPoint_NoOverride_ReturnsLidgrenAddr` | NetManager has `RemoteAddressOverride = null`; real handshake from `127.0.0.1` | `channel.RemoteEndPoint.Address.ToString() == "127.0.0.1"` |
| `NetChannel_RemoteEndPoint_OverrideReturnsValue_UsesOverride` | NetManager wired to a stub override that returns `203.0.113.5:54321` for any input | `channel.RemoteEndPoint` equals `203.0.113.5:54321`, NOT `127.0.0.1` |
| `NetChannel_RemoteEndPoint_OverrideReturnsNull_FallsBackToRaw` | Stub override returns null | `channel.RemoteEndPoint` equals the real Lidgren peer addr (loopback) |
| `NetChannel_RemoteEndPoint_OverrideThrows_FallsBackToRaw_LogsWarning` | Stub override throws `IOException` | `channel.RemoteEndPoint` returns raw; warning recorded; NetChannel itself does NOT propagate the exception (spec §3.9) |
| `ServerAuth_NetConnectingArgsIp_UsesOverride` | Same as `OverrideReturnsValue_UsesOverride`, but assert on `NetConnectingArgs.IP` raised during the handshake (not the per-getter `RemoteEndPoint`) | Event payload's `IP.Address.ToString() == "203.0.113.5"` |
| `NetChannel_Override_ProtocolStringIsUdp_ForUdpPeer` | Connection arrives over UDP; spy on the override's `protocol` parameter | `protocol == "udp"` |
| `NetChannel_Override_ProtocolStringIsTcp_ForTcpPeer` | Connection arrives over TCP (status endpoint) | `protocol == "tcp"` |

### Layer 4 — Cvar gating (spec §4.7)

**Location** (when written): `Content.Server.Tests/Connection/Ss14WrapperCvarTests.cs`

The patch only fires when `net.wrapper_enabled = true`. Default
false means vanilla behavior.

**Test cases**:

| Test name | CVar state | Assertion |
|---|---|---|
| `WrapperCvar_DefaultFalse_DoesNotConnectUds` | `net.wrapper_enabled = false` (default) | Spy on `UnixDomainSocketClient` construction: zero invocations even after a NetChannel.RemoteEndPoint read |
| `WrapperCvar_True_RegistersOverride_IoC` | `net.wrapper_enabled = true` set at boot | `IoCManager.Resolve<IRemoteAddressOverride>()` returns the `Ss14WrapperRemoteAddressOverride` instance, NOT a pass-through |
| `WrapperCvar_Hotflip_OnlyAtStartup` | Change the cvar AFTER ServerContentIoC.Register | (Decide in /impl): either the change is ignored or it re-registers; document the chosen behavior + test it |

## Test-infrastructure notes

### Sawmill verification

Several tests above assert "logs a warning." The Robust test rig
exposes a `TestSawmillProvider` (used by other tests in
`Robust.UnitTesting`) — wire that in and assert on the captured
log lines.

### UDS path collisions

UDS paths on macOS are subject to the 104-byte path-length limit.
Tests generate paths under `Path.GetTempPath()` + a GUID; verify
the resulting path is ≤ 104 bytes before binding (skip the test with
a clear reason if the temp dir is too long).

### Integration with the Go wrapper

These C# tests do **not** invoke the Go wrapper binary. The
integration is end-to-end-tested by:
1. The Go side's `integration_test.sh` (this PR) — proves the
   wrapper-side wire protocol.
2. A live cutover dry-run on pico (spec §4.6) — proves both ends
   compose.

Cross-process wire-protocol parity is guaranteed by both sides
reading from spec §4.2 — the spec IS the contract.

## Mapping to spec test cases

| Spec TC | C# layer | C# test |
|---|---|---|
| TC04 (LOOKUP returns real IP) | Layer 2 | `Lookup_HappyPath_Returns_ParsedEndpoint` + Layer 3 `OverrideReturnsValue_UsesOverride` |
| TC05 (LOOKUP MISS) | Layer 2 | `Lookup_MissReply_ReturnsNull` |
| TC07 (wrapper crash → fallback) | Layer 2 + Layer 3 | `Lookup_ConnectFails_ReturnsNull_LogsWarning` + `NetChannel_..._OverrideThrows_FallsBackToRaw_LogsWarning` |
| TC10 (cvar default off → no UDS) | Layer 4 | `WrapperCvar_DefaultFalse_DoesNotConnectUds` |
| TC14 (IPIntel reads real IP) | Layer 3 + end-to-end | `ServerAuth_NetConnectingArgsIp_UsesOverride` covers the NetConnectingArgs.IP read path; full IPIntel exercise needs a live DB and is left to cutover dry-run |
| TC15 (AdminAlertIfSharedConnection) | Layer 3 + end-to-end | `NetChannel_RemoteEndPoint_OverrideReturnsValue_UsesOverride` covers the channel-read path |

## Out of scope for this sketch

- Actual C# source code (the next dispatch writes it in vacation-station-14)
- Performance / load tests (covered by Go integration test TC09 / TC16)
- IPv6 (spec §1.5: IPv4-first ship; IPv6 tests deferred to follow-up bead)
- End-to-end with the real Go wrapper binary (covered by cutover playbook §4.6)

## Open questions for the SS14 test author

1. **Robust test framework choice**: NUnit (which RobustToolbox uses)
   or xUnit? Pick whichever already runs in `Content.Server.Tests`.
2. **UDS support on Windows-CI**: if the test fleet runs on
   Windows-only CI, UDS-server-stub tests need `[Platform("Linux,MacOS")]`
   exclusion. Verify the test-runner config.
3. **Mocking strategy for `IPEndPoint.Parse`**: .NET's parser is
   strict — wire-protocol round-trip tests should use real strings,
   not mocked parsers.

## See also

- Spec: `br show dotfiles-9g1` (Sections 4.3, 4.7, 5)
- Go test surface: `ss14-wrapper/wrapper/*_test.go` (sibling to this doc)
- Integration test: `ss14-wrapper/integration_test.sh`
- /check decision: `br show dotfiles-9cj`
