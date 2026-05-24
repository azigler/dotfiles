package wrapper_test

import (
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/azigler/dotfiles/ss14-wrapper/wrapper"
	"github.com/stretchr/testify/require"
)

// fakePacketConn is a minimal in-memory net.PacketConn that satisfies
// the interface for session-store tests without binding real OS
// sockets. Useful for thousands of concurrent sessions.
type fakePacketConn struct {
	localAddr *net.UDPAddr
	closed    atomic.Bool
}

func newFakeConn(port int) *fakePacketConn {
	return &fakePacketConn{
		localAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port},
	}
}

func (f *fakePacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	return 0, nil, net.ErrClosed
}

func (f *fakePacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	return len(p), nil
}
func (f *fakePacketConn) Close() error                       { f.closed.Store(true); return nil }
func (f *fakePacketConn) LocalAddr() net.Addr                { return f.localAddr }
func (f *fakePacketConn) SetDeadline(t time.Time) error      { return nil }
func (f *fakePacketConn) SetReadDeadline(t time.Time) error  { return nil }
func (f *fakePacketConn) SetWriteDeadline(t time.Time) error { return nil }

// portAllocator returns a fakePacketConn allocator that hands out
// sequential ports starting at 40000, so each LookupOrCreate gets a
// unique fan-out port (matching the real impl's contract).
func portAllocator() func() (net.PacketConn, error) {
	var next int32 = 40000
	return func() (net.PacketConn, error) {
		p := atomic.AddInt32(&next, 1)
		return newFakeConn(int(p)), nil
	}
}

// TEST: TC02 — first datagram from a new 5-tuple allocates a session
// (spec dotfiles-9g1 §5 TC02).
func TestSessionStore_LookupOrCreate_NewSession(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	publicSrc := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000}
	realClient := &net.TCPAddr{IP: net.IPv4(203, 0, 113, 5), Port: 54321}

	sess, isNew, err := store.LookupOrCreate(publicSrc, realClient)

	require.NoError(t, err)
	require.True(t, isNew, "first sight of a 5-tuple must report isNew=true")
	require.NotNil(t, sess, "session must be returned")
	require.NotNil(t, sess.FanOut, "fan-out socket must be allocated")
	require.NotZero(t, sess.FanOutPort, "FanOutPort must be set")
	require.Equal(t, "203.0.113.5:54321", sess.RealClientAddr.String())
	require.Equal(t, 1, store.Count())
}

// TEST: TC03 — second datagram from the SAME 5-tuple reuses the
// existing session, isNew=false, fan-out port unchanged (spec
// dotfiles-9g1 §5 TC03 — critical per OQ-03: nginx emits PROXY header
// on every UDP datagram so the wrapper must tolerate re-seeing it).
func TestSessionStore_LookupOrCreate_ReuseSession(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	publicSrc := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000}
	realClient := &net.TCPAddr{IP: net.IPv4(203, 0, 113, 5), Port: 54321}

	sess1, isNew1, err1 := store.LookupOrCreate(publicSrc, realClient)
	require.NoError(t, err1)
	require.True(t, isNew1)

	sess2, isNew2, err2 := store.LookupOrCreate(publicSrc, realClient)
	require.NoError(t, err2)
	require.False(t, isNew2, "second datagram from same 5-tuple must reuse")
	require.Equal(t, sess1.FanOutPort, sess2.FanOutPort,
		"fan-out port must be stable across reuse")
	require.Same(t, sess1, sess2, "same Session pointer must be returned")
	require.Equal(t, 1, store.Count(), "store must still hold exactly 1 session")
}

// TEST: distinct 5-tuples allocate distinct fan-out ports + sessions.
// (TC09 multiplexing baseline.)
func TestSessionStore_DistinctTuples_DistinctFanOut(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	srcA := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41001}
	srcB := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41002}
	realA := &net.TCPAddr{IP: net.IPv4(203, 0, 113, 5), Port: 1}
	realB := &net.TCPAddr{IP: net.IPv4(198, 51, 100, 99), Port: 2}

	sA, newA, _ := store.LookupOrCreate(srcA, realA)
	sB, newB, _ := store.LookupOrCreate(srcB, realB)

	require.True(t, newA)
	require.True(t, newB)
	require.NotEqual(t, sA.FanOutPort, sB.FanOutPort,
		"each unique 5-tuple gets a unique fan-out port (multiplexing contract)")
	require.Equal(t, 2, store.Count())
}

// TEST: TC04 — LOOKUP by fan-out port returns the real client addr
// (spec dotfiles-9g1 §5 TC04).
func TestSessionStore_LookupByPort_OK(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	publicSrc := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000}
	realClient := &net.TCPAddr{IP: net.IPv4(203, 0, 113, 5), Port: 54321}
	sess, _, err := store.LookupOrCreate(publicSrc, realClient)
	require.NoError(t, err)

	got, ok := store.LookupByPort("udp", sess.FanOutPort)

	require.True(t, ok, "LOOKUP by valid fan-out port must hit")
	require.Equal(t, "203.0.113.5:54321", got.String())
}

// TEST: TC05 — LOOKUP for unknown port returns ok=false (MISS)
// (spec dotfiles-9g1 §5 TC05).
func TestSessionStore_LookupByPort_Miss(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())

	got, ok := store.LookupByPort("udp", 9999)

	require.False(t, ok, "LOOKUP for unknown port must return ok=false")
	require.Nil(t, got)
}

// TEST: TC08 — TTL eviction after the configured timeout
// (spec dotfiles-9g1 §5 TC08, proxy_timeout 120s).
func TestSessionStore_EvictExpired(t *testing.T) {
	clock := &fakeClock{t: time.Unix(1_700_000_000, 0)}
	store := wrapper.NewSessionStoreForTest(120*time.Second, clock.Now, portAllocator())
	publicSrc := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000}
	realClient := &net.TCPAddr{IP: net.IPv4(203, 0, 113, 5), Port: 54321}

	sess, _, err := store.LookupOrCreate(publicSrc, realClient)
	require.NoError(t, err)
	require.Equal(t, 1, store.Count())

	// Advance past the TTL window
	clock.Advance(121 * time.Second)
	evicted := store.EvictExpired()

	require.Equal(t, 1, evicted, "one expired session must be evicted")
	require.Equal(t, 0, store.Count())

	// Lookup by the now-evicted fan-out port returns MISS.
	_, ok := store.LookupByPort("udp", sess.FanOutPort)
	require.False(t, ok, "evicted session must MISS subsequent LOOKUPs")
}

// TEST: a session NOT yet expired must NOT be evicted.
func TestSessionStore_EvictExpired_LiveSessionSurvives(t *testing.T) {
	clock := &fakeClock{t: time.Unix(1_700_000_000, 0)}
	store := wrapper.NewSessionStoreForTest(120*time.Second, clock.Now, portAllocator())
	publicSrc := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000}
	realClient := &net.TCPAddr{IP: net.IPv4(203, 0, 113, 5), Port: 54321}

	_, _, err := store.LookupOrCreate(publicSrc, realClient)
	require.NoError(t, err)

	// Advance LESS than TTL
	clock.Advance(60 * time.Second)
	evicted := store.EvictExpired()

	require.Equal(t, 0, evicted, "live session must survive partial-TTL window")
	require.Equal(t, 1, store.Count())
}

// TEST: TC09 — 10 distinct synthetic clients get 10 distinct fan-out
// ports (spec dotfiles-9g1 §5 TC09).
func TestSessionStore_ConcurrentSessions_TenClients(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	const n = 10
	ports := make(map[int]struct{})

	for i := 0; i < n; i++ {
		src := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000 + i}
		real := &net.TCPAddr{IP: net.IPv4(203, 0, 113, byte(i+1)), Port: 54000 + i}
		sess, isNew, err := store.LookupOrCreate(src, real)
		require.NoError(t, err)
		require.True(t, isNew)
		require.NotContains(t, ports, sess.FanOutPort,
			"fan-out ports must be globally unique across sessions")
		ports[sess.FanOutPort] = struct{}{}
	}

	require.Equal(t, n, store.Count())
	enum := store.Enumerate()
	require.Len(t, enum, n, "ENUMERATE must return all sessions")
}

// EDGE: TC16 — connect-storm: 30 distinct clients simultaneously,
// allocating from a shared store. The store's mutex must serialize
// allocations such that all 30 get a unique fan-out port and no
// goroutine sees a partial write.
func TestSessionStore_ConcurrentAllocation_Safe(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	const n = 30
	var wg sync.WaitGroup
	wg.Add(n)
	results := make([]*wrapper.Session, n)
	errs := make([]error, n)

	for i := 0; i < n; i++ {
		i := i
		go func() {
			defer wg.Done()
			src := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 50000 + i}
			real := &net.TCPAddr{IP: net.IPv4(203, 0, 113, byte(i+1)), Port: 60000 + i}
			sess, _, err := store.LookupOrCreate(src, real)
			results[i] = sess
			errs[i] = err
		}()
	}
	wg.Wait()

	seenPorts := make(map[int]struct{}, n)
	for i, sess := range results {
		require.NoError(t, errs[i], "concurrent goroutine %d must not error", i)
		require.NotNil(t, sess, "concurrent goroutine %d must get a session", i)
		require.NotContains(t, seenPorts, sess.FanOutPort,
			"fan-out port %d allocated twice under concurrency", sess.FanOutPort)
		seenPorts[sess.FanOutPort] = struct{}{}
	}
	require.Equal(t, n, store.Count())
}

// EDGE: AddTCPSession + RemoveTCPSession round-trip.
func TestSessionStore_TCP_AddRemove(t *testing.T) {
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, portAllocator())
	real := &net.TCPAddr{IP: net.IPv4(198, 51, 100, 99), Port: 4000}
	const upstreamPort = 33000

	store.AddTCPSession(upstreamPort, real)

	got, ok := store.LookupByPort("tcp", upstreamPort)
	require.True(t, ok, "TCP session must be findable post-Add")
	require.Equal(t, real.String(), got.String())

	store.RemoveTCPSession(upstreamPort)

	_, ok = store.LookupByPort("tcp", upstreamPort)
	require.False(t, ok, "TCP session must MISS after Remove")
}

// EDGE: allocator failure surfaces as an error from LookupOrCreate
// (and the store is NOT left in a half-allocated state).
func TestSessionStore_LookupOrCreate_AllocFailure(t *testing.T) {
	failingAlloc := func() (net.PacketConn, error) {
		return nil, net.ErrClosed
	}
	store := wrapper.NewSessionStoreForTest(120*time.Second, time.Now, failingAlloc)
	publicSrc := &net.UDPAddr{IP: net.IPv4(100, 95, 4, 73), Port: 41000}
	realClient := &net.TCPAddr{IP: net.IPv4(203, 0, 113, 5), Port: 54321}

	sess, isNew, err := store.LookupOrCreate(publicSrc, realClient)

	require.Error(t, err, "allocator failure must surface as error")
	require.False(t, isNew, "no session was created — isNew must be false")
	require.Nil(t, sess)
	require.Equal(t, 0, store.Count(), "store must be unchanged after alloc failure")
}

// fakeClock for deterministic TTL tests.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}
