//go:build windows

package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// Settings are what the window remembers between runs. They hold no keys of the tunnel (those stay with the service) and nothing
// about the person.
type Settings struct {
	// TelegramSecret is the key of the local proxy (32 hex digits); Telegram Desktop remembers it with the link.
	TelegramSecret string `json:"telegramSecret"`
	TelegramPort   int    `json:"telegramPort"`
	// TelegramAuto: the proxy was on when Nimb was last used, so it comes back by itself.
	TelegramAuto bool `json:"telegramAuto"`
	// Provider is the Smart DNS provider chosen last.
	Provider string `json:"provider"`
	// OnboardingDone: the first setup was gone through (or skipped).
	OnboardingDone bool `json:"onboardingDone"`
	// TunnelDropSeen is the time (unix) of the last note of a tunnel that the service took down by itself and that the person was told
	// about, so that the same drop is told once.
	TunnelDropSeen int64 `json:"tunnelDropSeen,omitempty"`
	// UpdateTold is the last version of Nimb that the person was told about with a notification (one for one version).
	UpdateTold string `json:"updateTold,omitempty"`
	// UpdateNotifyOff: the person turned the notifications about new versions off (they are on until then).
	UpdateNotifyOff bool `json:"updateNotifyOff,omitempty"`
}

type settingsStore struct {
	mu   sync.Mutex
	path string
	s    Settings
}

func dataDir() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "Nimb")
}

func loadSettings() *settingsStore {
	st := &settingsStore{path: filepath.Join(dataDir(), "settings.json")}
	if raw, err := os.ReadFile(st.path); err == nil {
		json.Unmarshal(raw, &st.s)
	}
	if len(st.s.TelegramSecret) != 32 {
		b := make([]byte, 16)
		rand.Read(b)
		st.s.TelegramSecret = hex.EncodeToString(b)
	}
	if st.s.Provider == "" {
		st.s.Provider = "geohide-eu"
	}
	st.saveLocked()
	return st
}

func (st *settingsStore) get() Settings {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.s
}

func (st *settingsStore) update(change func(*Settings)) {
	st.mu.Lock()
	defer st.mu.Unlock()
	change(&st.s)
	st.saveLocked()
}

func (st *settingsStore) saveLocked() {
	os.MkdirAll(filepath.Dir(st.path), 0o700)
	if raw, err := json.MarshalIndent(st.s, "", "  "); err == nil {
		tmp := st.path + ".tmp"
		if os.WriteFile(tmp, raw, 0o600) == nil {
			os.Rename(tmp, st.path)
		}
	}
}
