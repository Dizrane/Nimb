//go:build windows

package dnsx

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWindowsLegacyHostsCleanupReplacesARealFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hosts")
	const original = "# manually set\r\n192.0.2.10 example.test"
	old := "\xef\xbb\xbf" + recoveryStart + "\r\n192.0.2.1 old.test\r\n" + recoveryEnd + "\r\n" + original
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	flushes := 0
	flush := func() { flushes++ }
	if err := removeLegacyHosts(path, flush); err != nil {
		t.Fatal(err)
	}
	if err := removeLegacyHosts(path, flush); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != "\xef\xbb\xbf"+original || flushes != 1 {
		t.Fatalf("not restored: %q, flushes %d, err %v", data, flushes, err)
	}
}
