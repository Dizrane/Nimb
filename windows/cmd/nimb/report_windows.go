//go:build windows

package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
	"github.com/Dizrane/Nimb/windows/internal/probe"
	"github.com/Dizrane/Nimb/windows/internal/report"
)

// reportEnv says what names the person on this computer, so that a report can take it out.
func reportEnv() report.Environment {
	env := report.Environment{}
	env.Home, _ = os.UserHomeDir()
	if u, err := user.Current(); err == nil {
		env.UserName = u.Username
		if i := strings.LastIndex(env.UserName, `\`); i >= 0 {
			env.UserName = env.UserName[i+1:]
		}
	}
	if env.UserName == "" {
		env.UserName = os.Getenv("USERNAME")
	}
	env.ComputerName, _ = os.Hostname()
	if facts, err := dnsx.Describe(); err == nil {
		for _, f := range facts {
			env.Connections = append(env.Connections, f.Name)
		}
	}
	return env
}

// ReportPrep is what the page shows when the form opens.
type ReportPrep struct {
	ID    string `json:"id"`
	Facts string `json:"facts"`
}

// ReportPrepare collects the facts for a report (it takes a few seconds: it asks Cloudflare where the traffic leaves from).
func (a *App) ReportPrepare() ReportPrep {
	id := report.NewID()
	st := a.GetState()
	var out []string

	out = append(out, report.Section("Программа",
		"Nimb для Windows "+Version,
		"Windows "+windowsVersion()+", "+runtime.GOARCH,
		"Язык системы: "+uiLanguage(),
		"Прошлый запуск закончился неожиданно: "+yesNo(a.previousEndedBadly),
		"Автозапуск с Windows: "+yesNo(autostartOn()),
	))

	svc := []string{}
	if !st.ServiceOK {
		svc = append(svc, "Служба Nimb: не отвечает ("+st.ServiceError+")")
	} else {
		svc = append(svc, "Служба Nimb: отвечает")
	}
	svc = append(svc,
		"Нейросети (DNS): "+onOff(st.AI.On, providerName(st.AI.Provider))+"; выбран "+providerName(a.settings.get().Provider),
		fmt.Sprintf("Telegram (прокси): %s; соединений %d, ошибок %d, чужой ключ %d, через WebSocket %d, напрямую %d",
			onOff(st.Telegram.On, fmt.Sprintf("порт %d", st.Telegram.Port)), st.Telegram.Stats.Total, st.Telegram.Stats.Failures,
			st.Telegram.Stats.WrongSecret, st.Telegram.Stats.WebSocket, st.Telegram.Stats.DirectTCP),
		"YouTube и Discord (туннель): "+onOff(st.Media.On, fmt.Sprintf("рукопожатие %d с назад", st.Media.HandshakeAgo)),
	)
	out = append(out, report.Section("Сервисы", svc...))

	var shown []string
	for _, e := range []string{st.AI.Error, st.Telegram.Error, st.Media.Error, st.ServiceError} {
		if e != "" {
			shown = append(shown, e)
		}
	}
	if len(shown) > 0 {
		out = append(out, report.Section("Ошибки на экране", shown...))
	}

	out = append(out, report.Section("Сеть", cloudflareFacts()...))

	// Which names go through which connection and which DNS: what keeps Smart DNS from working shows here (DNS of IPv6, other
	// connections with a DNS of their own).
	if facts, err := dnsx.Describe(); err == nil {
		var lines []string
		for _, f := range facts {
			lines = append(lines, f.Line())
		}
		out = append(out, report.Section("Подключения и их DNS", lines...))
	}
	if hint := a.browserHint(); hint != "" {
		out = append(out, report.Section("Браузер", "Firefox установлен, «DNS через HTTPS» в нём не выключен"))
	}

	probed := a.probeForReport()
	if len(probed) > 0 {
		out = append(out, report.Section("Проверка DNS", probe.Lines(probed)...))
	}

	if resp, err := callService(ipc.Request{Cmd: ipc.Diag}); err == nil && len(resp.Lines) > 0 {
		out = append(out, report.Section("Служба", resp.Lines...))
	}

	log := tailLog(filepath.Join(dataDir(), "window.log"), 60)
	if len(log) == 0 {
		log = []string{"пусто"}
	}
	out = append(out, report.Section("Журнал окна (последние строки)", log...))

	env := reportEnv()
	env.Public = probe.Addresses(probed)
	facts := report.Clean(strings.Join(out, "\n\n"), env)
	a.mu.Lock()
	a.reportID, a.reportFacts = id, facts
	a.mu.Unlock()
	return ReportPrep{ID: id, Facts: facts}
}

func (a *App) reportText(description, contact string) (id, text string) {
	a.mu.Lock()
	id, facts := a.reportID, a.reportFacts
	a.mu.Unlock()
	return id, report.Head(id, description, contact, reportEnv()) + "\n\n" + facts
}

// ReportPreview is the whole text that would be sent.
func (a *App) ReportPreview(description, contact string) string {
	_, text := a.reportText(description, contact)
	return text
}

// ReportSend sends the report to the developer through the relay.
func (a *App) ReportSend(description, contact string) Result {
	id, text := a.reportText(description, contact)
	logLine("report " + id + ": sending")
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := report.Send(ctx, Version, id, text); err != nil {
		logLine("report " + id + ": not sent: " + err.Error())
		return Result{Error: err.Error()}
	}
	logLine("report " + id + ": sent")
	return Result{OK: true}
}

// ReportCopy puts the whole report on the clipboard.
func (a *App) ReportCopy(description, contact string) Result {
	_, text := a.reportText(description, contact)
	if err := wruntime.ClipboardSetText(a.ctx, text); err != nil {
		return Result{Error: "Не удалось скопировать."}
	}
	return Result{OK: true}
}

// ReportWrite copies the report (cut to one message) and opens the chat with the developer, for when sending does not work.
func (a *App) ReportWrite(description, contact string) Result {
	id, text := a.reportText(description, contact)
	if err := wruntime.ClipboardSetText(a.ctx, report.Fitted(text, report.MessageLimit)); err != nil {
		return Result{Error: "Не удалось скопировать."}
	}
	cmd := exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", "tg://resolve?domain="+report.DeveloperHandle)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if cmd.Start() != nil {
		wruntime.BrowserOpenURL(a.ctx, "https://t.me/"+report.DeveloperHandle)
	}
	logLine("report " + id + ": copied for the chat with the developer")
	return Result{OK: true}
}

func yesNo(b bool) string {
	if b {
		return "да"
	}
	return "нет"
}

func onOff(on bool, detail string) string {
	if on {
		return "включено, " + detail
	}
	return "выключено"
}

func providerName(id string) string {
	for _, p := range providerList() {
		if p.ID == id {
			return p.Name
		}
	}
	return "?"
}

// windowsVersion names the Windows of this computer. The ProductName of the registry still says "Windows 10" on Windows 11, so the
// number of the build decides (22000 and above is Windows 11).
func windowsVersion() string {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion`, registry.QUERY_VALUE)
	if err != nil {
		return "?"
	}
	defer k.Close()
	display, _, _ := k.GetStringValue("DisplayVersion")
	build, _, _ := k.GetStringValue("CurrentBuild")
	name := "10"
	if n, err := strconv.Atoi(build); err == nil && n >= 22000 {
		name = "11"
	}
	return strings.TrimSpace(fmt.Sprintf("%s %s (сборка %s)", name, display, build))
}

func uiLanguage() string {
	if langs, err := windows.GetUserPreferredUILanguages(windows.MUI_LANGUAGE_NAME); err == nil && len(langs) > 0 {
		return langs[0]
	}
	return "?"
}

// cloudflareFacts asks Cloudflare where the traffic leaves from (warp=on means through the tunnel).
func cloudflareFacts() []string {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://www.cloudflare.com/cdn-cgi/trace", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return []string{"Cloudflare не ответил за 6 секунд (интернета нет или он закрыт)"}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
	var facts []string
	for _, line := range strings.Split(string(raw), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok && (k == "warp" || k == "loc" || k == "colo" || k == "http") {
			facts = append(facts, k+"="+v)
		}
	}
	return []string{"Cloudflare: " + strings.Join(facts, ", ")}
}

func tailLog(path string, n int) []string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\r\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}
