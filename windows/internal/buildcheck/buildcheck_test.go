package buildcheck

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sum(b string) string { h := sha256.Sum256([]byte(b)); return hex.EncodeToString(h[:]) }

func TestABuildIsOursWhenItHasTheKeyAndItsFilesAreTheOnesItMade(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "nimb-svc.exe"), []byte("service"), 0o600)
	os.WriteFile(filepath.Join(dir, "wintun.dll"), []byte("wintun"), 0o600)
	files := "nimb-svc.exe=" + sum("service") + ";wintun.dll=" + strings.ToUpper(sum("wintun"))
	if got := Problem(true, files, dir); got != "" {
		t.Fatalf("ours: %q", got)
	}
	if got := Problem(false, files, dir); !strings.Contains(got, "не из официального выпуска") {
		t.Errorf("no key: %q", got)
	}
	os.WriteFile(filepath.Join(dir, "nimb-svc.exe"), []byte("a service of another build"), 0o600)
	if got := Problem(true, files, dir); !strings.Contains(got, "nimb-svc.exe не наш") {
		t.Errorf("replaced service: %q", got)
	}
	os.Remove(filepath.Join(dir, "wintun.dll"))
	os.WriteFile(filepath.Join(dir, "nimb-svc.exe"), []byte("service"), 0o600)
	if got := Problem(true, files, dir); !strings.Contains(got, "нет файла wintun.dll") {
		t.Errorf("missing file: %q", got)
	}
}

func TestOnlyTheNamesOfFilesNextToTheProgramAreLooked(t *testing.T) {
	dir := t.TempDir()
	// a name with a path is not followed, and an empty list judges nothing
	if got := Problem(true, `..\evil.exe=`+sum("x")+";broken;=abc", dir); got != "" {
		t.Errorf("%q", got)
	}
	if got := Problem(true, "", dir); got != "" {
		t.Errorf("%q", got)
	}
	if PausedWords == "" || PausedShort == "" || PausedWords == PausedShort {
		t.Error("words")
	}
}
