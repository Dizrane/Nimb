//go:build windows

package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"github.com/Dizrane/Nimb/windows/internal/autoreport"
)

// Settings are what the window remembers between runs. They hold no keys of the tunnel (those stay with the service) and nothing
// about the person.
type Settings struct {
	// TelegramSecret is the key of the local proxy (32 hex digits); Telegram Desktop remembers it with the link.
	TelegramSecret string `json:"telegramSecret"`
	TelegramPort   int    `json:"telegramPort"`
	// TelegramAuto is from the time the proxy lived in the window (0.2.0 and before): it was on. The window gives it to the service once and clears
	// it. TelegramSecret and TelegramPort are the key and the port that the window offers the service when the proxy is switched on.
	TelegramAuto bool `json:"telegramAuto"`
	// Provider is the Smart DNS provider chosen last.
	Provider string `json:"provider"`
	// OnboardingDone: the first setup was gone through (or skipped).
	OnboardingDone bool `json:"onboardingDone"`
	// TunnelDropSeen is the time (unix) of the last note of a tunnel that the service took down by itself and that the person was told
	// about, so that the same drop is told once.
	TunnelDropSeen int64 `json:"tunnelDropSeen,omitempty"`
	// TunnelWanted: the tunnel was on when the person last used it, so that it comes back after the computer was restarted. Switching it off
	// by hand, and removing Nimb, clear it.
	TunnelWanted bool `json:"tunnelWanted,omitempty"`
	// TunnelRestartsSeen is the time (unix) of the last restart of the program of the tunnel that went to the log of the window.
	TunnelRestartsSeen int64 `json:"tunnelRestartsSeen,omitempty"`
	// UpdateTold is the last version of Nimb that the person was told about with a notification (one for one version).
	UpdateTold string `json:"updateTold,omitempty"`
	// UpdateNotifyOff: the person turned the notifications about new versions off (they are on until then).
	UpdateNotifyOff bool `json:"updateNotifyOff,omitempty"`
	// WindowSized: the window has been given its size (client area 1100 by 660) once; after that the size the person left is kept.
	WindowSized bool `json:"windowSized,omitempty"`

	// «Помогать тестированию» (off until the person turns it on, see autoreport_windows.go). HelpInstall is the random number of this
	// installation (it is wiped when the switch is turned off, and so is everything below); HelpHistory are the reports that went in the last
	// day (their cause and time); HelpCount and HelpLast are how many went and when the last one did (unix); HelpDigest is when the last
	// digest of the day went, or when the switch was turned on.
	HelpTesting bool              `json:"helpTesting,omitempty"`
	HelpInstall string            `json:"helpInstall,omitempty"`
	HelpHistory []autoreport.Sent `json:"helpHistory,omitempty"`
	HelpCount   int               `json:"helpCount,omitempty"`
	HelpLast    int64             `json:"helpLast,omitempty"`
	HelpDigest  int64             `json:"helpDigest,omitempty"`
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
