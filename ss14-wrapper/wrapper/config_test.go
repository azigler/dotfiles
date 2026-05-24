package wrapper_test

import (
	"testing"
	"time"

	"github.com/azigler/dotfiles/ss14-wrapper/wrapper"
	"github.com/stretchr/testify/require"
)

// TEST: LoadConfigFromEnv populates all four fields from the
// SS14_WRAPPER_* env vars (per spec dotfiles-9g1 §4.4 plist
// EnvironmentVariables block).
func TestLoadConfigFromEnv_AllFields(t *testing.T) {
	t.Setenv("SS14_WRAPPER_LISTEN", "100.95.4.73:1212")
	t.Setenv("SS14_WRAPPER_UPSTREAM", "127.0.0.1:1213")
	t.Setenv("SS14_WRAPPER_SOCK", "/Users/pico/run/ss14-wrapper.sock")
	t.Setenv("SS14_WRAPPER_LOG", "/Users/pico/Library/Logs/ss14-wrapper.log")

	cfg, err := wrapper.LoadConfigFromEnv()

	require.NoError(t, err)
	require.NotNil(t, cfg)
	require.Equal(t, "100.95.4.73:1212", cfg.ListenAddr)
	require.Equal(t, "127.0.0.1:1213", cfg.UpstreamAddr)
	require.Equal(t, "/Users/pico/run/ss14-wrapper.sock", cfg.SocketPath)
	require.Equal(t, "/Users/pico/Library/Logs/ss14-wrapper.log", cfg.LogPath)
}

// TEST: ListenAddr unset → ErrMissingListenAddr.
func TestLoadConfigFromEnv_MissingListen(t *testing.T) {
	t.Setenv("SS14_WRAPPER_LISTEN", "")
	t.Setenv("SS14_WRAPPER_UPSTREAM", "127.0.0.1:1213")
	t.Setenv("SS14_WRAPPER_SOCK", "/tmp/test.sock")

	_, err := wrapper.LoadConfigFromEnv()

	require.ErrorIs(t, err, wrapper.ErrMissingListenAddr,
		"missing SS14_WRAPPER_LISTEN must surface as ErrMissingListenAddr")
}

// TEST: UpstreamAddr unset → ErrMissingUpstreamAddr.
func TestLoadConfigFromEnv_MissingUpstream(t *testing.T) {
	t.Setenv("SS14_WRAPPER_LISTEN", "100.95.4.73:1212")
	t.Setenv("SS14_WRAPPER_UPSTREAM", "")
	t.Setenv("SS14_WRAPPER_SOCK", "/tmp/test.sock")

	_, err := wrapper.LoadConfigFromEnv()

	require.ErrorIs(t, err, wrapper.ErrMissingUpstreamAddr,
		"missing SS14_WRAPPER_UPSTREAM must surface as ErrMissingUpstreamAddr")
}

// TEST: SocketPath unset → ErrMissingSocketPath.
func TestLoadConfigFromEnv_MissingSocket(t *testing.T) {
	t.Setenv("SS14_WRAPPER_LISTEN", "100.95.4.73:1212")
	t.Setenv("SS14_WRAPPER_UPSTREAM", "127.0.0.1:1213")
	t.Setenv("SS14_WRAPPER_SOCK", "")

	_, err := wrapper.LoadConfigFromEnv()

	require.ErrorIs(t, err, wrapper.ErrMissingSocketPath,
		"missing SS14_WRAPPER_SOCK must surface as ErrMissingSocketPath")
}

// TEST: default SessionTTL when no override is provided matches the
// nginx proxy_timeout of 120s per spec §4.1 (OQ-01 decision).
func TestLoadConfigFromEnv_DefaultTTL(t *testing.T) {
	t.Setenv("SS14_WRAPPER_LISTEN", "100.95.4.73:1212")
	t.Setenv("SS14_WRAPPER_UPSTREAM", "127.0.0.1:1213")
	t.Setenv("SS14_WRAPPER_SOCK", "/tmp/test.sock")

	cfg, err := wrapper.LoadConfigFromEnv()

	require.NoError(t, err)
	require.Equal(t, 120*time.Second, cfg.SessionTTL,
		"default SessionTTL must match nginx proxy_timeout 120s (spec §4.1)")
}

// TEST (delegation-assertion): Run() delegates the listener-stack
// startup to ServeUDP/ServeTCP/APIServer.Serve — it must NOT swallow
// a bad config silently. If the impl agent ships Run() as `return
// nil` (no-op), this test fails because a wholly invalid config
// would still get accepted.
//
// We cannot easily spy on internal listener funcs from outside the
// package; instead we verify the boundary contract: Run with a nil
// config must error (it cannot construct listeners from nothing).
func TestRun_NilConfig_Errors(t *testing.T) {
	err := wrapper.Run(nil)

	require.Error(t, err,
		"Run(nil) must error — a no-op stub that returns nil would silently "+
			"accept misconfiguration")
}

// TEST (delegation-assertion): Run() with an obviously-invalid
// ListenAddr returns an error rather than blocking forever or
// silently passing.
func TestRun_InvalidListenAddr(t *testing.T) {
	cfg := &wrapper.Config{
		ListenAddr:   "not-a-real-address:::",
		UpstreamAddr: "127.0.0.1:1213",
		SocketPath:   "/tmp/ss14-wrapper-test.sock",
		SessionTTL:   120 * time.Second,
	}

	err := wrapper.Run(cfg)

	require.Error(t, err,
		"Run with a syntactically-invalid ListenAddr must surface an error "+
			"from the underlying net.Listen / net.ListenPacket call")
}
