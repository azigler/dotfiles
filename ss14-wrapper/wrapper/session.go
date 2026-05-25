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
	byTCPPort   map[int]net.Addr    // key: upstream-side local port (proto=tcp) → real client
	ttl         time.Duration
	allocPort   func() (net.PacketConn, error) // pluggable for tests
	now         func() time.Time               // pluggable for tests (TTL)
	upstreamFor *net.UDPAddr                   // where fan-out writes go (informational)
}

// NewSessionStore returns an empty store with the given TTL and the
// real socket-allocator. Tests inject a fake allocator via
// NewSessionStoreForTest.
func NewSessionStore(ttl time.Duration, upstream *net.UDPAddr) *SessionStore {
	return &SessionStore{
		bySrc:       make(map[string]*Session),
		byUDPPort:   make(map[int]*Session),
		byTCPPort:   make(map[int]net.Addr),
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
		byTCPPort: make(map[int]net.Addr),
		ttl:       ttl,
		now:       now,
		allocPort: alloc,
	}
}

// LookupOrCreate finds the session for the given public-side
// PublicSrcAddr; if none exists, it allocates a new fan-out socket
// and records (real, fanOut). Returns (session, isNew, err).
//
// On second sight of the same 5-tuple from a PROXY-header-bearing
// datagram, the existing session is reused, LastSeen bumped, and the
// real-client refreshed (it could in theory drift on NAT rebind);
// isNew=false. NOTE: in practice nginx emits the PROXY header ONCE
// per nginx-UDP-session (dotfiles-jc5) so the reuse-from-header path
// is rare; the common subsequent-datagram path goes through
// LookupBySrcTuple instead. This LookupOrCreate reuse branch is kept
// because (a) it's the right behavior if a header IS re-presented,
// and (b) some nginx configs / proxy chains MAY re-emit per datagram.
//
// If the allocator fails, no session is recorded and the store is
// left in its prior state (TestSessionStore_LookupOrCreate_AllocFailure).
func (s *SessionStore) LookupOrCreate(publicSrc net.Addr, realClient net.Addr) (*Session, bool, error) {
	key := publicSrc.String()

	// Fast path: read-locked lookup.
	s.mu.RLock()
	if sess, ok := s.bySrc[key]; ok {
		s.mu.RUnlock()
		s.mu.Lock()
		sess.LastSeen = s.now()
		// Refresh real-client (header could in theory drift on NAT
		// rebind — accept the latest observation).
		sess.RealClientAddr = realClient
		s.mu.Unlock()
		return sess, false, nil
	}
	s.mu.RUnlock()

	// Slow path: allocator + insert under write lock. Re-check after
	// taking the write lock in case another goroutine raced us.
	s.mu.Lock()
	if sess, ok := s.bySrc[key]; ok {
		sess.LastSeen = s.now()
		sess.RealClientAddr = realClient
		s.mu.Unlock()
		return sess, false, nil
	}

	conn, err := s.allocPort()
	if err != nil {
		s.mu.Unlock()
		return nil, false, err
	}

	port := 0
	switch la := conn.LocalAddr().(type) {
	case *net.UDPAddr:
		port = la.Port
	case *net.TCPAddr:
		port = la.Port
	}

	sess := &Session{
		PublicSrcAddr:  publicSrc,
		RealClientAddr: realClient,
		FanOut:         conn,
		FanOutPort:     port,
		Protocol:       "udp",
		LastSeen:       s.now(),
	}
	s.bySrc[key] = sess
	s.byUDPPort[port] = sess
	s.mu.Unlock()
	return sess, true, nil
}

// LookupBySrcTuple finds an existing session by the public-side src
// address (the addr the wrapper received the datagram FROM — i.e. the
// nginx outbound socket's 5-tuple). Returns (session, ok).
//
// This is the path taken when a subsequent UDP datagram arrives WITHOUT
// a PROXY-protocol header: nginx's stream-module `proxy_protocol on`
// emits the v1 header ONCE per nginx-UDP-session (keyed by client
// <src-ip, src-port>), not once per datagram. The wrapper's UDP loop
// uses this lookup to route the headerless datagram via the session
// established by the FIRST (header-bearing) datagram of the same flow.
//
// On hit, LastSeen is bumped so the session doesn't TTL-evict under a
// sustained header-once-then-quiet flow. RealClientAddr is left intact
// (we trust the original header; subsequent datagrams have no header
// to refresh it from).
//
// Thread-safe — takes the write lock so the LastSeen bump is visible to
// the janitor goroutine.
func (s *SessionStore) LookupBySrcTuple(publicSrc net.Addr) (*Session, bool) {
	key := publicSrc.String()
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.bySrc[key]
	if !ok {
		return nil, false
	}
	sess.LastSeen = s.now()
	return sess, true
}

// LookupByPort answers UDS API LOOKUP queries. proto is "udp" or
// "tcp"; port is the local port Robust.Server sees as the peer.
// Returns (realClient, ok).
func (s *SessionStore) LookupByPort(proto string, port int) (net.Addr, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	switch proto {
	case "udp":
		sess, ok := s.byUDPPort[port]
		if !ok {
			return nil, false
		}
		return sess.RealClientAddr, true
	case "tcp":
		addr, ok := s.byTCPPort[port]
		if !ok {
			return nil, false
		}
		return addr, true
	}
	return nil, false
}

// AddTCPSession registers a TCP session keyed by the upstream-side
// local port (the port Robust.Server sees as the peer). Called from
// ServeTCP after the PROXY header is consumed.
func (s *SessionStore) AddTCPSession(upstreamLocalPort int, realClient net.Addr) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.byTCPPort[upstreamLocalPort] = realClient
}

// RemoveTCPSession is the deferred cleanup partner of AddTCPSession.
func (s *SessionStore) RemoveTCPSession(upstreamLocalPort int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.byTCPPort, upstreamLocalPort)
}

// Enumerate returns a snapshot of all current UDP sessions for the
// UDS ENUMERATE command. TCP sessions are NOT included here — the
// UDS wire protocol's per-session line uses proto+port+real but TCP
// sessions are short-lived enough that ENUMERATE focuses on the UDP
// game-traffic case (the live moderation surface).
func (s *SessionStore) Enumerate() []*Session {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*Session, 0, len(s.bySrc))
	for _, sess := range s.bySrc {
		out = append(out, sess)
	}
	return out
}

// EvictExpired walks the map and removes sessions whose LastSeen is
// older than ttl. Returns the count evicted. Called from a janitor
// goroutine in Run().
func (s *SessionStore) EvictExpired() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := s.now().Add(-s.ttl)
	evicted := 0
	for key, sess := range s.bySrc {
		if sess.LastSeen.Before(cutoff) {
			delete(s.bySrc, key)
			delete(s.byUDPPort, sess.FanOutPort)
			if sess.FanOut != nil {
				_ = sess.FanOut.Close()
			}
			evicted++
		}
	}
	return evicted
}

// Count returns the current UDP session count (test helper).
func (s *SessionStore) Count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.bySrc)
}
