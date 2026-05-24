package wrapper

import (
	"errors"
	"net"
	"strings"
	"time"
)

// UDS wire-protocol response constants per spec §4.2.
const (
	APIRespMiss  = "MISS\n"
	APIRespEnd   = "END\n"
	APIPrefixOK  = "OK "
	APIPrefixLog = "ss14-wrapper UDS"
)

// ErrBadAPIRequest is returned by HandleAPIRequest when the request
// line cannot be parsed (unknown verb, missing args, malformed port).
var ErrBadAPIRequest = errors.New("ss14-wrapper: bad UDS API request")

// APIServer wraps a SessionStore and a UDS listener.
type APIServer struct {
	Store   *SessionStore
	StartAt time.Time
}

// NewAPIServer returns an APIServer bound to the given store. The
// caller passes the listener to Serve so tests can use a temp socket
// path or an in-memory pipe.
func NewAPIServer(store *SessionStore) *APIServer {
	return &APIServer{Store: store, StartAt: time.Now()}
}

// Serve accepts UDS connections from the listener and dispatches each
// request line to HandleAPIRequest. STUB — /impl wave fills in the
// accept loop + connection handler.
func (a *APIServer) Serve(ln net.Listener) error {
	return ErrNotImplemented
}

// HandleAPIRequest is the pure-function dispatcher for UDS API
// commands. Takes a raw request line (no trailing newline) and the
// backing store + start time, returns the response string (newline
// already included).
//
// Per spec §4.2 wire protocol:
//
//	LOOKUP <proto> <local-port>\n  → "OK <ip>:<port>\n" | "MISS\n"
//	ENUMERATE\n                    → N lines + "END\n"
//	HEALTH\n                       → "OK active_sessions=N uptime_s=X\n"
//
// STUB — returns "" + ErrNotImplemented so tests fail at the
// assertion (real response shape) not at compile time.
func HandleAPIRequest(line string, store *SessionStore, startAt time.Time) (string, error) {
	// Best-effort: try to early-return for obviously-bad input so the
	// stub's signature is honest. The real dispatch lives in /impl.
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", ErrBadAPIRequest
	}
	return "", ErrNotImplemented
}
