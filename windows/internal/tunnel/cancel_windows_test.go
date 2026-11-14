//go:build windows

package tunnel

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/awgconf"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

func TestWindowsSystemCancelUnansweredHandshakeRemovesAdapter(t *testing.T) {
	if os.Getenv("NIMB_SYSTEM_TEST") != "1" {
		t.Skip("requires snapshotted Windows VM, admin and wintun.dll beside test binary")
	}
	key := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("\x01", 32)))
	peer := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("\x02", 32)))
	// Documentation-only IP ranges: no real WARP account and no default routes are used.
	cfg, err := awgconf.Parse("[Interface]\nPrivateKey = " + key + "\nAddress = 192.0.2.2/32\nMTU = 1280\n[Peer]\nPublicKey = " + peer + "\nEndpoint = 203.0.113.1:500\nAllowedIPs = 198.51.100.0/24\nPersistentKeepalive = 1\n")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ready := make(chan struct{})
	var once sync.Once
	type result struct {
		tun *Tunnel
		err error
	}
	done := make(chan result, 1)
	name := "Nimb Validation Cancel"
	go func() {
		tun, err := Up(cfg, Options{Context: ctx, Name: name, HandshakeTimeout: 30 * time.Second, Logf: func(format string, args ...any) {
			if strings.Contains(format, "адрес, маршруты и DNS заданы") {
				once.Do(func() { close(ready) })
			}
		}})
		done <- result{tun, err}
	}()
	select {
	case <-ready:
	case result := <-done:
		t.Fatalf("start failed before waiting: %v", result.err)
	case <-time.After(10 * time.Second):
		t.Fatal("test adapter did not initialise")
	}
	start := time.Now()
	cancel()
	select {
	case result := <-done:
		if result.tun != nil {
			result.tun.Close()
			t.Error("cancelled start returned a live tunnel")
		}
		if !errors.Is(result.err, context.Canceled) {
			t.Fatalf("expected cancelled handshake, got %v", result.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancel did not interrupt handshake and cleanup")
	}
	t.Logf("cancelled unanswered handshake and cleaned up in %s", time.Since(start))
	// PnP removes the device asynchronously. Keep this test process alive to prove cleanup does not depend on process exit.
	deadline := time.Now().Add(3 * time.Second)
	for {
		adapters, err := winipcfg.GetAdaptersAddresses(windows.AF_UNSPEC, winipcfg.GAAFlagIncludeAllInterfaces)
		if err != nil {
			t.Fatal(err)
		}
		present := false
		for _, a := range adapters {
			if a.FriendlyName() == name {
				present = true
			}
		}
		if !present {
			t.Logf("adapter disappearance confirmed in %s (test process still running)", time.Since(start))
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("cancelled tunnel left its adapter/routes/DNS while the service process remains alive")
		}
		time.Sleep(50 * time.Millisecond)
	}
}
