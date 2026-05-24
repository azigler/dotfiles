package wrapper_test

import (
	"net"
	"strings"
	"testing"
	"time"

	"github.com/azigler/dotfiles/ss14-wrapper/wrapper"
	"github.com/stretchr/testify/require"
)

// seedStoreWithSession populates a store with one known session for
// LOOKUP / ENUMERATE tests.
func seedStoreWithSession(t *testing.T, realIP string, realPort int) (*wrapper.SessionStore, int) {
	t.Helper()
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	publicSrc := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000}
	realClient := &net.TCPAddr{IP: net.ParseIP(realIP), Port: realPort}
	sess, _, err := store.LookupOrCreate(publicSrc, realClient)
	require.NoError(t, err)
	return store, sess.FanOutPort
}

// TEST: TC04 (UDS surface) — LOOKUP udp <port> with a live session
// returns "OK <ip>:<port>\n".
func TestHandleAPIRequest_Lookup_OK(t *testing.T) {
	store, port := seedStoreWithSession(t, "203.0.113.5", 54321)
	req := "LOOKUP udp " + itoaInt(port)

	resp, err := wrapper.HandleAPIRequest(req, store, time.Now())

	require.NoError(t, err)
	require.Equal(t, "OK 203.0.113.5:54321\n", resp,
		"LOOKUP OK response must match spec §4.2 wire protocol exactly")
}

// TEST: TC05 (UDS surface) — LOOKUP for an unknown port returns
// "MISS\n".
func TestHandleAPIRequest_Lookup_Miss(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())

	resp, err := wrapper.HandleAPIRequest("LOOKUP udp 9999", store, time.Now())

	require.NoError(t, err)
	require.Equal(t, wrapper.APIRespMiss, resp,
		"unknown port must produce MISS\\n exactly")
}

// TEST: LOOKUP with malformed args returns ErrBadAPIRequest.
func TestHandleAPIRequest_Lookup_Malformed(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	cases := []string{
		"LOOKUP",
		"LOOKUP udp",
		"LOOKUP udp notanumber",
		"LOOKUP weirdproto 1234",
		"",
	}
	for _, line := range cases {
		t.Run(line, func(t *testing.T) {
			_, err := wrapper.HandleAPIRequest(line, store, time.Now())
			require.Error(t, err,
				"malformed request %q must return ErrBadAPIRequest", line)
		})
	}
}

// TEST: ENUMERATE with N sessions returns N lines + "END\n".
func TestHandleAPIRequest_Enumerate(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	// seed 3 distinct sessions
	for i := 0; i < 3; i++ {
		src := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000 + i}
		real := &net.TCPAddr{IP: net.IPv4(203, 0, 113, byte(i+1)), Port: 54000 + i}
		_, _, err := store.LookupOrCreate(src, real)
		require.NoError(t, err)
	}

	resp, err := wrapper.HandleAPIRequest("ENUMERATE", store, time.Now())

	require.NoError(t, err)
	require.True(t, strings.HasSuffix(resp, wrapper.APIRespEnd),
		"ENUMERATE response must terminate with END\\n; got: %q", resp)
	// Count non-END lines — should equal session count.
	lines := strings.Split(strings.TrimSuffix(resp, wrapper.APIRespEnd), "\n")
	// Filter empty lines (trailing \n from last entry)
	var got int
	for _, ln := range lines {
		if strings.TrimSpace(ln) != "" {
			got++
		}
	}
	require.Equal(t, 3, got, "ENUMERATE must list 3 sessions before END\\n")
}

// TEST: ENUMERATE with an empty store returns just "END\n".
func TestHandleAPIRequest_Enumerate_Empty(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())

	resp, err := wrapper.HandleAPIRequest("ENUMERATE", store, time.Now())

	require.NoError(t, err)
	require.Equal(t, wrapper.APIRespEnd, resp,
		"empty ENUMERATE must be exactly END\\n")
}

// TEST: HEALTH returns "OK active_sessions=N uptime_s=X\n".
func TestHandleAPIRequest_Health(t *testing.T) {
	store, _ := seedStoreWithSession(t, "203.0.113.5", 54321)
	startAt := time.Now().Add(-15 * time.Second)

	resp, err := wrapper.HandleAPIRequest("HEALTH", store, startAt)

	require.NoError(t, err)
	require.True(t, strings.HasPrefix(resp, "OK "),
		"HEALTH must start with 'OK '; got: %q", resp)
	require.Contains(t, resp, "active_sessions=1",
		"HEALTH must report the live session count")
	require.Contains(t, resp, "uptime_s=",
		"HEALTH must include uptime_s field")
	require.True(t, strings.HasSuffix(resp, "\n"),
		"HEALTH response must terminate with newline")
}

// TEST: unknown verb returns ErrBadAPIRequest.
func TestHandleAPIRequest_UnknownVerb(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())

	_, err := wrapper.HandleAPIRequest("DESTROY all", store, time.Now())

	require.Error(t, err, "unknown verb must return ErrBadAPIRequest")
}

// TEST (delegation-assertion): HandleAPIRequest for LOOKUP must
// delegate to store.LookupByPort with the parsed (proto, port) — NOT
// reach into the store fields directly. The /test SKILL Step 3.5
// pattern: if the impl agent stubs the LOOKUP handler to "return
// 'MISS\\n'", this test catches it because the stubbed handler never
// touches the store, so the spy on the dependency would never fire.
//
// We approximate the spy with a recording store wrapper: any call to
// LookupByPort populates the recorder. If HandleAPIRequest does NOT
// call through, the recorder stays empty → test fails.
//
// Note: SessionStore is a struct (not interface) for performance, so
// we use the public type. The "spy" here is "did the response
// reflect the SEEDED data?" — a stub handler that returns hardcoded
// "MISS\n" would fail the previous OK test. Combined with the
// LOOKUP unknown-port test (returns MISS), the pair forms a
// distinguishing oracle: a stub can't satisfy both.
//
// This test explicitly asserts that LOOKUP for a port we created
// (via the real LookupOrCreate path) routes through to the same
// store and gets the same real-client back — i.e., the dispatcher
// actually delegates to the store rather than to a hardcoded reply.
func TestHandleAPIRequest_Lookup_DelegatesToStore(t *testing.T) {
	// Two stores with DIFFERENT seeded real-client addresses.
	storeA := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	storeB := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())

	srcA := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000}
	realA := &net.TCPAddr{IP: net.IPv4(203, 0, 113, 5), Port: 54321}
	sessA, _, err := storeA.LookupOrCreate(srcA, realA)
	require.NoError(t, err)

	srcB := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000}
	realB := &net.TCPAddr{IP: net.IPv4(198, 51, 100, 99), Port: 12345}
	sessB, _, err := storeB.LookupOrCreate(srcB, realB)
	require.NoError(t, err)

	// Same request, different stores → MUST yield different responses
	// IFF the handler actually delegates to the passed-in store.
	respA, errA := wrapper.HandleAPIRequest(
		"LOOKUP udp "+itoaInt(sessA.FanOutPort), storeA, time.Now())
	respB, errB := wrapper.HandleAPIRequest(
		"LOOKUP udp "+itoaInt(sessB.FanOutPort), storeB, time.Now())

	require.NoError(t, errA)
	require.NoError(t, errB)
	require.NotEqual(t, respA, respB,
		"if HandleAPIRequest is delegating to the passed store, two stores "+
			"with different seeded data MUST produce different responses; "+
			"identical responses indicate a stub that doesn't read the store")
	require.Contains(t, respA, "203.0.113.5:54321")
	require.Contains(t, respB, "198.51.100.99:12345")
}

// TEST: LOOKUP request line tolerates a trailing \n (UDS clients
// typically write a newline-terminated request).
func TestHandleAPIRequest_TrailingNewline(t *testing.T) {
	store, port := seedStoreWithSession(t, "203.0.113.5", 54321)

	resp1, err1 := wrapper.HandleAPIRequest("LOOKUP udp "+itoaInt(port), store, time.Now())
	resp2, err2 := wrapper.HandleAPIRequest("LOOKUP udp "+itoaInt(port)+"\n", store, time.Now())
	resp3, err3 := wrapper.HandleAPIRequest("LOOKUP udp "+itoaInt(port)+"\r\n", store, time.Now())

	require.NoError(t, err1)
	require.NoError(t, err2)
	require.NoError(t, err3)
	require.Equal(t, resp1, resp2, "trailing \\n must not change response")
	require.Equal(t, resp1, resp3, "trailing \\r\\n must not change response")
}

// TEST: NewAPIServer initializes with the given store and a
// non-zero StartAt.
func TestNewAPIServer_Init(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())

	srv := wrapper.NewAPIServer(store)

	require.NotNil(t, srv)
	require.Same(t, store, srv.Store, "APIServer must hold the passed store")
	require.False(t, srv.StartAt.IsZero(), "StartAt must be initialized")
}

func itoaInt(i int) string {
	// Local helper to avoid pulling strconv into every test file's
	// import list (we already have it in proxy_test.go's package).
	if i == 0 {
		return "0"
	}
	var b [20]byte
	pos := len(b)
	neg := false
	if i < 0 {
		neg = true
		i = -i
	}
	for i > 0 {
		pos--
		b[pos] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		pos--
		b[pos] = '-'
	}
	return string(b[pos:])
}
