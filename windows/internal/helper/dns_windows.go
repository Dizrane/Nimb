//go:build windows

package helper

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
)

func (h *Helper) backupPath() string { return filepath.Join(h.dir, "dns-backup.json") }

func (h *Helper) loadBackup() *dnsx.Backup {
	raw, err := os.ReadFile(h.backupPath())
	if err != nil {
		return nil
	}
	var b dnsx.Backup
	if err := json.Unmarshal(raw, &b); err != nil {
		h.logf("DNS: файл с прежними настройками повреждён: %v", err)
		return nil
	}
	return &b
}

// saveBackup is written before the adapters are touched, so that a crash in the middle still leaves the way back.
func (h *Helper) saveBackup() error {
	raw, err := json.Marshal(h.backup)
	if err != nil {
		return err
	}
	tmp := h.backupPath() + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, h.backupPath())
}

func (h *Helper) dropBackup() {
	h.backup = nil
	os.Remove(h.backupPath())
}

func (h *Helper) dnsStatus() *ipc.DNSStatus {
	if h.backup == nil {
		return &ipc.DNSStatus{}
	}
	return &ipc.DNSStatus{Active: true, Provider: h.backup.Provider}
}

// tunnelDNS: the DNS of the tunnel adapter is first in the order of the system (its metric is the lowest), so with Smart DNS
// on it gets the servers of the provider too, or the names would be asked of 1.1.1.1 and Smart DNS would do nothing.
func (h *Helper) tunnelDNS() []netip.Addr {
	if h.backup != nil {
		if p, ok := dnsx.Find(h.backup.Provider); ok {
			var out []netip.Addr
			for _, a := range p.Addresses {
				if addr, err := netip.ParseAddr(a); err == nil {
					out = append(out, addr)
				}
			}
			return out
		}
	}
	return defaultTunnelDNS
}

func (h *Helper) syncTunnelDNS() {
	if h.tun != nil {
		if err := h.tun.SetDNS(h.tunnelDNS()); err != nil {
			h.logf("DNS туннеля: %v", err)
		}
	}
}

// dnsSet puts the provider on every connected adapter of the computer.
func (h *Helper) dnsSet(provider dnsx.Provider) error {
	now, err := dnsx.Adapters()
	if err != nil {
		return fmt.Errorf("не удалось получить список сетевых подключений: %w", err)
	}
	if len(now) == 0 {
		return errors.New("нет подключённой сети (Wi-Fi или Ethernet)")
	}
	next := &dnsx.Backup{}
	if h.backup != nil {
		dup := *h.backup
		dup.Adapters = append([]dnsx.Adapter(nil), h.backup.Adapters...)
		next = &dup
	}
	write := next.Apply(provider, now)
	h.backup = next
	if err := h.saveBackup(); err != nil {
		h.dropBackup()
		return fmt.Errorf("не удалось сохранить прежние настройки: %w", err)
	}
	h.logf("DNS: %s (%s) задан на %d из %d подключений", provider.Name, provider.ID, len(write), len(now))
	failed := h.writeAll(write, provider)
	dnsx.Flush()
	h.syncTunnelDNS()
	if len(failed) > 0 {
		return fmt.Errorf("DNS не применился на: %s", strings.Join(failed, ", "))
	}
	return nil
}

// dnsRestore gives back what the adapters had. It is safe to call when Smart DNS is off.
func (h *Helper) dnsRestore() error {
	if h.backup == nil {
		return nil
	}
	now, err := dnsx.Adapters()
	if err != nil {
		return fmt.Errorf("не удалось получить список сетевых подключений: %w", err)
	}
	write, skipped := h.backup.Restore(now)
	for _, name := range skipped {
		h.logf("DNS: на «%s» его уже изменили вручную, оставляю как есть", name)
	}
	failed := 0
	var names []string
	for _, a := range write {
		if err := dnsx.Write(a); err != nil {
			h.logf("DNS: вернуть прежний не вышло: %v", err)
			failed++
			names = append(names, a.Name)
			continue
		}
		if after, ok := dnsx.Current(a.GUID); ok && !dnsx.Same(after.NameServer, a.NameServer) {
			failed++
			names = append(names, a.Name)
			continue
		}
		if a.Set6 {
			h.write6(a)
		}
	}
	dnsx.Flush()
	if failed > 0 {
		// The backup stays, so that the next try (or the uninstaller) can finish the job.
		return fmt.Errorf("DNS не вернулся на: %s", strings.Join(names, ", "))
	}
	h.dropBackup()
	h.syncTunnelDNS()
	if len(write) > 0 {
		h.logf("DNS: прежние настройки возвращены на %d подключениях", len(write))
	}
	return nil
}

// writeAll sets the servers on the adapters, reads them back, and returns the names of the adapters where it did not work. The
// IPv6 servers are a lesser matter: when they do not take, it is written to the log and the adapter still counts as done.
func (h *Helper) writeAll(adapters []dnsx.Adapter, provider dnsx.Provider) (failed []string) {
	for _, a := range adapters {
		a.NameServer, a.NameServer6 = provider.Servers(), provider.Servers6()
		if err := dnsx.Write(a); err != nil {
			failed = append(failed, a.Name)
			continue
		}
		if after, ok := dnsx.Current(a.GUID); ok && !dnsx.Same(after.NameServer, a.NameServer) {
			failed = append(failed, a.Name)
			continue
		}
		if a.Set6 {
			h.write6(a)
		}
	}
	return failed
}

// write6 writes the IPv6 servers of an adapter and checks them; a failure is only logged.
func (h *Helper) write6(a dnsx.Adapter) {
	if err := dnsx.Write6(a); err != nil {
		h.logf("DNS: серверы IPv6 на «%s» не заданы: %v", a.Name, err)
		return
	}
	if after, ok := dnsx.Current(a.GUID); ok && !dnsx.Same6(after.NameServer6, a.NameServer6) {
		h.logf("DNS: серверы IPv6 на «%s» не приняты системой: %q", a.Name, after.NameServer6)
	}
}

// dnsWatcher looks at the adapters while Smart DNS is on: a new one (the person plugs in a cable, a Wi-Fi adapter wakes up) gets
// the provider too, as on the Mac.
type dnsWatcher struct {
	cb   *winipcfg.InterfaceChangeCallback
	stop chan struct{}
}

func (h *Helper) startWatching() {
	w := &dnsWatcher{stop: make(chan struct{})}
	kick := make(chan struct{}, 1)
	cb, err := winipcfg.RegisterInterfaceChangeCallback(func(t winipcfg.MibNotificationType, _ *winipcfg.MibIPInterfaceRow) {
		if t != winipcfg.MibAddInstance {
			return
		}
		select {
		case kick <- struct{}{}:
		default:
		}
	})
	if err != nil {
		h.logf("следить за новыми подключениями не получается: %v", err)
		return
	}
	w.cb = cb
	h.watch = w
	go func() {
		for {
			select {
			case <-w.stop:
				return
			case <-kick:
				// A new adapter takes a moment to get its address, and changes come in bursts.
				time.Sleep(3 * time.Second)
				h.dnsFresh()
			}
		}
	}()
}

func (h *Helper) stopWatching() {
	if h.watch == nil {
		return
	}
	h.watch.cb.Unregister()
	close(h.watch.stop)
}

// dnsFresh gives the provider to adapters that appeared after Smart DNS was turned on.
func (h *Helper) dnsFresh() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.backup == nil {
		return
	}
	provider, ok := dnsx.Find(h.backup.Provider)
	if !ok {
		return
	}
	now, err := dnsx.Adapters()
	if err != nil {
		return
	}
	write := h.backup.Fresh(provider, now)
	if len(write) == 0 {
		return
	}
	if err := h.saveBackup(); err != nil {
		h.logf("DNS: %v", err)
		return
	}
	h.logf("DNS: %s (%s) задан на %d новых подключениях", provider.Name, provider.ID, len(write))
	h.writeAll(write, provider)
	dnsx.Flush()
}
