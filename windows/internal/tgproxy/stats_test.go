package tgproxy

import (
	"fmt"
	"net"
	"testing"
	"time"
)

func startTestEngine(t *testing.T) (*Engine, uint16) {
	t.Helper()
	e, err := New("0123456789abcdef0123456789abcdef", Config{})
	if err != nil {
		t.Fatal(err)
	}
	port, err := e.Start(0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(e.Stop)
	return e, port
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("did not happen: %s", what)
}

func TestAClientThatLeavesBeforeTheHandshakeIsNotAFailure(t *testing.T) {
	e, port := startTestEngine(t)
	for i := 0; i < 5; i++ {
		c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Fatal(err)
		}
		c.Close() // Telegram opens a connection ahead and drops it
	}
	waitFor(t, "five connections told", func() bool { s := e.Stats(); return s.Total == 5 && s.Active == 0 })
	if s := e.Stats(); s.Failures != 0 || s.Aborted != 5 {
		t.Errorf("failures %d, aborted %d: %+v", s.Failures, s.Aborted, s)
	}
}

func TestWhatTheStopClosesDoesNotLandInTheNumbersOfTheNextStart(t *testing.T) {
	e, port := startTestEngine(t)
	var open []net.Conn
	for i := 0; i < 6; i++ {
		c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Fatal(err)
		}
		open = append(open, c) // connected, saying nothing: the proxy waits for the handshake
	}
	defer func() {
		for _, c := range open {
			c.Close()
		}
	}()
	waitFor(t, "six connections open", func() bool { return e.Stats().Active == 6 })
	e.Stop()
	if _, err := e.Start(0); err != nil { // the quick off and on of a person
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond) // the handlers of the old start unwind now
	if s := e.Stats(); s.Total != 0 || s.Active != 0 || s.Failures != 0 || s.Aborted != 0 {
		t.Errorf("the closed connections of the old start changed the new numbers: %+v", s)
	}
}

func TestANewConnectionAfterTheRestartIsCountedFromZero(t *testing.T) {
	e, _ := startTestEngine(t)
	e.Stop()
	port, err := e.Start(0)
	if err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, "one connection", func() bool { return e.Stats().Total == 1 && e.Stats().Active == 1 })
	c.Close()
	waitFor(t, "it is gone", func() bool { return e.Stats().Active == 0 })
	if s := e.Stats(); s.Total != 1 || s.Failures != 0 {
		t.Errorf("%+v", s)
	}
}
