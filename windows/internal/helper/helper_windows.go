//go:build windows

// Package helper is what the service of Nimb does when the window asks: bring the tunnel up and down and look after the
// anonymous account that the tunnel uses. It runs as the system, so it takes nothing from the window except the name of a
// command (see package ipc). The account and the settings live in a folder that only the system and the administrators can read.
package helper

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/sys/windows"

	"github.com/Dizrane/Nimb/windows/internal/awgconf"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
	"github.com/Dizrane/Nimb/windows/internal/tunnel"
	"github.com/Dizrane/Nimb/windows/internal/warp"
)

// DataDir is where the service keeps its files.
func DataDir() string {
	base := os.Getenv("ProgramData")
	if base == "" {
		base = `C:\ProgramData`
	}
	return filepath.Join(base, "Nimb")
}

// The DNS of the tunnel. Without it the system keeps asking the router of the home network, which the tunnel does not reach.
var tunnelDNS = []netip.Addr{netip.MustParseAddr("1.1.1.1"), netip.MustParseAddr("1.0.0.1")}

// Helper carries out the commands.
type Helper struct {
	dir  string
	logf func(format string, args ...any)

	mu  sync.Mutex
	tun *tunnel.Tunnel
}

// New prepares the folder (closed to everybody but the system and the administrators) and returns a helper.
func New(dir string, logf func(string, ...any)) (*Helper, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	if err := secureDir(dir); err != nil {
		return nil, fmt.Errorf("папка службы: %w", err)
	}
	return &Helper{dir: dir, logf: logf}, nil
}

// Close takes the tunnel down.
func (h *Helper) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.down()
}

// Handle implements ipc.Handler.
func (h *Helper) Handle(ctx context.Context, cmd string) ipc.Response {
	h.mu.Lock()
	defer h.mu.Unlock()
	switch cmd {
	case ipc.Ping:
		return ipc.Response{OK: true}
	case ipc.Status:
		return ipc.Response{OK: true, Tunnel: h.status()}
	case ipc.TunnelUp:
		if err := h.up(ctx); err != nil {
			h.logf("tunnel.up: %v", err)
			return ipc.Response{Error: err.Error(), Tunnel: h.status()}
		}
		return ipc.Response{OK: true, Tunnel: h.status()}
	case ipc.TunnelDown:
		h.down()
		return ipc.Response{OK: true, Tunnel: h.status()}
	case ipc.TunnelUnregister:
		h.down()
		h.unregister(ctx)
		return ipc.Response{OK: true, Tunnel: h.status()}
	}
	return ipc.Response{Error: "неизвестная команда"}
}

func (h *Helper) status() *ipc.TunnelStatus {
	st := &ipc.TunnelStatus{HandshakeAgo: -1, HasAccount: h.hasAccount()}
	if h.tun != nil {
		st.Up = true
		if hs := h.tun.Handshake(); !hs.IsZero() {
			st.HandshakeAgo = int(time.Since(hs).Seconds())
		}
		st.Received, st.Sent = h.tun.Counters()
	}
	return st
}

func (h *Helper) up(ctx context.Context) error {
	if h.tun != nil {
		return nil
	}
	acc, err := h.account(ctx)
	if err != nil {
		return err
	}
	cfg, err := awgconf.Parse(acc.Config)
	if err != nil {
		return fmt.Errorf("настройки туннеля не прошли проверку: %w", err)
	}
	h.logf("bringing the tunnel up")
	t, err := tunnel.Up(cfg, tunnel.Options{Name: "Nimb", DNS: tunnelDNS, Logf: h.logf})
	if err != nil {
		if errors.Is(err, tunnel.ErrNoHandshake) {
			return errors.New("сервер не ответил за 16 секунд, интернет остался прежним")
		}
		return err
	}
	h.tun = t
	return nil
}

func (h *Helper) down() {
	if h.tun != nil {
		h.tun.Close()
		h.tun = nil
	}
}

// account returns the account of this installation, making one on the first use.
func (h *Helper) account(ctx context.Context) (*warp.Account, error) {
	if acc, err := h.loadAccount(); err == nil {
		return acc, nil
	}
	h.logf("registering an anonymous account")
	acc, err := warp.Register(ctx)
	if err != nil {
		return nil, err
	}
	if err := h.saveAccount(acc); err != nil {
		// Without a place to keep it the account is useless and would stay at Cloudflare for nothing.
		warp.Unregister(ctx, acc.ID, acc.Token)
		return nil, fmt.Errorf("не удалось сохранить аккаунт: %w", err)
	}
	return acc, nil
}

func (h *Helper) accountPath() string { return filepath.Join(h.dir, "account.json") }

func (h *Helper) hasAccount() bool {
	_, err := os.Stat(h.accountPath())
	return err == nil
}

func (h *Helper) loadAccount() (*warp.Account, error) {
	raw, err := os.ReadFile(h.accountPath())
	if err != nil {
		return nil, err
	}
	var acc warp.Account
	if err := json.Unmarshal(raw, &acc); err != nil || acc.ID == "" || acc.Config == "" {
		return nil, errors.New("файл аккаунта повреждён")
	}
	return &acc, nil
}

func (h *Helper) saveAccount(acc *warp.Account) error {
	raw, err := json.Marshal(acc)
	if err != nil {
		return err
	}
	tmp := h.accountPath() + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, h.accountPath())
}

// unregister deletes the account at Cloudflare and the file. If Cloudflare does not answer the file goes anyway: an account
// that nobody uses expires by itself, and a copy of its key must not stay on the disk.
func (h *Helper) unregister(ctx context.Context) {
	acc, err := h.loadAccount()
	if err != nil {
		os.Remove(h.accountPath())
		return
	}
	if err := warp.Unregister(ctx, acc.ID, acc.Token); err != nil {
		h.logf("unregister: %v", err)
	}
	os.Remove(h.accountPath())
}

// secureDir creates the folder and gives it to the system and the administrators only.
func secureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString("D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}
