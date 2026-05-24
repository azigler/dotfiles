package wrapper

import (
	"errors"
	"os"
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
	// Matches nginx's proxy_timeout per spec §4.1 (120s).
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

// LoadConfigFromEnv reads the SS14_WRAPPER_* environment variables and
// returns a populated Config. STUB — /impl wave replaces with the real
// loader. Currently returns an empty Config + nil to keep main.go
// compiling; tests assert the real validation contract.
func LoadConfigFromEnv() (*Config, error) {
	listen := os.Getenv("SS14_WRAPPER_LISTEN")
	upstream := os.Getenv("SS14_WRAPPER_UPSTREAM")
	sock := os.Getenv("SS14_WRAPPER_SOCK")
	logp := os.Getenv("SS14_WRAPPER_LOG")
	_ = listen
	_ = upstream
	_ = sock
	_ = logp
	// STUB: tests expect real validation; this body is intentionally
	// minimal so the package compiles. /impl wave fills in.
	return &Config{}, nil
}
