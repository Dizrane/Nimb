//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var logMu sync.Mutex

// logLine appends a line to the log of the window; the file starts again when it passes a megabyte.
func logLine(line string) {
	logMu.Lock()
	defer logMu.Unlock()
	path := filepath.Join(dataDir(), "window.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 1<<20 {
		os.Remove(path)
	}
	os.MkdirAll(filepath.Dir(path), 0o700)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s  %s\n", time.Now().Format("2006-01-02 15:04:05"), line)
}
