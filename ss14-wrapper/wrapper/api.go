package wrapper

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
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
// request line to HandleAPIRequest. Each connection is request/response
// (one line in, one response out) — clients reconnect for each query.
// This keeps the protocol stateless and trivially debuggable with
// `nc -U /Users/pico/run/ss14-wrapper.sock`.
func (a *APIServer) Serve(ln net.Listener) error {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("ss14-wrapper: UDS accept: %w", err)
		}
		go a.handleConn(conn)
	}
}

// handleConn reads one or more newline-delimited requests from the
// given connection and writes responses back. Closes the conn on EOF
// or write error.
func (a *APIServer) handleConn(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	// Per-request read deadline keeps slow / hung peers from pinning
	// goroutines indefinitely (the wrapper's UDS is local-only so the
	// expected RTT is sub-ms; 5s is generous slack).
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	reader := bufio.NewReader(conn)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if err != io.EOF {
				log.Printf("%s read: %v", APIPrefixLog, err)
			}
			return
		}
		resp, handleErr := HandleAPIRequest(line, a.Store, a.StartAt)
		if handleErr != nil {
			// Send a typed error response so clients can distinguish
			// "bad request" from "MISS".
			resp = "ERR " + handleErr.Error() + "\n"
		}
		if _, werr := io.WriteString(conn, resp); werr != nil {
			log.Printf("%s write: %v", APIPrefixLog, werr)
			return
		}
		// Refresh read deadline for any follow-up request on the same
		// connection (rare — clients usually reconnect per query).
		_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	}
}

// HandleAPIRequest is the pure-function dispatcher for UDS API
// commands. Takes a raw request line (trailing \n or \r\n tolerated)
// and the backing store + start time, returns the response string
// (newline already included).
//
// Per spec §4.2 wire protocol:
//
//	LOOKUP <proto> <local-port>\n  → "OK <ip>:<port>\n" | "MISS\n"
//	ENUMERATE\n                    → N lines + "END\n"
//	HEALTH\n                       → "OK active_sessions=N uptime_s=X\n"
func HandleAPIRequest(line string, store *SessionStore, startAt time.Time) (string, error) {
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", ErrBadAPIRequest
	}

	fields := strings.Fields(line)
	if len(fields) == 0 {
		return "", ErrBadAPIRequest
	}

	switch fields[0] {
	case "LOOKUP":
		return handleLookup(fields, store)
	case "ENUMERATE":
		if len(fields) != 1 {
			return "", ErrBadAPIRequest
		}
		return handleEnumerate(store), nil
	case "HEALTH":
		if len(fields) != 1 {
			return "", ErrBadAPIRequest
		}
		return handleHealth(store, startAt), nil
	default:
		return "", fmt.Errorf("%w: unknown verb %q", ErrBadAPIRequest, fields[0])
	}
}

func handleLookup(fields []string, store *SessionStore) (string, error) {
	if len(fields) != 3 {
		return "", fmt.Errorf("%w: LOOKUP requires <proto> <port>", ErrBadAPIRequest)
	}
	proto := fields[1]
	if proto != "udp" && proto != "tcp" {
		return "", fmt.Errorf("%w: proto must be udp|tcp (got %q)",
			ErrBadAPIRequest, proto)
	}
	port, err := strconv.Atoi(fields[2])
	if err != nil {
		return "", fmt.Errorf("%w: port not numeric (%q)", ErrBadAPIRequest, fields[2])
	}
	addr, ok := store.LookupByPort(proto, port)
	if !ok {
		return APIRespMiss, nil
	}
	return APIPrefixOK + addr.String() + "\n", nil
}

func handleEnumerate(store *SessionStore) string {
	sessions := store.Enumerate()
	var b strings.Builder
	for _, sess := range sessions {
		if sess.RealClientAddr == nil {
			continue
		}
		b.WriteString(sess.Protocol)
		b.WriteByte(' ')
		b.WriteString(strconv.Itoa(sess.FanOutPort))
		b.WriteByte(' ')
		b.WriteString(sess.RealClientAddr.String())
		b.WriteByte('\n')
	}
	b.WriteString(APIRespEnd)
	return b.String()
}

func handleHealth(store *SessionStore, startAt time.Time) string {
	uptime := time.Since(startAt).Round(time.Second) / time.Second
	return fmt.Sprintf("OK active_sessions=%d uptime_s=%d\n",
		store.Count(), int64(uptime))
}
