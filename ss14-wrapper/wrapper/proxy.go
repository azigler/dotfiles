package wrapper

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"time"

	proxyproto "github.com/pires/go-proxyproto"
)

// ErrNotImplemented is returned by stub functions in this package
// before the /impl wave lands. Kept exported because the test scaffold
// still references it as a sentinel; the real implementation no longer
// returns it from any production code path.
var ErrNotImplemented = errors.New("ss14-wrapper: not implemented (awaiting /impl wave)")

// ErrMalformedProxyHeader wraps any go-proxyproto Read error so
// callers can drop the datagram and increment a metric without
// branching on the specific parse-error type. See spec TC18.
var ErrMalformedProxyHeader = errors.New("ss14-wrapper: malformed PROXY-protocol header")

// udpReadBufSize is the per-read scratch buffer size. SS14/Lidgren
// packets are typically <1.5KB but nginx PROXY-headered packets can
// reach ~64KB at the IP layer; 64KiB covers max UDP payload safely.
const udpReadBufSize = 65535

// ParseProxyHeader takes a UDP datagram (PROXY-header + payload)
// and returns:
//   - realSrc: the real client IP+port decoded from the header.
//     For nginx 1.28 UDP this is a *net.TCPAddr (v1 only labels
//     TCP4/TCP6; nginx reuses the TCP4 token for UDP per haproxy
//     convention — spec OQ-03 evidence block).
//   - payload: the bytes AFTER the consumed header (the stripped
//     Lidgren datagram the wrapper forwards to Robust.Server). The
//     slice is a subslice of buf — zero-copy.
//   - err: non-nil on parse failure, wrapped as ErrMalformedProxyHeader.
//
// The proxyproto library auto-detects v1 (text) vs v2 (binary) by
// peeking at the first bytes; both formats parse through the same
// entry point (Read).
func ParseProxyHeader(buf []byte) (realSrc net.Addr, payload []byte, err error) {
	if len(buf) == 0 {
		return nil, nil, fmt.Errorf("%w: empty input", ErrMalformedProxyHeader)
	}

	// Defensive: proxyproto.Read can in some edge cases (e.g. signature
	// mismatch followed by a peek error) bubble panics on malformed input
	// shapes the library didn't anticipate. We swallow them as parse
	// errors — TC18 demands drop-with-metric, never crash.
	defer func() {
		if r := recover(); r != nil {
			realSrc = nil
			payload = nil
			err = fmt.Errorf("%w: panic during parse: %v", ErrMalformedProxyHeader, r)
		}
	}()

	underlying := bytes.NewReader(buf)
	br := bufio.NewReader(underlying)

	hdr, parseErr := proxyproto.Read(br)
	if parseErr != nil {
		return nil, nil, fmt.Errorf("%w: %v", ErrMalformedProxyHeader, parseErr)
	}
	if hdr == nil || hdr.SourceAddr == nil {
		return nil, nil, fmt.Errorf("%w: empty header", ErrMalformedProxyHeader)
	}

	// Compute exact bytes consumed from buf. proxyproto.Read may have
	// peeked past the header into the bufio buffer (Peek can read ahead);
	// the actually-consumed prefix is: total - bufio-buffered - underlying-remaining.
	consumed := len(buf) - br.Buffered() - underlying.Len()
	if consumed < 0 || consumed > len(buf) {
		return nil, nil, fmt.Errorf("%w: invalid consumed length %d (buf len %d)",
			ErrMalformedProxyHeader, consumed, len(buf))
	}

	// Return a subslice — preserves zero-copy contract for the UDP
	// forward path (spec §4.2 TC PayloadSliceBounds).
	payload = buf[consumed:]
	return hdr.SourceAddr, payload, nil
}

// ServeUDP runs the public-facing UDP listener. It reads each
// datagram, parses the PROXY header (per /check dotfiles-9cj: nginx
// 1.28 emits PROXY v1 on EVERY UDP datagram, not just the first),
// looks up or creates a session, and writes the stripped payload to
// the upstream Robust.Server over the session's fan-out socket.
//
// Returns when ctx is cancelled or listener errors fatally.
func ServeUDP(ctx context.Context, listenAddr, upstreamAddr string, store *SessionStore) error {
	publicConn, err := net.ListenPacket("udp", listenAddr)
	if err != nil {
		return fmt.Errorf("ss14-wrapper: ListenPacket %q: %w", listenAddr, err)
	}
	defer func() { _ = publicConn.Close() }()

	upstreamUDP, err := net.ResolveUDPAddr("udp", upstreamAddr)
	if err != nil {
		return fmt.Errorf("ss14-wrapper: ResolveUDPAddr %q: %w", upstreamAddr, err)
	}

	// Track per-session return-path goroutines so we can stop them on
	// session eviction. Concrete pump map: fanOutPort → cancel func.
	var pumpsMu sync.Mutex
	pumps := make(map[int]context.CancelFunc)

	// Stop helper: tear down everything when ctx cancels.
	go func() {
		<-ctx.Done()
		_ = publicConn.Close()
		pumpsMu.Lock()
		for _, cancel := range pumps {
			cancel()
		}
		pumpsMu.Unlock()
	}()

	bufPool := sync.Pool{
		New: func() any {
			b := make([]byte, udpReadBufSize)
			return &b
		},
	}

	for {
		bufPtr := bufPool.Get().(*[]byte)
		buf := *bufPtr
		n, srcAddr, readErr := publicConn.ReadFrom(buf)
		if readErr != nil {
			bufPool.Put(bufPtr)
			if errors.Is(readErr, net.ErrClosed) || ctx.Err() != nil {
				return nil
			}
			// transient read error — log + continue (drop this packet)
			log.Printf("ss14-wrapper: UDP read error: %v", readErr)
			continue
		}

		realSrc, payload, parseErr := ParseProxyHeader(buf[:n])
		if parseErr != nil {
			log.Printf("ss14-wrapper: malformed PROXY header from %s (drop): %v",
				srcAddr, parseErr)
			bufPool.Put(bufPtr)
			continue
		}

		sess, isNew, sessErr := store.LookupOrCreate(srcAddr, realSrc)
		if sessErr != nil {
			log.Printf("ss14-wrapper: session alloc failed for %s: %v",
				srcAddr, sessErr)
			bufPool.Put(bufPtr)
			continue
		}

		if isNew {
			pumpCtx, cancel := context.WithCancel(ctx)
			pumpsMu.Lock()
			pumps[sess.FanOutPort] = cancel
			pumpsMu.Unlock()
			go runReturnPump(pumpCtx, sess, publicConn)
		}

		if _, err := sess.FanOut.WriteTo(payload, upstreamUDP); err != nil {
			log.Printf("ss14-wrapper: upstream write failed for %s: %v",
				srcAddr, err)
		}

		bufPool.Put(bufPtr)
	}
}

// runReturnPump pumps datagrams that Robust.Server sends back to the
// session's fan-out socket back out the public listener with the
// original 5-tuple as the destination. One goroutine per active
// session — small at SS14 scale (~256 max connections).
func runReturnPump(ctx context.Context, sess *Session, publicConn net.PacketConn) {
	buf := make([]byte, udpReadBufSize)
	for {
		if ctx.Err() != nil {
			return
		}
		_ = sess.FanOut.SetReadDeadline(time.Now().Add(1 * time.Second))
		n, _, err := sess.FanOut.ReadFrom(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				continue
			}
			log.Printf("ss14-wrapper: return-pump read error (session %d): %v",
				sess.FanOutPort, err)
			continue
		}
		if _, err := publicConn.WriteTo(buf[:n], sess.PublicSrcAddr); err != nil {
			log.Printf("ss14-wrapper: return-pump write error (session %d): %v",
				sess.FanOutPort, err)
		}
	}
}

// ServeTCP runs the public-facing TCP listener. PROXY header is parsed
// once per connection (nginx default behavior, v2 binary per spec
// OQ-03 evidence — autodetected by the same Read entry point).
func ServeTCP(ctx context.Context, listenAddr, upstreamAddr string, store *SessionStore) error {
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return fmt.Errorf("ss14-wrapper: Listen tcp %q: %w", listenAddr, err)
	}
	defer func() { _ = ln.Close() }()

	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) || ctx.Err() != nil {
				return nil
			}
			log.Printf("ss14-wrapper: TCP accept error: %v", err)
			continue
		}
		go handleTCPConn(conn, upstreamAddr, store)
	}
}

// handleTCPConn peels the PROXY header off a single connection then
// bidirectionally copies between the public client and Robust.Server.
func handleTCPConn(client net.Conn, upstreamAddr string, store *SessionStore) {
	defer func() { _ = client.Close() }()

	reader := bufio.NewReader(client)
	hdr, err := proxyproto.Read(reader)
	if err != nil {
		log.Printf("ss14-wrapper: malformed TCP PROXY header from %s (drop): %v",
			client.RemoteAddr(), err)
		return
	}
	if hdr == nil || hdr.SourceAddr == nil {
		log.Printf("ss14-wrapper: empty TCP PROXY header from %s (drop)",
			client.RemoteAddr())
		return
	}

	upstream, err := net.Dial("tcp", upstreamAddr)
	if err != nil {
		log.Printf("ss14-wrapper: TCP upstream dial %q failed: %v", upstreamAddr, err)
		return
	}
	defer func() { _ = upstream.Close() }()

	upstreamLocal, ok := upstream.LocalAddr().(*net.TCPAddr)
	if !ok {
		log.Printf("ss14-wrapper: upstream LocalAddr unexpected type %T",
			upstream.LocalAddr())
		return
	}
	store.AddTCPSession(upstreamLocal.Port, hdr.SourceAddr)
	defer store.RemoveTCPSession(upstreamLocal.Port)

	// Bidirectional copy. Either direction closing tears down the other.
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(upstream, reader)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, upstream)
		done <- struct{}{}
	}()
	<-done
}

// Run wires up the configured listeners (UDP + TCP + UDS API) and
// blocks until ctx is cancelled or any listener fatally errors.
//
// Returns an error for misconfiguration (nil/invalid addresses), so
// callers can fail-fast at the boundary rather than block forever.
func Run(cfg *Config) error {
	if cfg == nil {
		return errors.New("ss14-wrapper: Run requires a non-nil Config")
	}
	if cfg.ListenAddr == "" {
		return ErrMissingListenAddr
	}
	if cfg.UpstreamAddr == "" {
		return ErrMissingUpstreamAddr
	}
	if cfg.SocketPath == "" {
		return ErrMissingSocketPath
	}

	upstreamUDP, err := net.ResolveUDPAddr("udp", cfg.UpstreamAddr)
	if err != nil {
		return fmt.Errorf("ss14-wrapper: resolve upstream %q: %w",
			cfg.UpstreamAddr, err)
	}

	ttl := cfg.SessionTTL
	if ttl == 0 {
		ttl = 120 * time.Second
	}
	store := NewSessionStore(ttl, upstreamUDP)

	// Best-effort: remove any stale socket file from a prior crashed run.
	// If the path is in use by an actual listener, the bind will fail
	// below and we surface that.
	_ = removeSocketIfStale(cfg.SocketPath)

	udsLn, err := net.Listen("unix", cfg.SocketPath)
	if err != nil {
		return fmt.Errorf("ss14-wrapper: listen UDS %q: %w", cfg.SocketPath, err)
	}
	defer func() { _ = udsLn.Close() }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Janitor goroutine: evict expired sessions every TTL/4.
	go runJanitor(ctx, store, ttl)

	apiSrv := NewAPIServer(store)
	errCh := make(chan error, 3)

	go func() { errCh <- ServeUDP(ctx, cfg.ListenAddr, cfg.UpstreamAddr, store) }()
	go func() { errCh <- ServeTCP(ctx, cfg.ListenAddr, cfg.UpstreamAddr, store) }()
	go func() { errCh <- apiSrv.Serve(udsLn) }()

	// Block on the first error from any listener. Cancel ctx to tear
	// down the rest cleanly.
	firstErr := <-errCh
	cancel()
	// Drain the remaining errors so goroutines don't leak.
	for i := 0; i < 2; i++ {
		<-errCh
	}
	if firstErr != nil && !errors.Is(firstErr, net.ErrClosed) {
		return firstErr
	}
	return nil
}

// removeSocketIfStale unlinks a unix socket file if one exists at the
// given path. Caller's bind will fail if the path is actually held.
func removeSocketIfStale(path string) error {
	conn, err := net.Dial("unix", path)
	if err == nil {
		_ = conn.Close()
		return errors.New("socket already in use")
	}
	// best-effort unlink — ignore "not exist" / "permission" results
	_ = removeFile(path)
	return nil
}

// removeFile is split out so tests can stub it if needed.
var removeFile = func(path string) error {
	return os.Remove(path)
}

func runJanitor(ctx context.Context, store *SessionStore, ttl time.Duration) {
	interval := ttl / 4
	if interval < time.Second {
		interval = time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = store.EvictExpired()
		}
	}
}
