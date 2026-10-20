//go:build windows

// nimbctl talks to the service of Nimb from a console, for testing: nimbctl ping | status | up | down | unregister.
package main

import (
	"fmt"
	"os"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/ipc"
)

var commands = map[string]string{
	"ping": ipc.Ping, "status": ipc.Status, "up": ipc.TunnelUp, "down": ipc.TunnelDown, "unregister": ipc.TunnelUnregister,
}

func main() {
	if len(os.Args) != 2 || commands[os.Args[1]] == "" {
		fmt.Fprintln(os.Stderr, "usage: nimbctl ping | status | up | down | unregister")
		os.Exit(2)
	}
	conn, err := ipc.Dial(5 * time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, "the service does not answer:", err)
		os.Exit(1)
	}
	resp, err := ipc.Call(conn, commands[os.Args[1]])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if t := resp.Tunnel; t != nil {
		fmt.Printf("tunnel: up=%v handshakeAgo=%ds received=%d sent=%d account=%v\n", t.Up, t.HandshakeAgo, t.Received, t.Sent, t.HasAccount)
	}
	if !resp.OK {
		fmt.Fprintln(os.Stderr, "error:", resp.Error)
		os.Exit(1)
	}
	fmt.Println("ok")
}
