package logfile

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestPreviousPath(t *testing.T) {
	for in, want := range map[string]string{`C:\x\window.log`: `C:\x\window-previous.log`, "/a/tunnel.log": "/a/tunnel-previous.log", "/a/service.log": "/a/service-previous.log"} {
		if got := PreviousPath(in); got != want {
			t.Errorf("%s: %s", in, got)
		}
	}
}

func TestTheLogOfTheLastRunIsPutAsideAndTheOlderOneGoes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "window.log")
	write(t, path, "run 1 a\nrun 1 b\n")
	if last := Rotate(path); last != "run 1 b" {
		t.Errorf("last line %q", last)
	}
	if _, err := os.Stat(path); err == nil {
		t.Error("the current file is still there")
	}
	write(t, path, "run 2 a\n")
	Rotate(path)
	prev, _ := os.ReadFile(PreviousPath(path))
	if string(prev) != "run 2 a\n" {
		t.Errorf("the previous one is %q: only the last run is kept", prev)
	}
}

func TestAnEmptyOrMissingLogDoesNotPushTheGoodPreviousOneOut(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "window.log")
	write(t, PreviousPath(path), "good old run\n")
	if Rotate(path) != "" {
		t.Error("nothing to put aside")
	}
	write(t, path, "  \n")
	Rotate(path)
	if prev, _ := os.ReadFile(PreviousPath(path)); string(prev) != "good old run\n" {
		t.Errorf("the previous one was lost: %q", prev)
	}
}

func TestABigLogIsCutToItsLastLinesNotEmptied(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.log")
	var b strings.Builder
	for i := 0; i < 5000; i++ {
		fmt.Fprintf(&b, "line %d %s\n", i, strings.Repeat("x", 100))
	}
	write(t, path, b.String())
	size := TrimIfOver(path, 100_000, 300)
	lines := Tail(path, 10000)
	if len(lines) != 300 || !strings.HasPrefix(lines[0], "line 4700 ") || !strings.HasPrefix(lines[299], "line 4999 ") {
		t.Errorf("%d lines, %q ... %q", len(lines), lines[0][:12], lines[len(lines)-1][:12])
	}
	info, _ := os.Stat(path)
	if size != info.Size() {
		t.Errorf("size %d, file %d", size, info.Size())
	}
	// A small one is left alone.
	if TrimIfOver(path, 1_000_000, 10) != info.Size() || len(Tail(path, 10000)) != 300 {
		t.Error("a log under the limit was cut")
	}
	if TrimIfOver(filepath.Join(t.TempDir(), "none.log"), 10, 1) != 0 {
		t.Error("a missing file")
	}
}
