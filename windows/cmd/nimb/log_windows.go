//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/logfile"
)

var logMu sync.Mutex
var logWrites int

func windowLogPath() string { return filepath.Join(dataDir(), "window.log") }

// logLine appends a line to the log of the window. The log holds this run only (the last run is kept aside, see setupDiagnostics); a run that
// writes a lot has the file cut to its last lines when it passes a megabyte, it is never emptied.
func logLine(line string) {
	logMu.Lock()
	defer logMu.Unlock()
	path := windowLogPath()
	if logWrites++; logWrites%200 == 0 {
		logfile.TrimIfOver(path, 1<<20, 2000)
	}
	os.MkdirAll(filepath.Dir(path), 0o700)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s  %s\n", time.Now().Format("2006-01-02 15:04:05"), line)
}
