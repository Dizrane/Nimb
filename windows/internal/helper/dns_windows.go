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
	legacyHosts := dnsx.HasLegacyGeoHideHosts()
	if h.backup == nil || h.backup.Restoring {
		return &ipc.DNSStatus{Active: legacyHosts, LegacyHosts: legacyHosts}
	}
	return &ipc.DNSStatus{Active: true, Provider: h.backup.Provider, LegacyHosts: legacyHosts}
}

// tunnelDNS: the DNS of the tunnel adapter is first in the order of the system (its metric is the lowest), so with Smart DNS
// on it gets the servers of the provider too, or the names would be asked of 1.1.1.1 and Smart DNS would do nothing.
func (h *Helper) tunnelDNS() []netip.Addr {
	if h.backup != nil && !h.backup.Restoring {
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
	if provider.Retired {
		return errors.New(provider.Name + " больше не поддерживает доступ к нейросетям. Выберите другой DNS.")
	}
	now, err := dnsx.Adapters()
	if err != nil {
		return fmt.Errorf("не удалось получить список сетевых подключений: %w", err)
	}
	if len(now) == 0 {
		return errors.New("нет подключённой сети (Wi-Fi или Ethernet)")
	}
	if err := dnsx.RemoveLegacyGeoHideHosts(); err != nil {
		return err
	}
	next := &dnsx.Backup{}
	if h.backup != nil {
		dup := *h.backup
		dup.Adapters = append([]dnsx.Adapter(nil), h.backup.Adapters...)
		next = &dup
	}
	write := next.Apply(provider, now)
	previous := h.backup
	h.backup = next
	if err := h.saveBackup(); err != nil {
		h.backup = previous
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
	if err := dnsx.RemoveLegacyGeoHideHosts(); err != nil {
		return err
	}
	if h.backup == nil {
		return nil
	}
	if !h.backup.Restoring {
		previous := h.backup
		next := *previous
		next.Restoring = true
		h.backup = &next
		if err := h.saveBackup(); err != nil {
			h.backup = previous
			return fmt.Errorf("не удалось сохранить запрос на возврат DNS: %w", err)
		}
	}
	defer h.syncTunnelDNS()
	now, err := dnsx.RestoreAdapters()
	if err != nil {
		return fmt.Errorf("не удалось получить список сетевых подключений: %w", err)
	}
	write, skipped := h.backup.Restore(now)
	for _, name := range skipped {
		h.logf("DNS: на «%s» его уже изменили вручную, оставляю как есть", name)
	}
	var failedGUIDs []string
	for _, a := range write {
		if err := dnsx.Write(a); err != nil {
			h.logf("DNS: вернуть прежний не вышло: %v", err)
			failedGUIDs = append(failedGUIDs, a.GUID)
			continue
		}
		if after, ok := dnsx.Current(a.GUID); !ok || !dnsx.Same(after.NameServer, a.NameServer) {
			failedGUIDs = append(failedGUIDs, a.GUID)
			continue
		}
		if a.Set6 {
			if err := h.write6Checked(a); err != nil {
				h.logf("DNS: вернуть прежние серверы IPv6 не вышло: %v", err)
				failedGUIDs = append(failedGUIDs, a.GUID)
			}
		}
	}
	dnsx.Flush()
	pending := h.backup.PendingRestore(now, failedGUIDs)
	if pending != nil {
		previous := h.backup
		h.backup = pending
		if err := h.saveBackup(); err != nil {
			h.backup = previous // the persisted superset still contains the way back for every adapter
			return fmt.Errorf("не удалось сохранить оставшиеся настройки DNS: %w", err)
		}
		var names []string
		for _, a := range pending.Adapters {
			names = append(names, a.Name)
		}
		return fmt.Errorf("DNS ещё не возвращён на: %s; повторю при появлении подключения", strings.Join(names, ", "))
	}
	h.dropBackup()
	if len(write) > 0 {
		h.logf("DNS: прежние настройки возвращены на %d подключениях", len(write))
	}
	return nil
}

// IPv6 failure matters too: the system can keep using those servers ahead of the selected provider.
func (h *Helper) writeAll(adapters []dnsx.Adapter, provider dnsx.Provider) (failed []string) {
	return writeDNSAdapters(adapters, provider, dnsx.Write, dnsx.Write6, dnsx.Current, h.logf)
}

// A restore must keep its backup when IPv6 could not be restored too (for example a disabled adapter rejects the write).
func (h *Helper) write6Checked(a dnsx.Adapter) error {
	if err := dnsx.Write6(a); err != nil {
		return err
	}
	after, ok := dnsx.Current(a.GUID)
	if !ok {
		return fmt.Errorf("не удалось проверить серверы IPv6 на «%s»", a.Name)
	}
	if !dnsx.Same6(after.NameServer6, a.NameServer6) {
		return fmt.Errorf("серверы IPv6 на «%s» не приняты системой: %q", a.Name, after.NameServer6)
	}
	return nil
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
	}
	w.cb = cb
	h.watch = w
	// Once a minute as well: a network can hand out its own IPv6 servers again at any moment (they are asked before ours).
	tick := time.NewTicker(time.Minute)
	go func() {
		defer tick.Stop()
		for {
			select {
			case <-w.stop:
				return
			case <-kick:
				// A new adapter takes a moment to get its address, and changes come in bursts.
				time.Sleep(3 * time.Second)
				h.dnsFresh()
			case <-tick.C:
				h.dnsFresh()
			}
		}
	}()
}

func (h *Helper) stopWatching() {
	if h.watch == nil {
		return
	}
	if h.watch.cb != nil {
		h.watch.cb.Unregister()
	}
	close(h.watch.stop)
}

// dnsFresh gives the provider to adapters that appeared after Smart DNS was turned on.
func (h *Helper) dnsFresh() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.backup == nil {
		return
	}
	if h.backup.Restoring {
		if err := h.dnsRestore(); err != nil {
			h.logf("DNS: %v", err)
		}
		return
	}
	provider, ok := dnsx.Find(h.backup.Provider)
	if !ok || provider.Retired {
		return
	}
	now, err := dnsx.Adapters()
	if err != nil {
		return
	}
	// The ones the backup knows go first: Fresh adds the new ones to it, and they are written below anyway.
	again := h.backup.Refresh6(provider, now)
	fresh := h.backup.Fresh(provider, now)
	if len(again)+len(fresh) == 0 {
		return
	}
	if err := h.saveBackup(); err != nil {
		h.logf("DNS: %v", err)
		return
	}
	if len(fresh) > 0 {
		h.logf("DNS: %s (%s) задан на %d новых подключениях", provider.Name, provider.ID, len(fresh))
	}
	if len(again) > 0 {
		h.logf("DNS: на %d подключениях серверы IPv6 снова от сети, беру их под %s", len(again), provider.Name)
	}
	h.writeAll(append(fresh, again...), provider)
	dnsx.Flush()
}
