//go:build windows

package helper

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/ipc"
	"github.com/Dizrane/Nimb/windows/internal/tgproxy"
)

// The proxy of Telegram lives in the service, not in the window: the window can be closed to the tray, or die (the browser process of
// WebView2 is not ours and can end), and Telegram goes on working. The service starts it again after a restart of the computer if it was on,
// and the window only asks it to be switched on or off and draws what the service says.

func (h *Helper) telegramPath() string { return filepath.Join(h.dir, "telegram.json") }

func (h *Helper) loadTelegram() {
	raw, err := os.ReadFile(h.telegramPath())
	if err != nil {
		return
	}
	var s tgproxy.Settings
	if json.Unmarshal(raw, &s) != nil || !tgproxy.ValidSecret(s.Secret) {
		h.logf("прокси Telegram: файл настроек повреждён, прокси выключен")
		return
	}
	h.tg = s
}

func (h *Helper) saveTelegram() {
	raw, _ := json.Marshal(h.tg)
	tmp := h.telegramPath() + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		h.logf("прокси Telegram: настройки не сохранены: %v", err)
		return
	}
	os.Rename(tmp, h.telegramPath())
}

// startTelegramWatch is called once, by New: it brings the proxy back if it was on, and keeps an eye on it.
func (h *Helper) startTelegramWatch() {
	tgproxy.OnPanic = func(where string, value any, stack []byte) {
		h.logf("ПАНИКА (остановлена, служба продолжает) в «%s»: %v", where, value)
		for i, line := range strings.Split(strings.TrimRight(string(stack), "\n"), "\n") {
			if i >= 30 {
				break
			}
			h.logf("    %s", strings.TrimRight(line, "\r"))
		}
	}
	h.tgStop = make(chan struct{})
	h.mu.Lock()
	if h.tg.Auto {
		h.logf("прокси Telegram: был включён, включаю снова")
		if err := h.telegramStart(); err != nil {
			h.logf("прокси Telegram: %v", err)
		}
	}
	h.mu.Unlock()
	go func() {
		defer func() {
			if v := recover(); v != nil {
				h.logf("ПАНИКА в слежении за прокси Telegram: %v\n%s", v, debug.Stack())
			}
		}()
		tick := time.NewTicker(6 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-h.tgStop:
				return
			case <-tick.C:
				h.watchTelegram()
			}
		}
	}()
}

// watchTelegram brings the port back when it stops listening (a sleep, another program took it), up to three tries.
func (h *Helper) watchTelegram() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.tg.Auto || h.engine == nil || h.engine.IsListening() {
		return
	}
	wanted := h.engine.Port()
	h.engine.Stop()
	for attempt := 1; attempt <= 3; attempt++ {
		h.mu.Unlock()
		time.Sleep(time.Duration(attempt) * time.Second)
		h.mu.Lock()
		if !h.tg.Auto {
			return // switched off while waiting
		}
		if port, err := h.engine.Start(uint16(max(int(wanted), 1024))); err == nil {
			h.tg.Port = int(port)
			h.saveTelegram()
			h.logf("прокси Telegram: порт слушает снова (%d)", port)
			return
		}
	}
	h.tg.Auto = false
	h.saveTelegram()
	h.telegramError = "Прокси остановился и не смог запуститься снова: порт, возможно, занят другой программой. Включите его ещё раз."
	h.logf("прокси Telegram: остановился и не запустился снова, выключен")
}

// telegramStart opens the port. The caller holds the lock.
func (h *Helper) telegramStart() error {
	if h.engine == nil {
		e, err := tgproxy.New(h.tg.Secret, tgproxy.DefaultConfig())
		if err != nil {
			return err
		}
		e.SetLogf(func(line string) {
			// A line for each connection would drown the log; the numbers are in the status. The start and the stop are told.
			if strings.HasPrefix(line, "Слушаю") || strings.HasPrefix(line, "Остановлен") {
				h.logf("прокси Telegram: %s", line)
			}
		})
		h.engine = e
	}
	if h.engine.IsListening() {
		return nil
	}
	port, err := h.engine.Start(uint16(h.tg.PreferredPort()))
	if err != nil {
		return fmt.Errorf("не удалось запустить прокси: %w", err)
	}
	h.tg.Port = int(port)
	h.telegramError = ""
	return nil
}

// telegramUp switches the proxy on. secret and port come from the window and count only when the service has no key yet (an earlier version
// had the proxy in the window, and the Telegram of the person knows its key and port).
func (h *Helper) telegramUp(secret string, port int) error {
	if err := h.tg.Adopt(secret, port); err != nil {
		return err
	}
	if err := h.telegramStart(); err != nil {
		return err
	}
	h.tg.Auto = true
	h.saveTelegram()
	return nil
}

func (h *Helper) telegramDown() {
	h.tg.Auto = false
	h.telegramError = ""
	if h.engine != nil {
		h.engine.Stop()
	}
	h.saveTelegram()
}

func (h *Helper) telegramStatus() *ipc.TelegramStatus {
	st := &ipc.TelegramStatus{Error: h.telegramError}
	if h.engine != nil && h.engine.IsListening() {
		st.On = true
		st.Port = int(h.engine.Port())
		st.Secret = h.tg.Secret
		st.Stats = h.engine.Stats()
	}
	return st
}
