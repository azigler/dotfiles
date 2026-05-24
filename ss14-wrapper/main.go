// Package main is the entrypoint for the ss14-wrapper daemon.
//
// The wrapper sits between nginx (which strips real client IPs from
// proxied UDP+TCP traffic and replaces them with PROXY-protocol
// headers) and Robust.Server (which expects plain UDP+TCP and reads
// peer IPs via Lidgren's NetConnection.RemoteEndPoint).
//
// Per spec dotfiles-9g1 §4.2. THIS FILE IS A STUB — /impl wave fills
// it in. The tests in this package import the real symbols (see
// /test SKILL Step 1) and fail at assertions, not at compile time.
package main

import (
	"fmt"
	"os"

	"github.com/azigler/dotfiles/ss14-wrapper/wrapper"
)

func main() {
	cfg, err := wrapper.LoadConfigFromEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ss14-wrapper: bad config: %v\n", err)
		os.Exit(2)
	}
	// Stub: real run loop ships in /impl wave. This call returns
	// ErrNotImplemented so the binary exits non-zero — preventing it
	// from being mistaken for a working daemon if shipped before impl.
	if err := wrapper.Run(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "ss14-wrapper: %v\n", err)
		os.Exit(1)
	}
}
