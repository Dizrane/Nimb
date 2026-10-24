//go:build windows

package helper

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/report"
	"github.com/Dizrane/Nimb/windows/internal/version"
)

// serviceLogLines is how much of the log of the service goes to the window (the report makes the events of the day of it).
const serviceLogLines = 300

// diag is what the service tells for a report about a problem: its version, the state of the adapters and of the tunnel, and the
// end of its own log. No keys, no tokens, no contents of the files of the account.
func (h *Helper) diag() []string {
	lines := []string{fmt.Sprintf("Служба Nimb %s, работает с %s", version.Version, h.started.Format("2006-01-02 15:04:05"))}

	st := h.status()
	if addr := h.tunnelServer(); addr != "" {
		how := "из аккаунта"
		if h.server != "" {
			how = "найден поиском: на нём открываются YouTube и Discord"
		}
		lines = append(lines, "Сервер туннеля: "+addr+" ("+how+")")
	}
	if st.Restarting {
		lines = append(lines, "Туннель: программа остановилась сама, служба запускает её снова")
	} else if st.Up {
		lines = append(lines, fmt.Sprintf("Туннель: включён, последнее рукопожатие %d с назад, принято %s, отправлено %s", st.HandshakeAgo, report.Bytes(st.Received), report.Bytes(st.Sent)))
	} else {
		lines = append(lines, fmt.Sprintf("Туннель: выключен; аккаунт WARP есть: %s", yesNo(st.HasAccount)))
	}
	lines = append(lines, "Аккаунт WARP: "+yesNo(st.HasAccount))
	if tg := h.telegramStatus(); tg.On {
		lines = append(lines, fmt.Sprintf("Прокси Telegram (в службе): включён, порт %d, соединений %d (сейчас %d), через WebSocket %d, напрямую %d, ошибок %d, чужой ключ %d", tg.Port, tg.Stats.Total, tg.Stats.Active, tg.Stats.WebSocket, tg.Stats.DirectTCP, tg.Stats.Failures, tg.Stats.WrongSecret))
	} else {
		lines = append(lines, "Прокси Telegram (в службе): выключен; должен быть включён после перезапуска: "+yesNo(h.tg.Auto))
	}
	if n := len(st.Restarts); n > 0 {
		lines = append(lines, fmt.Sprintf("Программа туннеля сама останавливалась и запускалась снова за сутки: %d", n))
	}
	if h.backup != nil {
		name := h.backup.Provider
		if p, ok := dnsx.Find(h.backup.Provider); ok {
			name = p.Name
		}
		lines = append(lines, "Smart DNS: включён, провайдер "+name)
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
	if tail := tailFile(filepath.Join(h.dir, "service.log"), serviceLogLines); len(tail) > 0 {
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
