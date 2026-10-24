// Package logfile keeps the logs of Nimb from growing without end and from mixing one run with another. A log is a text file of lines. At
// the start of a program its log of the last run is put aside as the «previous» one (one previous, the older one goes), so the file that is
// written holds the current run only; while the program runs, a file that has become too big is cut to its last lines (not emptied: the
// end of a long run is what a report needs).
package logfile

import (
	"os"
	"path/filepath"
	"strings"
)

// PreviousPath is where the log of the last run is kept: window.log becomes window-previous.log.
func PreviousPath(path string) string {
	ext := filepath.Ext(path)
	return strings.TrimSuffix(path, ext) + "-previous" + ext
}

// Rotate puts the log of the last run aside as the previous one; an empty or missing file is left where it is (the previous one stays
// the previous one). It returns the last line of the log that was put aside, which tells how that run ended.
func Rotate(path string) (lastLine string) {
	raw, err := os.ReadFile(path)
	if err != nil || len(strings.TrimSpace(string(raw))) == 0 {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\r\n"), "\n")
	lastLine = lines[len(lines)-1]
	os.Remove(PreviousPath(path))
	if os.Rename(path, PreviousPath(path)) != nil {
		os.Remove(path) // it could not be kept; at least the new run starts clean
	}
	return lastLine
}

// TrimIfOver cuts the file to its last keep lines when it is bigger than limit bytes, and returns the size it has now.
func TrimIfOver(path string, limit int64, keep int) int64 {
	info, err := os.Stat(path)
	if err != nil || info.Size() <= limit {
		if err != nil {
			return 0
		}
		return info.Size()
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return info.Size()
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\r\n"), "\n")
	if len(lines) > keep {
		lines = lines[len(lines)-keep:]
	}
	text := strings.Join(lines, "\n") + "\n"
	if os.WriteFile(path, []byte(text), 0o600) != nil {
		return info.Size()
	}
	return int64(len(text))
}

// Tail returns the last n lines of a file (nil when there is no file).
func Tail(path string, n int) []string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\r\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}
