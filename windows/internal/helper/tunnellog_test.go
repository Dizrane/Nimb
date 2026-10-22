package helper

import (
	"fmt"
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

func TestTunnelLogTrimsAnOldBigFileAtOpen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tunnel.log")
	var b strings.Builder
	for i := 0; i < 2000; i++ {
		fmt.Fprintf(&b, "line %d %s\n", i, strings.Repeat("y", 200))
	}
	os.WriteFile(path, []byte(b.String()), 0o600)
	l := newTunnelLog(path)
	lines := l.Tail(10000)
	if len(lines) != tunnelLogKeep || !strings.HasPrefix(lines[len(lines)-1], "line 1999 ") || !strings.HasPrefix(lines[0], "line 1600 ") {
		t.Errorf("%d lines, first %q", len(lines), lines[0][:12])
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
