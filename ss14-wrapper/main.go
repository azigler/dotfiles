// Package main is the entrypoint for the ss14-wrapper daemon.
//
// The wrapper sits between nginx (which strips real client IPs from
// proxied UDP+TCP traffic and replaces them with PROXY-protocol
// headers) and Robust.Server (which expects plain UDP+TCP and reads
// peer IPs via Lidgren's NetConnection.RemoteEndPoint). Per spec
// dotfiles-9g1 §4.2.
//
// Configuration is taken entirely from environment variables (see
// wrapper.LoadConfigFromEnv); the LaunchAgent plist on pico supplies
// them per spec §4.4.
package main

import (
	"fmt"
	"log"
	"os"

	"github.com/azigler/dotfiles/ss14-wrapper/wrapper"
)

func main() {
	cfg, err := wrapper.LoadConfigFromEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ss14-wrapper: bad config: %v\n", err)
		os.Exit(2)
	}

	log.SetPrefix("ss14-wrapper: ")
	log.Printf("starting — listen=%s upstream=%s sock=%s ttl=%s",
		cfg.ListenAddr, cfg.UpstreamAddr, cfg.SocketPath, cfg.SessionTTL)

	if err := wrapper.Run(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "ss14-wrapper: %v\n", err)
		os.Exit(1)
	}
}
