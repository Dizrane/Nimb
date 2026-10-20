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
)

var known = map[string]bool{Ping: true, Status: true, TunnelUp: true, TunnelDown: true, TunnelUnregister: true}

// MaxLine is the longest line the service reads.
const MaxLine = 4096

// Request is what the window sends.
type Request struct {
	Cmd string `json:"cmd"`
}

// Response is what the service answers.
type Response struct {
	OK     bool          `json:"ok"`
	Error  string        `json:"error,omitempty"` // worded for the person
	Tunnel *TunnelStatus `json:"tunnel,omitempty"`
}

// TunnelStatus is the state of the tunnel.
type TunnelStatus struct {
	Up bool `json:"up"`
	// HandshakeAgo is how many seconds ago the server last answered; -1 when it has not.
	HandshakeAgo int   `json:"handshakeAgo"`
	Received     int64 `json:"received"`
	Sent         int64 `json:"sent"`
	HasAccount   bool  `json:"hasAccount"`
}

// Handler does what a command asks.
type Handler interface {
	Handle(ctx context.Context, cmd string) Response
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
	if err := json.Unmarshal(line, &req); err != nil || !known[req.Cmd] {
		write(conn, Response{Error: "неизвестная команда"})
		return
	}
	mu.Lock()
	resp := safely(ctx, h, req.Cmd)
	mu.Unlock()
	write(conn, resp)
}

// safely keeps a mistake in one command from taking the service down.
func safely(ctx context.Context, h Handler, cmd string) (resp Response) {
	defer func() {
		if r := recover(); r != nil {
			resp = Response{Error: "внутренняя ошибка службы"}
		}
	}()
	return h.Handle(ctx, cmd)
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
func Call(conn net.Conn, cmd string) (Response, error) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(60 * time.Second))
	b, _ := json.Marshal(Request{Cmd: cmd})
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
