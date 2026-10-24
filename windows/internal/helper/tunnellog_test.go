package helper

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTunnelLogKeepsTheLastLinesWhenItGrowsPastTheLimit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tunnel.log")
	l := newTunnelLog(path)
	line := strings.Repeat("x", 200)
	for i := 0; i < 3000; i++ { // 3000 lines of about 230 bytes: well past 256 KB
		l.Logf("DEBUG: %d %s", i, line)
	}
	raw, _ := os.ReadFile(path)
	if len(raw) > tunnelLogLimit+1024 {
		t.Fatalf("the log is %d bytes", len(raw))
	}
	lines := l.Tail(10000)
	if len(lines) > 3000 || len(lines) < tunnelLogKeep {
		t.Fatalf("%d lines kept", len(lines))
	}
	if last := lines[len(lines)-1]; !strings.Contains(last, " 2999 ") {
		t.Errorf("the newest line is gone: %q", last[:40])
	}
	// The cut leaves exactly the last 400 at the moment of the cut; the lines after it are added.
	if first := lines[0]; strings.Contains(first, "DEBUG: 0 ") {
		t.Errorf("the oldest line stayed")
	}
}

func TestTheLogOfTheLastRunIsPutAsideAtTheStart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tunnel.log")
	first := newTunnelLog(path)
	first.Mark("up")
	first.Mark("daemon-exited")
	second := newTunnelLog(path) // the service starts again
	if marks := second.Marks(10); len(marks) != 0 {
		t.Errorf("the marks of the last run are in this run's file: %v", marks)
	}
	second.Mark("up")
	if marks := second.Marks(10); len(marks) != 1 || !strings.HasSuffix(marks[0], "NIMB: up") {
		t.Errorf("%v", marks)
	}
	prev, _ := os.ReadFile(filepath.Join(filepath.Dir(path), "tunnel-previous.log"))
	if !strings.Contains(string(prev), "NIMB: daemon-exited") {
		t.Errorf("the last run is not kept: %q", prev)
	}
}

func TestTunnelLogMarksAndTail(t *testing.T) {
	l := newTunnelLog(filepath.Join(t.TempDir(), "tunnel.log"))
	if got := l.Tail(5); got != nil {
		t.Errorf("no file: %v", got)
	}
	l.Mark("up")
	l.Mark("daemon-exited")
	l.Mark("restarting")
	l.Mark("restarted")
	got := l.Tail(2)
	if len(got) != 2 || !strings.HasSuffix(got[0], " NIMB: restarting") || !strings.HasSuffix(got[1], " NIMB: restarted") {
		t.Errorf("%v", got)
	}
}

func TestTunnelLogMarksAreFoundFarBackAmongTheLinesOfTheDaemon(t *testing.T) {
	l := newTunnelLog(filepath.Join(t.TempDir(), "tunnel.log"))
	l.Mark("up")
	for i := 0; i < 100; i++ {
		l.Logf("DEBUG: keepalive %d", i)
	}
	l.Mark("daemon-exited")
	for i := 0; i < 100; i++ {
		l.Logf("DEBUG: keepalive %d", i)
	}
	marks := l.Marks(10)
	if len(marks) != 2 || !strings.HasSuffix(marks[0], "NIMB: up") || !strings.HasSuffix(marks[1], "NIMB: daemon-exited") {
		t.Errorf("%v", marks)
	}
	if len(l.Marks(1)) != 1 {
		t.Error("only the last n")
	}
}
