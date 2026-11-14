//go:build windows

package helper

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
)

// Run only in a disposable/snapshotted Windows VM, as administrator, with the installed helper stopped.
// NIMB_SYSTEM_TEST=1 helper.test.exe -test.run TestWindowsSystem -test.v
func systemHelper(t *testing.T) *Helper {
	t.Helper()
	if os.Getenv("NIMB_SYSTEM_TEST") != "1" {
		t.Skip("requires explicit opt-in to reversible Windows system tests")
	}
	h, err := New(t.TempDir(), t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(h.Close)
	return h
}

func TestWindowsSystemStatusWithoutPreviousPoll(t *testing.T) {
	h := systemHelper(t)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go ipc.Serve(ctx, l, h)
	// The tunnel holds this same lock during startup. No status request has primed the cache.
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, command := range []string{ipc.Status, ipc.Ping} {
		conn, err := net.DialTimeout("tcp", l.Addr().String(), time.Second)
		if err != nil {
			t.Fatal(err)
		}
		conn.SetDeadline(time.Now().Add(time.Second))
		start := time.Now()
		response, err := ipc.Call(conn, ipc.Request{Cmd: command})
		conn.Close()
		if err != nil || !response.OK {
			t.Fatalf("%s blocked/failed: %v %+v", command, err, response)
		}
		t.Logf("%s answered with startup lock held in %s", command, time.Since(start))
	}
}

func TestWindowsSystemRestoreDisabledAdapter(t *testing.T) {
	h := systemHelper(t)
	h.mu.Lock()
	defer h.mu.Unlock()
	before, err := dnsx.Adapters()
	if err != nil || len(before) != 1 {
		t.Fatalf("requires exactly one active VM adapter: %+v %v", before, err)
	}
	a := before[0]
	adapterCommand := func(verb string) error {
		// Select by numeric index via GUID, never interpolate an adapter alias into executable text.
		script := "$a=Get-NetAdapter | Where-Object InterfaceGuid -eq '" + a.GUID + "'; if ($null -eq $a) { throw 'VM adapter not found' }; $a | " + verb + "-NetAdapter -Confirm:$false -ErrorAction Stop"
		if verb == "Disable" {
			script += "; if ((Get-NetAdapter -Name $a.Name).Status -ne 'Disabled') { throw 'Adapter was not disabled' }"
		}
		out, err := exec.Command("powershell.exe", "-NoProfile", "-Command", script).CombinedOutput()
		if err != nil {
			t.Logf("%s: %s", verb, out)
		}
		return err
	}
	defer func() {
		if err := adapterCommand("Enable"); err != nil {
			t.Errorf("enable adapter: %v", err)
		}
		if err := h.dnsRestore(); err != nil {
			t.Errorf("final DNS restore: %v", err)
		}
		current, ok := dnsx.Current(a.GUID)
		if !ok || !dnsx.Same(current.NameServer, a.NameServer) || !dnsx.Same6(current.NameServer6, a.NameServer6) {
			t.Errorf("original DNS not restored: %+v", current)
		}
	}()
	if err := h.dnsSet(dnsx.Providers[0]); err != nil {
		t.Fatal(err)
	}
	if err := adapterCommand("Disable"); err != nil {
		t.Fatal(err)
	}
	all, err := dnsx.RestoreAdapters()
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, item := range all {
		if item.GUID == a.GUID {
			found = true
		}
	}
	if !found {
		t.Fatal("disabled adapter missing from restoration enumeration")
	}
	err = h.dnsRestore()
	if err != nil {
		if h.backup == nil || !h.backup.Restoring {
			t.Fatalf("failed restore discarded backup: %v", err)
		}
		t.Logf("Windows deferred disabled-adapter write, backup retained: %v", err)
	} else {
		t.Log("DNS restored while adapter was disabled")
	}
	if err := adapterCommand("Enable"); err != nil {
		t.Fatal(err)
	}
	if err := h.dnsRestore(); err != nil {
		t.Fatal(err)
	}
	if h.backup != nil {
		t.Fatal("successful restore left pending backup")
	}
}

func TestWindowsSystemCleanupRequiresCompleteDNSRestoreAndLeavesNoBackup(t *testing.T) {
	if os.Getenv("NIMB_SYSTEM_TEST") != "1" {
		t.Skip("requires snapshotted Windows VM")
	}
	dir := filepath.Join(t.TempDir(), "service")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	h := &Helper{dir: dir, logf: t.Logf, backup: &dnsx.Backup{Provider: dnsx.Providers[0].ID, Adapters: []dnsx.Adapter{{GUID: "{11111111-1111-1111-1111-111111111111}", Name: "Missing test USB", NameServer: "10.0.0.53"}}}}
	if err := h.saveBackup(); err != nil {
		t.Fatal(err)
	}
	settings := filepath.Join(dir, "settings.json")
	if err := os.WriteFile(settings, []byte("test data"), 0600); err != nil {
		t.Fatal(err)
	}
	if problems := Cleanup(dir, t.Logf); len(problems) == 0 {
		t.Fatal("incomplete restoration must abort cleanup")
	}
	if _, err := os.Stat(settings); err != nil {
		t.Fatalf("aborted uninstall deleted settings: %v", err)
	}
	if _, err := os.Stat(h.backupPath()); err != nil {
		t.Fatalf("aborted uninstall lost original DNS: %v", err)
	}
	// No real adapter is modified: this empty backup represents completed restoration on the retry.
	h.backup = &dnsx.Backup{Provider: dnsx.Providers[0].ID}
	if err := h.saveBackup(); err != nil {
		t.Fatal(err)
	}
	if problems := Cleanup(dir, t.Logf); len(problems) != 0 {
		t.Fatal(problems)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("successful cleanup left service data/backup: %v", err)
	}
}
