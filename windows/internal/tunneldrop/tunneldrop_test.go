package tunneldrop

import (
	"strings"
	"testing"
	"time"
)

var t0 = time.Unix(1_800_000_000, 0)

func TestTheNoteIsReadAndToldOnce(t *testing.T) {
	n, ok := ParseNote("1800000000 daemon-exited\n")
	if !ok || !n.When.Equal(t0) || n.Reason != DaemonExited {
		t.Fatalf("%+v %v", n, ok)
	}
	if n.Format() != "1800000000 daemon-exited\n" {
		t.Errorf("format %q", n.Format())
	}
	if n, ok := ParseNote("1800000000"); !ok || n.Reason != "" {
		t.Error("a note without a reason is still a note")
	}
	for _, bad := range []string{"", "daemon-exited", "0 daemon-exited", "-5 x", "abc def", "01800000000 x"} {
		if _, ok := ParseNote(bad); ok {
			t.Errorf("%q is not a note", bad)
		}
	}
	now := t0.Add(time.Minute)
	if !IsNews(t0, 0, now) || IsNews(t0, t0.Unix(), now) {
		t.Error("a note is told once")
	}
	if !IsNews(t0.Add(time.Hour), t0.Unix(), now.Add(2*time.Hour)) {
		t.Error("a later stop is news again")
	}
	if IsNews(t0, 0, t0.Add(NewsFor+time.Second)) {
		t.Error("an old note is history")
	}
}

func TestTheWordsFollowTheReason(t *testing.T) {
	if m := MessageFor(DaemonExited); !strings.Contains(m, "программа неожиданно завершилась") || strings.Contains(m, "Cloudflare") {
		t.Errorf("%q", m)
	}
	if m := MessageFor(NoHandshake); !strings.Contains(m, "Cloudflare не отвечал") {
		t.Errorf("a note of the old kind keeps its words: %q", m)
	}
	if MessageFor("") != MessageFor(DaemonExited) {
		t.Error("a note without a reason is told as the new kind")
	}
}

func TestTheEndOfTheProgramIsUnexpected(t *testing.T) {
	stop, exited := make(chan struct{}), make(chan struct{})
	close(exited)
	if !Unexpected(stop, exited) {
		t.Error("the program ended by itself: a note and the routes back")
	}
}

func TestSwitchingOffByHandLeavesNoNote(t *testing.T) {
	// the person turns the tunnel off: stop is closed first, then the program ends because of it
	stop, exited := make(chan struct{}), make(chan struct{})
	close(stop)
	close(exited)
	if Unexpected(stop, exited) {
		t.Error("a switching off by the person is not a stop by itself")
	}
	stop2 := make(chan struct{})
	done := make(chan bool)
	go func() { done <- Unexpected(stop2, make(chan struct{})) }()
	close(stop2)
	select {
	case got := <-done:
		if got {
			t.Error("stop alone")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("did not return after stop")
	}
}

// The silence of the server does nothing: there is no clock in this package, and nothing here ends a tunnel for any time.
func TestNothingEndsATunnelByTime(t *testing.T) {
	stop, exited := make(chan struct{}), make(chan struct{})
	done := make(chan bool, 1)
	go func() { done <- Unexpected(stop, exited) }()
	select {
	case <-done:
		t.Fatal("it ended with neither a stop nor an end of the program")
	case <-time.After(300 * time.Millisecond):
	}
	close(stop)
	<-done
}
