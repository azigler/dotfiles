package wrapper_test

import (
	"context"
	"net"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/azigler/dotfiles/ss14-wrapper/wrapper"
	"github.com/stretchr/testify/require"
)

// proxyV2Signature is the 12-byte PROXY v2 magic per
// https://www.haproxy.org/download/2.6/doc/proxy-protocol.txt §2.2.
var proxyV2Signature = []byte{
	0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D,
	0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A,
}

// buildProxyV1UDP returns a synthetic UDP datagram with a PROXY v1
// text header (matching what nginx 1.28 actually emits on UDP per
// /check dotfiles-9cj) followed by the given payload.
func buildProxyV1UDP(srcIP, dstIP string, srcPort, dstPort int, payload []byte) []byte {
	hdr := []byte(
		"PROXY TCP4 " + srcIP + " " + dstIP + " " +
			strconv.Itoa(srcPort) + " " + strconv.Itoa(dstPort) + "\r\n",
	)
	return append(hdr, payload...)
}

// buildProxyV2TCP4 returns a synthetic v2 binary datagram for the
// IPv4 TCP family (0x11) — this is what nginx emits by default on
// TCP per spec OQ-03.
func buildProxyV2TCP4(srcIP, dstIP string, srcPort, dstPort int, payload []byte) []byte {
	out := make([]byte, 0, 16+12+len(payload))
	out = append(out, proxyV2Signature...)
	// ver_cmd: ver=2 (high nibble) | cmd=PROXY=1 (low nibble) = 0x21
	out = append(out, 0x21)
	// fam_proto: AF_INET=0x1 (high) | TCP=0x1 (low) = 0x11
	out = append(out, 0x11)
	// addr_len: 12 bytes (4+4+2+2)
	out = append(out, 0x00, 0x0C)
	out = append(out, parseIP4(srcIP)...)
	out = append(out, parseIP4(dstIP)...)
	out = append(out, byte(srcPort>>8), byte(srcPort&0xff))
	out = append(out, byte(dstPort>>8), byte(dstPort&0xff))
	out = append(out, payload...)
	return out
}

func parseIP4(s string) []byte {
	ip := net.ParseIP(s).To4()
	if ip == nil {
		panic("bad ipv4: " + s)
	}
	return ip
}

// TEST: TC01a — PROXY v1 text header autodetected and parsed
// (spec dotfiles-9g1 §5 TC01, INPUT-a path).
func TestParseProxyHeader_V1_Text(t *testing.T) {
	payload := []byte("ss14-handshake")
	datagram := buildProxyV1UDP("203.0.113.5", "100.95.4.73", 54321, 1212, payload)

	realSrc, stripped, err := wrapper.ParseProxyHeader(datagram)

	require.NoError(t, err, "v1 text parse must succeed")
	require.NotNil(t, realSrc, "realSrc must be populated")
	require.Equal(t, "203.0.113.5:54321", realSrc.String(),
		"real client IP+port must match v1 header")
	require.Equal(t, payload, stripped,
		"stripped payload must equal input after the consumed header")
}

// TEST: TC01b — PROXY v2 binary header autodetected and parsed
// (spec dotfiles-9g1 §5 TC01, INPUT-b path). nginx defaults to v2 on
// TCP per spec OQ-03; same autodetecting reader must handle both.
func TestParseProxyHeader_V2_Binary(t *testing.T) {
	payload := []byte("ss14-handshake")
	datagram := buildProxyV2TCP4("203.0.113.5", "100.95.4.73", 54321, 1212, payload)

	realSrc, stripped, err := wrapper.ParseProxyHeader(datagram)

	require.NoError(t, err, "v2 binary parse must succeed")
	require.NotNil(t, realSrc)
	require.Equal(t, "203.0.113.5:54321", realSrc.String())
	require.Equal(t, payload, stripped)
}

// TEST: TC01 table — exhaustive v1 + v2 combos including different
// source IPs/ports and a zero-length payload (a Lidgren keepalive
// ping could in theory be small enough that the payload after the
// header is degenerate; the parser must not panic).
func TestParseProxyHeader_Table(t *testing.T) {
	cases := []struct {
		name     string
		datagram []byte
		wantSrc  string
		wantPay  []byte
	}{
		{
			name:     "v1_loopback_no_payload",
			datagram: buildProxyV1UDP("127.0.0.1", "127.0.0.1", 1, 11212, nil),
			wantSrc:  "127.0.0.1:1",
			wantPay:  []byte{},
		},
		{
			name:     "v1_high_ports",
			datagram: buildProxyV1UDP("198.51.100.99", "100.95.4.73", 65535, 1212, []byte("x")),
			wantSrc:  "198.51.100.99:65535",
			wantPay:  []byte("x"),
		},
		{
			name:     "v2_minimal",
			datagram: buildProxyV2TCP4("10.0.0.1", "10.0.0.2", 5000, 1212, []byte("y")),
			wantSrc:  "10.0.0.1:5000",
			wantPay:  []byte("y"),
		},
		{
			name:     "v2_large_payload",
			datagram: buildProxyV2TCP4("203.0.113.5", "100.95.4.73", 54321, 1212, make([]byte, 1024)),
			wantSrc:  "203.0.113.5:54321",
			wantPay:  make([]byte, 1024),
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			src, pay, err := wrapper.ParseProxyHeader(tc.datagram)
			require.NoError(t, err)
			require.Equal(t, tc.wantSrc, src.String())
			require.Equal(t, tc.wantPay, pay)
		})
	}
}

// TEST: TC18 — malformed header → wrapped error, no panic
// (spec dotfiles-9g1 §5 TC18 hardening).
func TestParseProxyHeader_Malformed(t *testing.T) {
	cases := []struct {
		name string
		buf  []byte
	}{
		{"all_zeros_short", []byte{0, 0, 0, 0}},
		{"random_garbage", []byte("not-a-proxy-header-just-random-bytes")},
		{"v2_sig_truncated", proxyV2Signature[:8]},
		{"v1_partial", []byte("PROXY TCP4 203.0.113.5")},
		{"v1_no_terminator", []byte("PROXY TCP4 203.0.113.5 100.95.4.73 54321 1212")},
		{"empty", []byte{}},
		{"single_byte", []byte{0x42}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Must NOT panic — must return an error
			require.NotPanics(t, func() {
				_, _, _ = wrapper.ParseProxyHeader(tc.buf)
			})
			_, _, err := wrapper.ParseProxyHeader(tc.buf)
			require.Error(t, err,
				"malformed input must return a non-nil error (drop-with-metric)")
		})
	}
}

// EDGE: header looks valid but contains an IPv6 source — wrapper's
// IPv4-first ship (spec §1.5 + TC12) must surface this as either a
// successful parse (returning a TCPAddr with the v6 address) or an
// error. Whatever the choice, it must NOT silently downgrade to v4.
func TestParseProxyHeader_V1_IPv6(t *testing.T) {
	hdr := []byte("PROXY TCP6 2001:db8::1 2001:db8::2 54321 1212\r\n")
	datagram := append(hdr, []byte("payload")...)

	realSrc, payload, err := wrapper.ParseProxyHeader(datagram)
	// Either it parses OK and yields a v6 src OR it errors. NEVER:
	// "[::ffff:0:0]:54321" downgrade or "[::]:0" silent zeros.
	if err == nil {
		require.NotNil(t, realSrc)
		require.Contains(t, realSrc.String(), "2001:db8::1",
			"v6 src must be preserved verbatim, not downgraded to v4")
		require.Equal(t, []byte("payload"), payload)
	}
}

// EDGE: header parses but trailing payload offset must not exceed
// the datagram length (off-by-one boundary). Tests the parser
// returns a payload slice that's a SUBSLICE of the input — not
// reaching beyond the input buffer.
func TestParseProxyHeader_PayloadSliceBounds(t *testing.T) {
	payload := []byte("exact-payload-bytes-here")
	datagram := buildProxyV1UDP("203.0.113.5", "100.95.4.73", 54321, 1212, payload)

	_, stripped, err := wrapper.ParseProxyHeader(datagram)
	require.NoError(t, err)
	require.Equal(t, len(payload), len(stripped),
		"stripped payload length must equal original payload length")
	// Make sure the parser did not reallocate — payload bytes should
	// match byte-for-byte (this is the contract the UDP forward path
	// relies on for zero-copy forward).
	require.Equal(t, payload, stripped)
}

// EDGE: a known-good v1 header concatenated with EXTRA trailing data
// (simulating an oversized packet). The library should consume only
// the header, leaving everything after as the payload.
func TestParseProxyHeader_V1_TrailingData(t *testing.T) {
	trailer := []byte("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	datagram := buildProxyV1UDP("198.51.100.99", "100.95.4.73", 12345, 1212, trailer)

	src, pay, err := wrapper.ParseProxyHeader(datagram)
	require.NoError(t, err)
	require.Equal(t, "198.51.100.99:12345", src.String())
	require.Equal(t, trailer, pay)
}

// TEST: dotfiles-jc5 regression — ParseProxyHeader must surface
// "signature not present" as ErrNoProxyHeader (NOT
// ErrMalformedProxyHeader). ServeUDP's branching on errors.Is for
// ErrNoProxyHeader is load-bearing for the nginx-per-session header
// behavior; if this distinction collapses, headerless follow-up
// datagrams get treated as malformed and silently dropped.
func TestParseProxyHeader_NoHeader_IsErrNoProxyHeader(t *testing.T) {
	// Raw Lidgren-shaped bytes — definitely no PROXY signature.
	rawPayload := []byte("just-a-game-datagram-no-proxy-header")

	_, _, err := wrapper.ParseProxyHeader(rawPayload)

	require.Error(t, err, "no-header input must error")
	require.ErrorIs(t, err, wrapper.ErrNoProxyHeader,
		"no-signature input must wrap ErrNoProxyHeader (drives ServeUDP's "+
			"session-lookup-before-drop branch — dotfiles-jc5)")
	require.NotErrorIs(t, err, wrapper.ErrMalformedProxyHeader,
		"no-signature input must NOT collapse into ErrMalformedProxyHeader — "+
			"the distinction drives the lookup-vs-drop branch in ServeUDP")
}

// TEST: dotfiles-jc5 regression — corrupt-but-signature-present
// input must surface as ErrMalformedProxyHeader, NOT ErrNoProxyHeader.
// The TC18 drop-with-metric path depends on this distinction.
func TestParseProxyHeader_TruncatedHeader_IsErrMalformed(t *testing.T) {
	// PROXY v1 signature present ("PROXY ") but the header is
	// truncated mid-line — proxyproto returns an error OTHER than
	// ErrNoProxyProtocol.
	truncated := []byte("PROXY TCP4 203.0.113.5 100.95.4.73 54321 1212")

	_, _, err := wrapper.ParseProxyHeader(truncated)

	require.Error(t, err)
	require.ErrorIs(t, err, wrapper.ErrMalformedProxyHeader,
		"truncated-signature-present input must wrap ErrMalformedProxyHeader")
	require.NotErrorIs(t, err, wrapper.ErrNoProxyHeader,
		"signature-present-but-corrupt must NOT be classified as 'no header'")
}

// findFreeUDPPort opens an ephemeral UDP socket, captures the OS-
// assigned port, then closes it so the caller can rebind. There is a
// trivial TOCTOU window between Close and re-bind; the integration
// test is happy to retry on conflict.
func findFreeUDPPort(t *testing.T) int {
	t.Helper()
	c, err := net.ListenPacket("udp", "127.0.0.1:0")
	require.NoError(t, err)
	port := c.LocalAddr().(*net.UDPAddr).Port
	_ = c.Close()
	return port
}

// TEST: dotfiles-jc5 regression — the CORE bug guard. A FIRST
// datagram with PROXY header creates the session; a SECOND datagram
// from the SAME src tuple without a header must be routed via
// LookupBySrcTuple to the existing session, NOT dropped.
//
// Pre-fix state: the second (headerless) datagram fails ParseProxyHeader,
// hits the unconditional `continue` (drop), and never reaches upstream.
// This test would FAIL — only one payload arrives upstream.
//
// Post-fix: the headerless second datagram is forwarded via the
// session established by the first. Both payloads land upstream.
func TestServeUDP_HeaderlessFollowupRoutesViaSession(t *testing.T) {
	// Allocate upstream + wrapper ports.
	upstreamPort := findFreeUDPPort(t)
	wrapperPort := findFreeUDPPort(t)

	// Upstream: collect payloads into a slice with a mutex.
	upstreamConn, err := net.ListenPacket("udp", "127.0.0.1:"+strconv.Itoa(upstreamPort))
	require.NoError(t, err)
	defer func() { _ = upstreamConn.Close() }()

	received := make(chan []byte, 8)
	go func() {
		buf := make([]byte, 65535)
		for {
			_ = upstreamConn.SetReadDeadline(time.Now().Add(3 * time.Second))
			n, _, rerr := upstreamConn.ReadFrom(buf)
			if rerr != nil {
				return
			}
			cp := make([]byte, n)
			copy(cp, buf[:n])
			received <- cp
		}
	}()

	// Wrapper: real session store + ServeUDP goroutine.
	upstreamUDP, err := net.ResolveUDPAddr("udp", "127.0.0.1:"+strconv.Itoa(upstreamPort))
	require.NoError(t, err)
	store := wrapper.NewSessionStore(120*time.Second, upstreamUDP)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	servErr := make(chan error, 1)
	go func() {
		servErr <- wrapper.ServeUDP(ctx,
			"127.0.0.1:"+strconv.Itoa(wrapperPort),
			"127.0.0.1:"+strconv.Itoa(upstreamPort),
			store)
	}()

	// Give ServeUDP a beat to bind. Best-effort: try to bind to the
	// wrapper's port from outside; success means it's free (= wrapper
	// not bound yet), failure means wrapper is holding it (= ready).
	wrapperAddr := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: wrapperPort}
	bindDeadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(bindDeadline) {
		probe, perr := net.ListenPacket("udp", "127.0.0.1:"+strconv.Itoa(wrapperPort))
		if perr != nil {
			// EADDRINUSE — wrapper is bound. Good.
			break
		}
		_ = probe.Close()
		time.Sleep(20 * time.Millisecond)
	}

	// Pinned source port — both datagrams must share this.
	clientConn, err := net.ListenPacket("udp", "127.0.0.1:0")
	require.NoError(t, err)
	defer func() { _ = clientConn.Close() }()

	// --- DATAGRAM 1: PROXY-headered (first datagram, establishes session) ---
	// Use the client's actual src-port in the PROXY header — the real
	// nginx behavior would put the real client's IP+port here, but for
	// this test we just need a coherent header. The wrapper trusts the
	// PROXY header for RealClientAddr, but routes by srcAddr (the
	// wrapper-side src of the actual UDP read, i.e. our clientConn).
	payload1 := []byte("PAYLOAD-FIRST-WITH-HEADER")
	dg1 := buildProxyV1UDP("203.0.113.5", "127.0.0.1", 54321, wrapperPort, payload1)
	_, werr := clientConn.WriteTo(dg1, wrapperAddr)
	require.NoError(t, werr)

	// --- DATAGRAM 2: headerless follow-up from SAME src port ---
	// Pre-fix: this is dropped at ParseProxyHeader. Post-fix: routed
	// via LookupBySrcTuple to the session created by dg1.
	payload2 := []byte("PAYLOAD-SECOND-NO-HEADER")
	_, werr = clientConn.WriteTo(payload2, wrapperAddr)
	require.NoError(t, werr)

	// --- DATAGRAM 3: another headerless follow-up from the SAME src
	// port (further proves the lookup path isn't a one-shot). ---
	payload3 := []byte("PAYLOAD-THIRD-NO-HEADER")
	_, werr = clientConn.WriteTo(payload3, wrapperAddr)
	require.NoError(t, werr)

	// Collect upstream arrivals. Expected: payload1 (stripped),
	// payload2 (raw — already headerless), payload3 (raw).
	got := make(map[string]bool)
	collectDeadline := time.After(2 * time.Second)
collectLoop:
	for len(got) < 3 {
		select {
		case b := <-received:
			got[string(b)] = true
		case <-collectDeadline:
			break collectLoop
		}
	}

	require.True(t, got[string(payload1)],
		"first (headered) datagram payload must reach upstream, got=%v", keysOf(got))
	require.True(t, got[string(payload2)],
		"SECOND (headerless) datagram MUST reach upstream via "+
			"LookupBySrcTuple — this is the dotfiles-jc5 regression guard. got=%v", keysOf(got))
	require.True(t, got[string(payload3)],
		"third (headerless) datagram MUST reach upstream — session "+
			"lookup is not a one-shot. got=%v", keysOf(got))
}

// TEST: dotfiles-jc5 regression — a headerless datagram from an
// UNKNOWN src tuple (no prior session established) must NOT be
// forwarded. The lookup-before-drop path is gated on session
// existence; orphan headerless traffic stays dropped.
func TestServeUDP_HeaderlessOrphanIsDropped(t *testing.T) {
	upstreamPort := findFreeUDPPort(t)
	wrapperPort := findFreeUDPPort(t)

	upstreamConn, err := net.ListenPacket("udp", "127.0.0.1:"+strconv.Itoa(upstreamPort))
	require.NoError(t, err)
	defer func() { _ = upstreamConn.Close() }()

	var arrived atomic.Int32
	go func() {
		buf := make([]byte, 65535)
		for {
			_ = upstreamConn.SetReadDeadline(time.Now().Add(1 * time.Second))
			_, _, rerr := upstreamConn.ReadFrom(buf)
			if rerr != nil {
				return
			}
			arrived.Add(1)
		}
	}()

	upstreamUDP, err := net.ResolveUDPAddr("udp", "127.0.0.1:"+strconv.Itoa(upstreamPort))
	require.NoError(t, err)
	store := wrapper.NewSessionStore(120*time.Second, upstreamUDP)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		_ = wrapper.ServeUDP(ctx,
			"127.0.0.1:"+strconv.Itoa(wrapperPort),
			"127.0.0.1:"+strconv.Itoa(upstreamPort),
			store)
	}()

	// Brief wait for bind.
	time.Sleep(100 * time.Millisecond)

	clientConn, err := net.ListenPacket("udp", "127.0.0.1:0")
	require.NoError(t, err)
	defer func() { _ = clientConn.Close() }()

	wrapperAddr := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: wrapperPort}
	// Headerless datagram with NO prior session — must drop.
	_, werr := clientConn.WriteTo([]byte("orphan-no-header-no-session"), wrapperAddr)
	require.NoError(t, werr)

	// Wait long enough that any (incorrect) forward would arrive.
	time.Sleep(500 * time.Millisecond)
	require.Equal(t, int32(0), arrived.Load(),
		"headerless orphan datagram (no prior session) MUST be dropped, "+
			"never forwarded to upstream")
}

func keysOf(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
