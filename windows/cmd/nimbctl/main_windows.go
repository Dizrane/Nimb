//go:build windows

// nimbctl talks to the service of Nimb from a console, for testing:
//
//	nimbctl ping | status | up | down | unregister
//	nimbctl dns <provider id>     Smart DNS on (geohide-eu, comss, geohide, geohide-us)
//	nimbctl dns-off               Smart DNS off
package main

import (
	"fmt"
	"os"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/ipc"
)

func request(args []string) (ipc.Request, bool) {
	if len(args) == 2 && args[0] == "dns" {
		return ipc.Request{Cmd: ipc.DNSSet, Provider: args[1]}, true
	}
	if len(args) != 1 {
		return ipc.Request{}, false
	}
	switch args[0] {
	case "ping":
		return ipc.Request{Cmd: ipc.Ping}, true
	case "status":
		return ipc.Request{Cmd: ipc.Status}, true
	case "up":
		return ipc.Request{Cmd: ipc.TunnelUp}, true
	case "down":
		return ipc.Request{Cmd: ipc.TunnelDown}, true
	case "unregister":
		return ipc.Request{Cmd: ipc.TunnelUnregister}, true
	case "dns-off":
		return ipc.Request{Cmd: ipc.DNSRestore}, true
	}
	return ipc.Request{}, false
}

func main() {
	req, ok := request(os.Args[1:])
	if !ok {
		fmt.Fprintln(os.Stderr, "usage: nimbctl ping | status | up | down | unregister | dns <provider> | dns-off")
		os.Exit(2)
	}
	conn, err := ipc.Dial(5 * time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, "the service does not answer:", err)
		os.Exit(1)
	}
	resp, err := ipc.Call(conn, req)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if t := resp.Tunnel; t != nil {
		fmt.Printf("tunnel: up=%v handshakeAgo=%ds received=%d sent=%d account=%v\n", t.Up, t.HandshakeAgo, t.Received, t.Sent, t.HasAccount)
	}
	if d := resp.DNS; d != nil {
		fmt.Printf("dns: active=%v provider=%s\n", d.Active, d.Provider)
	}
	if !resp.OK {
		fmt.Fprintln(os.Stderr, "error:", resp.Error)
		os.Exit(1)
	}
	fmt.Println("ok")
}
