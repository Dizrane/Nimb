//go:build windows

package main

import (
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"

	"github.com/Dizrane/Nimb/windows/internal/ipc"
)

func (a *App) exitInProgress() bool { return a.quitRequested.Load() || a.quitting.Load() }

// shutdownServices uses the same bounded commands as the switches. SetAll(false) cannot be used here: it skips a busy DNS/proxy
// switch, which could then finish turning on after Nimb exits. New switches are blocked by quitRequested while this runs.
func (a *App) shutdownServices(request func(ipc.Request) (ipc.Response, error)) []string {
	logLine("выход: отменяю подключения и выключаю DNS, прокси Telegram и туннель")
	a.settings.update(func(s *Settings) {
		s.TunnelWanted = false
		s.TelegramAuto = false
	})
	a.mu.Lock()
	attempt := a.mediaAttempt
	mediaBusy := a.busy["media"]
	a.mu.Unlock()
	if mediaBusy && attempt != "" {
		// Send cancellation before waiting: startup holds the helper's lock until it is cancelled.
		// The final down below is repeated after all earlier switches have finished.
		if _, err := request(ipc.Request{Cmd: ipc.TunnelDown, Attempt: attempt}); err != nil {
			logLine("выход: ранняя отмена запуска туннеля: " + err.Error())
		}
	}

	deadline := time.Now().Add(3 * time.Minute)
	for {
		a.mu.Lock()
		pending := a.busy["ai"] || a.busy["telegram"] || a.busy["media"]
		a.mu.Unlock()
		if !pending {
			break
		}
		if a.quitting.Load() {
			return []string{"Системное завершение прервало отключение сервисов"}
		}
		if time.Now().After(deadline) {
			return []string{"Предыдущее переключение не завершилось: отключение сервисов не подтверждено"}
		}
		time.Sleep(100 * time.Millisecond)
	}

	var problems []string
	for _, step := range []struct{ name, cmd string }{
		{"Туннель YouTube и Discord", ipc.TunnelDown},
		{"Прокси Telegram", ipc.TelegramDown},
		{"DNS нейросетей", ipc.DNSRestore},
	} {
		resp, err := request(ipc.Request{Cmd: step.cmd})
		if err != nil {
			problems = append(problems, step.name+": "+err.Error())
		} else if !resp.OK {
			message := resp.Error
			if message == "" {
				message = "служба не подтвердила отключение"
			}
			problems = append(problems, step.name+": "+message)
		}
	}
	// Clear the saved intent again after earlier startup completions and verify the actual state.
	a.settings.update(func(s *Settings) {
		s.TunnelWanted = false
		s.TelegramAuto = false
	})
	status, err := request(ipc.Request{Cmd: ipc.Status})
	if err != nil || !status.OK {
		problems = append(problems, "Не удалось подтвердить состояние сервисов после отключения")
	} else {
		if status.Tunnel == nil || status.Tunnel.Up || status.Tunnel.Restarting {
			problems = append(problems, "Отключение туннеля не подтверждено")
		}
		if status.Telegram == nil || status.Telegram.On {
			problems = append(problems, "Остановка прокси Telegram не подтверждена")
		}
		if status.DNS == nil || status.DNS.Active {
			problems = append(problems, "Восстановление DNS не подтверждено")
		}
	}
	if len(problems) == 0 {
		logLine("выход: DNS восстановлен, прокси Telegram и туннель выключены")
	} else {
		logLine("выход: отключение завершено не полностью: " + strings.Join(problems, "; "))
	}
	return problems
}

func (a *App) confirmQuitLeaving(problems []string) bool {
	a.ShowWindow()
	title, _ := syscall.UTF16PtrFromString("Не всё удалось выключить")
	text, _ := syscall.UTF16PtrFromString("Не удалось подтвердить полное отключение:\n\n" + strings.Join(problems, "\n") +
		"\n\nЕсли выйти сейчас, часть сервисов может остаться включённой. Выйти всё равно?\n\n«Нет» — остаться в Nimb.")
	const yesNo, warning, defaultNo, topmost = 0x4, 0x30, 0x100, 0x40000
	answer, _ := windows.MessageBox(0, text, title, yesNo|warning|defaultNo|topmost)
	return answer == 6 // IDYES; No, a closed dialog, or an error keeps Nimb running.
}
