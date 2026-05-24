package wrapper

import (
	"errors"
	"net"
)

// ErrNotImplemented is returned by stub functions in this package
// before the /impl wave lands. Its presence in test failures is a
// signal that the impl agent has more work to do.
var ErrNotImplemented = errors.New("ss14-wrapper: not implemented (awaiting /impl wave)")

// ErrMalformedProxyHeader wraps any go-proxyproto Read error so
// callers can drop the datagram and increment a metric without
// branching on the specific parse-error type. See spec TC18.
var ErrMalformedProxyHeader = errors.New("ss14-wrapper: malformed PROXY-protocol header")

// ParseProxyHeader takes a UDP datagram (PROXY-header + payload)
// and returns:
//   - realSrc: the real client IP+port as decoded from the header
//     (TCPAddr for v1 since v1 only labels TCP4/TCP6; nginx reuses
//     the TCP4 token for UDP per haproxy convention — see spec
//     OQ-03 evidence block)
//   - payload: the bytes AFTER the consumed header (i.e. the raw
//     Lidgren datagram the wrapper forwards to Robust.Server)
//   - err: non-nil on parse failure (wrapped as
//     ErrMalformedProxyHeader)
//
// STUB — returns (nil, nil, ErrNotImplemented) so tests fail with a
// clearly-identifiable error message rather than compile errors.
func ParseProxyHeader(buf []byte) (realSrc net.Addr, payload []byte, err error) {
	return nil, nil, ErrNotImplemented
}

// ServeUDP runs the public-facing UDP listener. It reads each
// datagram, parses the PROXY header (per /check dotfiles-9cj:
// nginx 1.28 emits PROXY v1 on EVERY UDP datagram, not just the
// first), looks up or creates a session, and writes the stripped
// payload to the upstream Robust.Server. STUB.
func ServeUDP(listenAddr, upstreamAddr string, store *SessionStore) error {
	return ErrNotImplemented
}

// ServeTCP runs the public-facing TCP listener. PROXY header is
// parsed once per connection (nginx default behavior, also v2 binary
// per spec OQ-03 evidence). STUB.
func ServeTCP(listenAddr, upstreamAddr string, store *SessionStore) error {
	return ErrNotImplemented
}

// Run wires up the configured listeners (UDP + TCP + UDS API) and
// blocks until the process is killed. STUB.
func Run(cfg *Config) error {
	return ErrNotImplemented
}
