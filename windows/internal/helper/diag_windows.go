//go:build windows

package helper

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/version"
)

// diag is what the service tells for a report about a problem: its version, the state of the adapters and of the tunnel, and the
// end of its own log. No keys, no tokens, no contents of the files of the account.
func (h *Helper) diag() []string {
	lines := []string{fmt.Sprintf("Служба Nimb %s, работает с %s", version.Version, h.started.Format("2006-01-02 15:04:05"))}

	st := h.status()
	if st.Up {
		lines = append(lines, fmt.Sprintf("Туннель: включён, последнее рукопожатие %d с назад, принято %d, отправлено %d байт", st.HandshakeAgo, st.Received, st.Sent))
	} else {
		lines = append(lines, fmt.Sprintf("Туннель: выключен; аккаунт WARP есть: %s", yesNo(st.HasAccount)))
	}
	if h.backup != nil {
		lines = append(lines, "Smart DNS: включён, провайдер "+h.backup.Provider)
	} else {
		lines = append(lines, "Smart DNS: выключен")
	}
	if adapters, err := dnsx.Adapters(); err != nil {
		lines = append(lines, "Сетевые подключения не прочитаны: "+err.Error())
	} else {
		for _, a := range adapters {
			servers := a.NameServer
			if servers == "" {
				servers = "автоматический (DHCP)"
			}
			line := fmt.Sprintf("DNS на «%s»: %s", a.Name, servers)
			if a.V6 {
				servers6 := a.NameServer6
				if servers6 == "" {
					servers6 = "от сети"
				}
				line += "; IPv6: " + servers6
			}
			lines = append(lines, line)
		}
		if len(adapters) == 0 {
			lines = append(lines, "Подходящих сетевых подключений (Wi-Fi, Ethernet) нет")
		}
	}
	if tail := tailFile(filepath.Join(h.dir, "service.log"), 40); len(tail) > 0 {
		lines = append(lines, "", "Журнал службы:")
		lines = append(lines, tail...)
	}
	return lines
}

func yesNo(b bool) string {
	if b {
		return "да"
	}
	return "нет"
}

// tailFile returns the last n lines of a text file.
func tailFile(path string, n int) []string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	if len(raw) > 200_000 {
		raw = raw[len(raw)-200_000:]
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\r\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}
