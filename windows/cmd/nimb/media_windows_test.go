//go:build windows

package main

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/ipc"
)

func TestCancelStartupAndIgnoreItsLateSuccessWhileANewStartRuns(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())
	a := &App{settings: &settingsStore{path: filepath.Join(t.TempDir(), "settings.json")}, busy: map[string]bool{}, errs: map[string]string{}}
	started := make(chan ipc.Request, 2)
	releaseOld, releaseNew := make(chan struct{}), make(chan struct{})
	var oldID string
	request := func(r ipc.Request) (ipc.Response, error) {
		if r.Cmd == ipc.TunnelUp {
			started <- r
			if r.Attempt == oldID {
				<-releaseOld
			} else {
				<-releaseNew
			}
		}
		return ipc.Response{OK: true}, nil
	}
	// Set the expected first ID in the fake on its first call without relying on scheduling.
	first := func(r ipc.Request) (ipc.Response, error) {
		oldID = r.Attempt
		started <- r
		<-releaseOld
		return ipc.Response{OK: true}, nil
	}
	doneOld := make(chan Result, 1)
	go func() { doneOld <- a.setMedia(true, first) }()
	old := <-started
	stopCalled := false
	if result := a.setMedia(false, func(r ipc.Request) (ipc.Response, error) {
		stopCalled = true
		if r.Cmd != ipc.TunnelDown || r.Attempt != old.Attempt || r.Attempt == "" {
			t.Error("stop lost the startup ID")
		}
		return ipc.Response{OK: true}, nil
	}); !result.OK || !stopCalled {
		t.Fatal("off was ignored while connecting")
	}
	if a.settings.get().TunnelWanted {
		t.Fatal("cancelled start is scheduled for next login")
	}
	doneNew := make(chan Result, 1)
	go func() { doneNew <- a.setMedia(true, request) }()
	next := <-started
	if next.Attempt == old.Attempt {
		t.Fatal("a new attempt reused the cancelled ID")
	}
	close(releaseOld)
	select {
	case <-doneOld:
	case <-time.After(time.Second):
		t.Fatal("old start did not finish")
	}
	a.mu.Lock()
	busy, id := a.busy["media"], a.mediaAttempt
	a.mu.Unlock()
	if !busy || id != next.Attempt || a.settings.get().TunnelWanted {
		t.Fatal("old completion overwrote the new attempt or revived saved intent")
	}
	close(releaseNew)
	select {
	case result := <-doneNew:
		if !result.OK {
			t.Fatal(result)
		}
	case <-time.After(time.Second):
		t.Fatal("new start did not finish")
	}
	if !a.settings.get().TunnelWanted {
		t.Fatal("a fresh successful explicit start should be remembered")
	}
}
