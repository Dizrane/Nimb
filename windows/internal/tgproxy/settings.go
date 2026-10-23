package tgproxy

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"regexp"
	"strings"
)

// Settings are what the service keeps of the proxy: the key (the links that the Telegram of the person has stored use it), the port, and
// whether it is on (it then comes back after a restart of the service or of the computer).
type Settings struct {
	Secret string `json:"secret"`
	Port   int    `json:"port"`
	Auto   bool   `json:"auto"`
}

// DefaultPort is the port that is tried first when nothing else is known.
const DefaultPort = 1443

var reSecret = regexp.MustCompile(`^[0-9a-fA-F]{32}$`)

// ValidSecret: 32 hexadecimal digits.
func ValidSecret(s string) bool { return reSecret.MatchString(s) }

// Adopt gives the settings a key and a port when they have none. The window of an earlier version, which had the proxy inside it, offers the
// key and the port that the Telegram of the person already knows; they count only the first time (the service keeps its own after that), and
// only when they are valid (32 hex digits, a port from 1024). Without an offer a key is made.
func (s *Settings) Adopt(offeredSecret string, offeredPort int) error {
	if s.Secret == "" {
		if ValidSecret(offeredSecret) {
			s.Secret = strings.ToLower(offeredSecret)
		} else {
			b := make([]byte, 16)
			if _, err := rand.Read(b); err != nil {
				return errors.New("не удалось придумать ключ для прокси")
			}
			s.Secret = hex.EncodeToString(b)
		}
		if offeredPort >= 1024 && offeredPort <= 65535 && s.Port == 0 {
			s.Port = offeredPort
		}
	}
	return nil
}

// PreferredPort is the port to try first.
func (s Settings) PreferredPort() int {
	if s.Port < 1024 || s.Port > 65535 {
		return DefaultPort
	}
	return s.Port
}
