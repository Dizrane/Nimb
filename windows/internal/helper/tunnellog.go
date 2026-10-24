package helper

import (
	"fmt"
	"github.com/Dizrane/Nimb/windows/internal/logfile"
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
	// The log of the last run of the service is put aside: this file holds this run only (its marks are the story of this run).
	logfile.Rotate(path)
	return &tunnelLog{path: path}
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

// trim cuts the file to its last tunnelLogKeep lines when it is over the limit. The caller holds the lock.
func (l *tunnelLog) trim() { l.size = logfile.TrimIfOver(l.path, tunnelLogLimit, tunnelLogKeep) }

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

// Marks returns the last n lines that the service wrote itself (NIMB: up, daemon-exited, restarting, restarted, ...), from the whole file:
// the lines of the daemon around them are many, and they would push the marks out of a short tail.
func (l *tunnelLog) Marks(n int) []string {
	var marks []string
	for _, line := range l.Tail(1 << 20) {
		if strings.Contains(line, " NIMB: ") {
			marks = append(marks, line)
		}
	}
	if len(marks) > n {
		marks = marks[len(marks)-n:]
	}
	return marks
}
