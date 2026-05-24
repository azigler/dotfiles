package wrapper

import (
	"net"
	"sync"
	"time"
)

// Session holds the wrapper-side state for one real-client flow.
// One Session per (real-client-IP, real-client-port) pair as observed
// by nginx — i.e. one Session per Lidgren peer the server sees.
type Session struct {
	// PublicSrcAddr is the nginx-side 5-tuple key (the addr the
	// wrapper received the datagram FROM — typically the tailnet IP
	// + an nginx-assigned ephemeral port).
	PublicSrcAddr net.Addr

	// RealClientAddr is the genuine client IP+port (decoded from
	// the PROXY-protocol header). The whole spec exists to make
	// this honest.
	RealClientAddr net.Addr

	// FanOut is the wrapper-owned outbound UDP socket whose local
	// address Robust.Server sees as the peer. One per session, so
	// Robust.Server can multiplex back via LocalAddr.
	FanOut net.PacketConn

	// FanOutPort is the convenience cache of
	// FanOut.LocalAddr().(*net.UDPAddr).Port for the UDS LOOKUP API.
	FanOutPort int

	// Protocol is "udp" or "tcp" — see UDS wire protocol in spec §4.2.
	Protocol string

	// LastSeen is updated on every datagram from PublicSrcAddr;
	// drives TTL eviction (spec §4.1 proxy_timeout 120s = TC08).
	LastSeen time.Time
}

// SessionStore is the wrapper's session map. Backed by an RWMutex
// so concurrent goroutines (one per UDP fan-out + UDS server) can
// read/write safely.
type SessionStore struct {
	mu          sync.RWMutex
	bySrc       map[string]*Session // key: PublicSrcAddr.String()
	byUDPPort   map[int]*Session    // key: fan-out local port (proto=udp)
	byTCPPort   map[int]*Session    // key: upstream-side local port (proto=tcp)
	ttl         time.Duration
	allocPort   func() (net.PacketConn, error) // pluggable for tests
	now         func() time.Time               // pluggable for tests (TTL)
	upstreamFor *net.UDPAddr                   // where fan-out writes go
}

// NewSessionStore returns an empty store with the given TTL and the
// real socket-allocator. Tests inject a fake allocator via
// NewSessionStoreForTest.
func NewSessionStore(ttl time.Duration, upstream *net.UDPAddr) *SessionStore {
	return &SessionStore{
		bySrc:       make(map[string]*Session),
		byUDPPort:   make(map[int]*Session),
		byTCPPort:   make(map[int]*Session),
		ttl:         ttl,
		now:         time.Now,
		upstreamFor: upstream,
		allocPort:   func() (net.PacketConn, error) { return net.ListenPacket("udp", "127.0.0.1:0") },
	}
}

// NewSessionStoreForTest returns a store with injected clock + allocator
// so unit tests can drive TTL eviction deterministically and avoid
// allocating real sockets.
func NewSessionStoreForTest(ttl time.Duration, now func() time.Time, alloc func() (net.PacketConn, error)) *SessionStore {
	return &SessionStore{
		bySrc:     make(map[string]*Session),
		byUDPPort: make(map[int]*Session),
		byTCPPort: make(map[int]*Session),
		ttl:       ttl,
		now:       now,
		allocPort: alloc,
	}
}

// LookupOrCreate finds the session for the given public-side
// PublicSrcAddr; if none exists, it allocates a new fan-out socket
// and records (real, fanOut). Returns (session, isNew, err).
//
// STUB.
func (s *SessionStore) LookupOrCreate(publicSrc net.Addr, realClient net.Addr) (*Session, bool, error) {
	return nil, false, ErrNotImplemented
}

// LookupByPort answers UDS API LOOKUP queries. proto is "udp" or
// "tcp"; port is the local port Robust.Server sees as the peer.
// Returns (realClient, ok). STUB.
func (s *SessionStore) LookupByPort(proto string, port int) (net.Addr, bool) {
	return nil, false
}

// AddTCPSession registers a TCP session keyed by the upstream-side
// local port (the port Robust.Server sees as the peer). Called from
// ServeTCP after the PROXY header is consumed.
//
// STUB.
func (s *SessionStore) AddTCPSession(upstreamLocalPort int, realClient net.Addr) {
	// stub
}

// RemoveTCPSession is the deferred cleanup partner of AddTCPSession.
// STUB.
func (s *SessionStore) RemoveTCPSession(upstreamLocalPort int) {
	// stub
}

// Enumerate returns a snapshot of all current sessions for the UDS
// ENUMERATE command. STUB.
func (s *SessionStore) Enumerate() []*Session {
	return nil
}

// EvictExpired walks the map and removes sessions whose LastSeen is
// older than ttl. Returns the count evicted. Called from a janitor
// goroutine in Run(). STUB.
func (s *SessionStore) EvictExpired() int {
	return 0
}

// Count returns the current session count (test helper).
func (s *SessionStore) Count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.bySrc)
}
