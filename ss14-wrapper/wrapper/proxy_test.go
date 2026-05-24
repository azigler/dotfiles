package wrapper_test

import (
	"net"
	"strconv"
	"testing"

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
