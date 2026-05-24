package wrapper

import (
	"errors"
	"os"
	"strconv"
	"time"
)

// Config holds the wrapper daemon's runtime parameters. Sourced from
// environment variables set by the LaunchAgent plist (per spec
// dotfiles-9g1 §4.4).
type Config struct {
	// ListenAddr is the public-facing tailnet IP:port (e.g.
	// "100.95.4.73:1212"). The wrapper binds UDP and TCP both here.
	ListenAddr string

	// UpstreamAddr is the Robust.Server bind (always loopback per
	// spec §4.5 — e.g. "127.0.0.1:1213").
	UpstreamAddr string

	// SocketPath is the UDS path the wrapper exposes its LOOKUP /
	// ENUMERATE / HEALTH API on (e.g. "/Users/pico/run/ss14-wrapper.sock").
	SocketPath string

	// SessionTTL is how long an idle session lives before eviction.
	// Matches nginx's proxy_timeout per spec §4.1 (120s default).
	SessionTTL time.Duration

	// LogPath is the wrapper's structured-log destination (best-effort).
	LogPath string
}

// ErrMissingListenAddr is returned when SS14_WRAPPER_LISTEN is unset.
var ErrMissingListenAddr = errors.New("SS14_WRAPPER_LISTEN must be set")

// ErrMissingUpstreamAddr is returned when SS14_WRAPPER_UPSTREAM is unset.
var ErrMissingUpstreamAddr = errors.New("SS14_WRAPPER_UPSTREAM must be set")

// ErrMissingSocketPath is returned when SS14_WRAPPER_SOCK is unset.
var ErrMissingSocketPath = errors.New("SS14_WRAPPER_SOCK must be set")

// defaultSessionTTL matches the nginx proxy_timeout 120s decision
// from spec §4.1 (OQ-01 decided 2026-05-24 via /check dotfiles-9cj).
const defaultSessionTTL = 120 * time.Second

// LoadConfigFromEnv reads the SS14_WRAPPER_* environment variables
// and returns a populated Config. Validates that the three required
// vars are non-empty. SessionTTL defaults to 120s (spec §4.1) but can
// be overridden via SS14_WRAPPER_TTL_SECONDS for testing.
func LoadConfigFromEnv() (*Config, error) {
	listen := os.Getenv("SS14_WRAPPER_LISTEN")
	if listen == "" {
		return nil, ErrMissingListenAddr
	}
	upstream := os.Getenv("SS14_WRAPPER_UPSTREAM")
	if upstream == "" {
		return nil, ErrMissingUpstreamAddr
	}
	sock := os.Getenv("SS14_WRAPPER_SOCK")
	if sock == "" {
		return nil, ErrMissingSocketPath
	}

	ttl := defaultSessionTTL
	if v := os.Getenv("SS14_WRAPPER_TTL_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			ttl = time.Duration(n) * time.Second
		}
	}

	return &Config{
		ListenAddr:   listen,
		UpstreamAddr: upstream,
		SocketPath:   sock,
		SessionTTL:   ttl,
		LogPath:      os.Getenv("SS14_WRAPPER_LOG"),
	}, nil
}
