//go:build windows

package helper

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/windows"

	"github.com/Dizrane/Nimb/windows/internal/awgconf"
	"github.com/Dizrane/Nimb/windows/internal/serverpick"
	"github.com/Dizrane/Nimb/windows/internal/tunnel"
	"github.com/Dizrane/Nimb/windows/internal/tunnelrestart"
)

// The choice of the WARP server (package serverpick has the rules); here is what they need from the service.

func (h *Helper) serverPath() string { return filepath.Join(h.dir, "tunnel.server") }
func (h *Helper) searchPath() string { return filepath.Join(h.dir, "tunnel.search") }

// serverSteps gives serverpick what it needs. The caller holds the lock.
func (h *Helper) serverSteps(ctx context.Context, cfg *awgconf.Config) serverpick.Steps {
	client := &http.Client{
		Transport:     &http.Transport{DisableKeepAlives: true, Proxy: nil, DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	return serverpick.Steps{
		BringUp:  func(host string) error { return h.bringUpAt(cfg, host) },
		NoAnswer: func(err error) bool { return errors.Is(err, tunnel.ErrNoHandshake) },
		Web:      func() bool { return serverpick.Opens(ctx, client, serverpick.ProbeWeb) },
		Opens:    func() bool { return serverpick.OpenBoth(ctx, client, serverpick.ProbeVideo, serverpick.ProbeChat) },
		Saved: func() string {
			raw, _ := os.ReadFile(h.serverPath())
			if host := strings.TrimSpace(string(raw)); serverpick.Valid(host) {
				return host
			}
			return ""
		},
		Save: func(host string) {
			if host == "" {
				os.Remove(h.serverPath())
				return
			}
			os.WriteFile(h.serverPath(), []byte(host+"\n"), 0o600)
		},
		SearchedAt: func() time.Time {
			raw, _ := os.ReadFile(h.searchPath())
			sec, err := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
			if err != nil || sec <= 0 {
				return time.Time{}
			}
			return time.Unix(sec, 0)
		},
		MarkSearched: func(t time.Time) {
			if t.IsZero() {
				os.Remove(h.searchPath())
				return
			}
			os.WriteFile(h.searchPath(), []byte(fmt.Sprint(t.Unix())+"\n"), 0o600)
		},
		Now: time.Now,
		Log: func(format string, args ...any) {
			line := fmt.Sprintf(format, args...)
			h.logf("туннель: %s", line)
			h.tlog.Mark(line)
		},
	}
}

// bringUpAt takes the tunnel that is up down and starts one at the server host ("" is the one in the account). The server in the account
// gets the whole schedule (two attempts, see tunnelrestart); any other server one attempt, so that looking through the servers does not take
// minutes.
func (h *Helper) bringUpAt(cfg *awgconf.Config, host string) error {
	h.closeTunnel()
	if wait := tunnelrestart.SettleWait(time.Since(h.lastClosed), !h.lastClosed.IsZero()); wait > 0 {
		h.logf("туннель: прошлый закрыт только что, жду %.0f с, чтобы он ушёл совсем", wait.Seconds())
		time.Sleep(wait)
	}
	endpoint, err := serverpick.WithHost(cfg.Endpoint, host)
	if err != nil {
		return fmt.Errorf("адрес сервера не разобран: %w", err)
	}
	at := *cfg
	at.Endpoint = endpoint
	timeouts := tunnelrestart.AttemptTimeouts
	if host != "" {
		timeouts = timeouts[:1]
	}
	var t *tunnel.Tunnel
	for attempt, timeout := range timeouts {
		t, err = tunnel.Up(&at, tunnel.Options{Name: "Nimb", DNS: h.tunnelDNS(), Logf: h.logf, DeviceLogf: h.tlog.Logf, HandshakeTimeout: timeout})
		// Two things went wrong at a start right after a stop, and both were gone on a second try: no answer to the handshake, and an adapter
		// that Windows did not know yet («Element not found» while the routes were set). The tunnel of the failed attempt is already taken
		// down. One more try, so that the person does not see an error for a start that a moment later would have worked.
		retryable := errors.Is(err, tunnel.ErrNoHandshake) || errors.Is(err, tunnel.ErrAdapter) || errors.Is(err, windows.ERROR_NOT_FOUND)
		if !retryable || attempt == len(timeouts)-1 {
			break
		}
		h.tlog.Mark("start failed, trying once more: " + err.Error())
		h.logf("туннель: не вышло (%v), пробую ещё раз", err)
		time.Sleep(tunnelrestart.RetryPause)
	}
	if err != nil {
		return err
	}
	h.tun = t
	h.clearDrop()
	h.watchTunnel(t)
	h.server = host
	h.serverAddr, _, _ = net.SplitHostPort(endpoint)
	label := host
	if label == "" {
		label = "из настроек"
	}
	h.tlog.Mark("up server=" + label)
	return nil
}

// tunnelServer is the address of the server that the tunnel is at (empty when it is down).
func (h *Helper) tunnelServer() string {
	if h.tun == nil {
		return ""
	}
	return h.serverAddr
}
