// Package ipc is the talk between the window of Nimb and its service. The set of commands is closed, like the lines of the
// sudoers file on the Mac: a command is a name from the list below, nothing else comes from the window. No path, no file
// name, no command line, no settings of a tunnel travels this way, so the worst the window (or any program of the same person)
// can do is switch the tunnel on and off.
//
// One request is one line of JSON, the answer is one line of JSON, and then the connection is closed.
package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// The commands.
const (
	Ping             = "ping"
	Status           = "status"
	TunnelUp         = "tunnel.up"
	TunnelDown       = "tunnel.down"
	TunnelUnregister = "tunnel.unregister"
	DNSSet           = "dns.set"     // takes the ID of a provider from the list of the service
	DNSRestore       = "dns.restore" // gives the DNS of the adapters back
	Diag             = "diag"        // facts of the service for a report about a problem (no keys)
)

var known = map[string]bool{
	Ping: true, Status: true, TunnelUp: true, TunnelDown: true, TunnelUnregister: true, DNSSet: true, DNSRestore: true, Diag: true,
}

// MaxLine is the longest line the service reads.
const MaxLine = 4096

// Request is what the window sends.
type Request struct {
	Cmd string `json:"cmd"`
	// Provider is the ID of a Smart DNS provider, only for dns.set. The service has its own list and takes no addresses.
	Provider string `json:"provider,omitempty"`
}

// Response is what the service answers.
type Response struct {
	OK     bool          `json:"ok"`
	Error  string        `json:"error,omitempty"` // worded for the person
	Tunnel *TunnelStatus `json:"tunnel,omitempty"`
	DNS    *DNSStatus    `json:"dns,omitempty"`
	// Lines answer the command diag; Version is the version of the service.
	Lines   []string `json:"lines,omitempty"`
	Version string   `json:"version,omitempty"`
	// TunnelLog answers the command diag: the last lines of the log of the program of the tunnel (no keys, the window cleans the addresses).
	TunnelLog []string `json:"tunnelLog,omitempty"`
	// TunnelMarks are the lines of that log that the service itself wrote (up, daemon-exited, restarting, restarted, ...), from further back.
	TunnelMarks []string `json:"tunnelMarks,omitempty"`
}

// DNSStatus is the state of Smart DNS.
type DNSStatus struct {
	Active   bool   `json:"active"`
	Provider string `json:"provider,omitempty"`
}

// TunnelStatus is the state of the tunnel.
type TunnelStatus struct {
	Up bool `json:"up"`
	// HandshakeAgo is how many seconds ago the server last answered; -1 when it has not.
	HandshakeAgo int   `json:"handshakeAgo"`
	Received     int64 `json:"received"`
	Sent         int64 `json:"sent"`
	HasAccount   bool  `json:"hasAccount"`
	// DroppedAt is the unix time at which the service took the tunnel down by itself (the server stopped answering), or 0; the
	// window tells the person once. It stays until the tunnel is brought up again.
	DroppedAt  int64  `json:"droppedAt,omitempty"`
	DropReason string `json:"dropReason,omitempty"`
	// Restarting says that the program of the tunnel ended by itself and the service is starting it again; Up is true then, so that the
	// switch of the window does not blink. Restarts are the unix times of the restarts of the last day.
	Restarting bool    `json:"restarting,omitempty"`
	Restarts   []int64 `json:"restarts,omitempty"`
}

// Handler does what a command asks.
type Handler interface {
	Handle(ctx context.Context, req Request) Response
}

// Serve answers the connections of the listener until the context ends. Commands run one at a time.
func Serve(ctx context.Context, l net.Listener, h Handler) error {
	go func() {
		<-ctx.Done()
		l.Close()
	}()
	var mu sync.Mutex
	for {
		conn, err := l.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return err
		}
		go func() {
			defer conn.Close()
			serveOne(ctx, conn, h, &mu)
		}()
	}
}

func serveOne(ctx context.Context, conn net.Conn, h Handler, mu *sync.Mutex) {
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	line, err := readLine(conn)
	if err != nil {
		write(conn, Response{Error: "запрос не прочитан"})
		return
	}
	var req Request
	if err := json.Unmarshal(line, &req); err != nil || !known[req.Cmd] || (req.Provider != "" && req.Cmd != DNSSet) {
		write(conn, Response{Error: "неизвестная команда"})
		return
	}
	mu.Lock()
	resp := safely(ctx, h, req)
	mu.Unlock()
	write(conn, resp)
}

// safely keeps a mistake in one command from taking the service down.
func safely(ctx context.Context, h Handler, req Request) (resp Response) {
	defer func() {
		if r := recover(); r != nil {
			resp = Response{Error: "внутренняя ошибка службы"}
		}
	}()
	return h.Handle(ctx, req)
}

func readLine(r io.Reader) ([]byte, error) {
	br := bufio.NewReaderSize(io.LimitReader(r, MaxLine+1), MaxLine+1)
	line, err := br.ReadBytes('\n')
	if len(line) > MaxLine {
		return nil, errors.New("слишком длинный запрос")
	}
	if err != nil && !(errors.Is(err, io.EOF) && len(line) > 0) {
		return nil, err
	}
	return line, nil
}

func write(conn net.Conn, resp Response) {
	conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	b, _ := json.Marshal(resp)
	conn.Write(append(b, '\n'))
}

// Call sends one command over the connection and reads the answer. A command may take long (the tunnel waits for the
// server for up to 16 seconds), so the wait is generous.
func Call(conn net.Conn, req Request) (Response, error) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(60 * time.Second))
	b, _ := json.Marshal(req)
	if _, err := conn.Write(append(b, '\n')); err != nil {
		return Response{}, fmt.Errorf("служба не отвечает: %w", err)
	}
	line, err := bufio.NewReader(io.LimitReader(conn, 1<<20)).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return Response{}, fmt.Errorf("служба не отвечает: %w", err)
	}
	var resp Response
	if err := json.Unmarshal(line, &resp); err != nil {
		return Response{}, errors.New("служба ответила непонятно")
	}
	return resp, nil
}
