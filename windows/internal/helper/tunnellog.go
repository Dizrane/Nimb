package helper

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// The log of the program of the tunnel (the daemon inside the service) is detailed. It is cut to its last lines when it grows past
// tunnelLogLimit, as on the Mac (the log of the helper there).
const (
	tunnelLogLimit = 256 * 1024
	tunnelLogKeep  = 400
)

// tunnelLog is the file of that log. The daemon never writes keys into it; the window cleans the addresses before it goes into a report.
type tunnelLog struct {
	path string
	mu   sync.Mutex
	size int64
}

func newTunnelLog(path string) *tunnelLog {
	l := &tunnelLog{path: path}
	if info, err := os.Stat(path); err == nil {
		l.size = info.Size()
	}
	l.trim()
	return l
}

// Logf writes a line with the time.
func (l *tunnelLog) Logf(format string, args ...any) {
	line := time.Now().Format("2006/01/02 15:04:05 ") + strings.TrimRight(fmt.Sprintf(format, args...), "\r\n") + "\n"
	l.mu.Lock()
	defer l.mu.Unlock()
	f, err := os.OpenFile(l.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	n, _ := f.WriteString(line)
	f.Close()
	l.size += int64(n)
	if l.size > tunnelLogLimit {
		l.trim()
	}
}

// Mark writes what the service itself does with the tunnel (up, daemon-exited, restarting, restarted), so that it can be told from the
// lines of the daemon.
func (l *tunnelLog) Mark(what string) { l.Logf("NIMB: %s", what) }

// trim keeps the last tunnelLogKeep lines when the file is over the limit. The caller holds the lock (or is the only user).
func (l *tunnelLog) trim() {
	if l.size <= tunnelLogLimit {
		return
	}
	raw, err := os.ReadFile(l.path)
	if err != nil {
		return
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if len(lines) > tunnelLogKeep {
		lines = lines[len(lines)-tunnelLogKeep:]
	}
	text := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(l.path, []byte(text), 0o600); err == nil {
		l.size = int64(len(text))
	}
}

// Tail returns the last n lines.
func (l *tunnelLog) Tail(n int) []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	raw, err := os.ReadFile(l.path)
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\r\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}
