//go:build windows

package main

import (
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/ipc"
)

func shutdownTestApp(t *testing.T) *App {
	t.Helper()
	t.Setenv("APPDATA", t.TempDir())
	a := &App{
		settings: &settingsStore{path: filepath.Join(t.TempDir(), "settings.json"), s: Settings{TunnelWanted: true, TelegramAuto: true}},
		busy:     map[string]bool{},
		errs:     map[string]string{},
	}
	a.quitRequested.Store(true)
	return a
}

func stoppedStatus() ipc.Response {
	return ipc.Response{OK: true, DNS: &ipc.DNSStatus{}, Tunnel: &ipc.TunnelStatus{}, Telegram: &ipc.TelegramStatus{}}
}

func TestShutdownStopsEveryFeatureAndClearsSavedStartup(t *testing.T) {
	a := shutdownTestApp(t)
	var commands []string
	problems := a.shutdownServices(func(r ipc.Request) (ipc.Response, error) {
		commands = append(commands, r.Cmd)
		if r.Cmd == ipc.Status {
			return stoppedStatus(), nil
		}
		return ipc.Response{OK: true}, nil
	})
	if len(problems) != 0 {
		t.Fatal(problems)
	}
	if want := []string{ipc.TunnelDown, ipc.TelegramDown, ipc.DNSRestore, ipc.Status}; !reflect.DeepEqual(commands, want) {
		t.Fatalf("shutdown commands: %v; want %v", commands, want)
	}
	if saved := a.settings.get(); saved.TunnelWanted || saved.TelegramAuto {
		t.Fatal("exited features would restart on the next launch")
	}
}

func TestShutdownReportsRestoreFailureEvenIfStatusLooksOff(t *testing.T) {
	a := shutdownTestApp(t)
	var commands []string
	problems := a.shutdownServices(func(r ipc.Request) (ipc.Response, error) {
		commands = append(commands, r.Cmd)
		if r.Cmd == ipc.TunnelDown {
			return ipc.Response{}, errors.New("tunnel stop failed")
		}
		if r.Cmd == ipc.DNSRestore {
			return ipc.Response{}, errors.New("DNS restore failed")
		}
		return stoppedStatus(), nil
	})
	message := strings.Join(problems, "; ")
	if !strings.Contains(message, "tunnel stop failed") || !strings.Contains(message, "DNS restore failed") {
		t.Fatalf("cleanup failure was hidden by an inactive status: %v", problems)
	}
	if want := []string{ipc.TunnelDown, ipc.TelegramDown, ipc.DNSRestore, ipc.Status}; !reflect.DeepEqual(commands, want) {
		t.Fatalf("one error skipped another stop: %v", commands)
	}
}

func TestShutdownRejectsActiveOrUnconfirmedStatus(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status ipc.Response
	}{
		{"missing states", ipc.Response{OK: true}},
		{"failed status", ipc.Response{}},
		{"active DNS", ipc.Response{OK: true, DNS: &ipc.DNSStatus{Active: true}, Tunnel: &ipc.TunnelStatus{}, Telegram: &ipc.TelegramStatus{}}},
		{"restarting tunnel", ipc.Response{OK: true, DNS: &ipc.DNSStatus{}, Tunnel: &ipc.TunnelStatus{Restarting: true}, Telegram: &ipc.TelegramStatus{}}},
		{"active proxy", ipc.Response{OK: true, DNS: &ipc.DNSStatus{}, Tunnel: &ipc.TunnelStatus{}, Telegram: &ipc.TelegramStatus{On: true}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := shutdownTestApp(t)
			problems := a.shutdownServices(func(r ipc.Request) (ipc.Response, error) {
				if r.Cmd == ipc.Status {
					return tc.status, nil
				}
				return ipc.Response{OK: true}, nil
			})
			if len(problems) == 0 {
				t.Fatal("unconfirmed cleanup was reported as successful")
			}
		})
	}
}

func TestShutdownWaitsForPendingSwitchBeforeRestoringDNS(t *testing.T) {
	a := shutdownTestApp(t)
	a.busy["ai"] = true
	called := make(chan string, 4)
	done := make(chan []string, 1)
	go func() {
		done <- a.shutdownServices(func(r ipc.Request) (ipc.Response, error) {
			called <- r.Cmd
			return stoppedStatus(), nil
		})
	}()
	select {
	case cmd := <-called:
		t.Fatalf("cleanup ran while an earlier DNS switch could still turn it back on: %s", cmd)
	case <-time.After(30 * time.Millisecond):
	}
	a.mu.Lock()
	delete(a.busy, "ai")
	a.mu.Unlock()
	select {
	case problems := <-done:
		if len(problems) != 0 {
			t.Fatal(problems)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown did not resume after the switch finished")
	}
}

func TestShutdownCancelsStartupAndIgnoresItsLateSuccess(t *testing.T) {
	a := shutdownTestApp(t)
	a.quitRequested.Store(false)
	started := make(chan ipc.Request, 1)
	cancelled := make(chan struct{})
	startDone := make(chan Result, 1)
	go func() {
		startDone <- a.setMedia(true, func(r ipc.Request) (ipc.Response, error) {
			started <- r
			<-cancelled
			return ipc.Response{OK: true}, nil
		})
	}()
	start := <-started
	a.quitRequested.Store(true)
	var commands []ipc.Request
	problems := a.shutdownServices(func(r ipc.Request) (ipc.Response, error) {
		commands = append(commands, r)
		if r.Attempt != "" {
			if r.Cmd != ipc.TunnelDown || r.Attempt != start.Attempt {
				t.Errorf("cancellation lost the pending startup ID: %+v", r)
			}
			close(cancelled)
		}
		return stoppedStatus(), nil
	})
	if len(problems) != 0 || len(commands) != 5 || commands[0].Attempt == "" {
		t.Fatalf("startup was not cancelled before final cleanup: %v, %+v", problems, commands)
	}
	select {
	case result := <-startDone:
		if !result.OK {
			t.Fatal(result)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("cancelled startup did not finish")
	}
	if a.settings.get().TunnelWanted {
		t.Fatal("late startup success revived the tunnel's saved intent")
	}
}

func TestShutdownBlocksNewSwitches(t *testing.T) {
	a := shutdownTestApp(t)
	for _, name := range []string{"ai", "telegram", "media"} {
		if a.enter(name) {
			t.Fatalf("new %s switch was accepted during exit", name)
		}
	}
	called := false
	a.setMedia(true, func(ipc.Request) (ipc.Response, error) {
		called = true
		return ipc.Response{OK: true}, nil
	})
	if called {
		t.Fatal("exit allowed a new tunnel startup request")
	}
}
