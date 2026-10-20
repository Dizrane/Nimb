package ipc

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"
)

type fake struct{ calls []string }

func (f *fake) Handle(_ context.Context, req Request) Response {
	f.calls = append(f.calls, req.Cmd+" "+req.Provider)
	if req.Cmd == TunnelUp {
		panic("a bug in a command")
	}
	return Response{OK: true, Tunnel: &TunnelStatus{Up: req.Cmd == Status, HandshakeAgo: -1}}
}

func start(t *testing.T) (*fake, string) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fake{}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Serve(ctx, l, f); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	return f, l.Addr().String()
}

func call(t *testing.T, addr, raw string) string {
	t.Helper()
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	c.Write([]byte(raw))
	buf := make([]byte, 4096)
	n, _ := c.Read(buf)
	return string(buf[:n])
}

func TestKnownCommandsAreAnswered(t *testing.T) {
	f, addr := start(t)
	c, _ := net.Dial("tcp", addr)
	resp, err := Call(c, Request{Cmd: Status})
	if err != nil || !resp.OK || resp.Tunnel == nil || !resp.Tunnel.Up {
		t.Fatalf("resp=%+v err=%v", resp, err)
	}
	if len(f.calls) != 1 || f.calls[0] != "status " {
		t.Fatalf("calls=%v", f.calls)
	}
}

func TestOnlyTheClosedSetOfCommandsGetsThrough(t *testing.T) {
	f, addr := start(t)
	for _, raw := range []string{
		`{"cmd":"cmd.exe /c calc"}` + "\n",
		`{"cmd":"tunnel.up","path":"C:\\x.conf"}` + "x\n", // not valid JSON
		`{"cmd":""}` + "\n",
		`not json` + "\n",
		`{"cmd":"TUNNEL.UP"}` + "\n",
		strings.Repeat("a", MaxLine+10) + "\n",
		`{"cmd":"ping","provider":"geohide"}` + "\n", // a provider only goes with dns.set
	} {
		out := call(t, addr, raw)
		if !strings.Contains(out, `"error"`) {
			t.Errorf("%q should be refused, got %q", raw[:min(len(raw), 40)], out)
		}
	}
	if len(f.calls) != 0 {
		t.Fatalf("the handler must not be called, calls=%v", f.calls)
	}
}

func TestAMistakeInACommandDoesNotTakeTheServiceDown(t *testing.T) {
	_, addr := start(t)
	if out := call(t, addr, `{"cmd":"tunnel.up"}`+"\n"); !strings.Contains(out, "внутренняя ошибка") {
		t.Fatalf("got %q", out)
	}
	if out := call(t, addr, `{"cmd":"ping"}`+"\n"); !strings.Contains(out, `"ok":true`) {
		t.Fatalf("the service must still answer, got %q", out)
	}
}

func TestARequestWithoutANewlineStillWorks(t *testing.T) {
	_, addr := start(t)
	c, _ := net.Dial("tcp", addr)
	c.Write([]byte(`{"cmd":"ping"}`))
	c.(*net.TCPConn).CloseWrite()
	buf := make([]byte, 512)
	c.SetDeadline(time.Now().Add(5 * time.Second))
	n, _ := c.Read(buf)
	if !strings.Contains(string(buf[:n]), `"ok":true`) {
		t.Fatalf("got %q", buf[:n])
	}
}

func TestAProviderGoesOnlyWithDNSSet(t *testing.T) {
	f, addr := start(t)
	if out := call(t, addr, `{"cmd":"dns.set","provider":"geohide"}`+"\n"); !strings.Contains(out, `"ok":true`) {
		t.Fatalf("got %q", out)
	}
	if len(f.calls) != 1 || f.calls[0] != "dns.set geohide" {
		t.Fatalf("calls=%v", f.calls)
	}
}
