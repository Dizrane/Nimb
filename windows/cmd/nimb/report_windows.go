//go:build windows

package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
	"github.com/Dizrane/Nimb/windows/internal/netfacts"
	"github.com/Dizrane/Nimb/windows/internal/probe"
	"github.com/Dizrane/Nimb/windows/internal/report"
	"github.com/Dizrane/Nimb/windows/internal/tunneldrop"
	"github.com/Dizrane/Nimb/windows/internal/winevents"
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

// ReportPrepare collects the facts for a report (it takes a while: it asks Cloudflare where the traffic leaves from and, when the
// providers have not been checked lately, asks them).
func (a *App) ReportPrepare() ReportPrep {
	id := report.NewID()
	st := a.GetState()
	var out []string

	_, offset := time.Now().Zone()
	out = append(out, report.Section("Программа",
		"Nimb для Windows "+Version,
		"Windows "+windowsVersion()+", "+runtime.GOARCH,
		"Язык системы: "+uiLanguage()+", часовой пояс UTC"+utcOffset(offset),
		"Отчёт собран: "+time.Now().Format("2006-01-02 15:04:05"),
		windowFacts(),
		"Компьютер включён с "+time.Now().Add(-windows.DurationSinceBoot()).Format("2006-01-02 15:04:05")+" (работает "+uptimeText(windows.DurationSinceBoot())+")",
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
		"Обновления: "+updateLine(st.Update),
	)
	out = append(out, report.Section("Сервисы", svc...))

	// The three things that are asked of the system, side by side (they all wait for the network).
	var trace map[string]string
	var probed []probe.ProviderReport
	var diag *ipc.Response
	var system, provider []string
	host := probe.All[0].Host
	var wg sync.WaitGroup
	wg.Add(4)
	go func() {
		defer wg.Done()
		safely("запрос к Cloudflare для отчёта", func() { trace = cloudflareTrace() })
	}()
	go func() {
		defer wg.Done()
		safely("проверка DNS для отчёта", func() { probed = a.probeForReport() })
	}()
	go func() {
		defer wg.Done()
		if resp, err := callService(ipc.Request{Cmd: ipc.Diag}); err == nil {
			diag = &resp
		}
	}()
	go func() {
		defer wg.Done()
		safely("ответы DNS для отчёта", func() { system, provider = a.dnsAnswers(host, st.AI.On, st.AI.Provider) })
	}()
	wg.Wait()

	adapters, _ := dnsx.Adapters()
	var active *dnsx.Provider
	if p, ok := dnsx.Find(st.AI.Provider); ok && st.AI.On {
		active = &p
	}
	routes, via, viaTunnel := netfacts.Routes("Nimb")
	dropped := ""
	if st.Media.DroppedAt > 0 && time.Since(time.Unix(st.Media.DroppedAt, 0)) < tunneldrop.NewsFor {
		dropped = st.Media.DropReason + " в " + time.Unix(st.Media.DroppedAt, 0).Format("01-02 15:04")
	}
	tg := st.Telegram.Stats
	out = append(out, report.Section("Что ждали и что увидели", joinLines(
		report.DNS(report.DNSFacts{Active: active, Adapters: adapters, Host: host, SystemAnswer: system, SystemFailed: system == nil && st.AI.On, ProviderAnswer: provider}).Lines(),
		report.Telegram(report.TelegramFacts{Running: st.Telegram.On, Port: st.Telegram.Port, Listening: st.Telegram.On, Total: tg.Total, Failures: tg.Failures,
			WrongSecret: tg.WrongSecret, WebSocket: tg.WebSocket, Direct: tg.DirectTCP}).Lines(),
		report.Tunnel(report.TunnelFacts{On: st.Media.On, Routes: routes, Via: via, ViaTunnel: viaTunnel, Warp: trace["warp"], Dropped: dropped, Restarts: unixTimes(st.Media.Restarts)}).Lines(),
	)...))

	var shown []string
	for _, e := range []string{st.AI.Error, st.Telegram.Error, st.Media.Error, st.ServiceError, st.Update.Error} {
		if e != "" {
			shown = append(shown, e)
		}
	}
	if len(shown) > 0 {
		out = append(out, report.Section("Ошибки на экране", shown...))
	}
	if hint := a.browserHint(); hint != "" {
		out = append(out, report.Section("Предупреждения DNS", "Firefox установлен, «DNS через HTTPS» в нём не выключен"))
	}
	if len(probed) > 0 {
		out = append(out, report.Section("Проверка DNS", probe.Lines(probed)...))
	}

	out = append(out, report.Section("Сеть", append([]string{cloudflareLine(trace)}, netfacts.RouteLines("Nimb")...)...))
	// Which address belongs to which provider: the addresses stay in the report as they are, and this says whose they are.
	var servers []string
	for _, p := range dnsx.Providers {
		servers = append(servers, p.Name+" ("+p.ID+"): "+strings.Join(p.Addresses, ", "))
	}
	out = append(out, report.Section("Серверы DNS провайдеров", servers...))
	// Which names go through which connection and which DNS: what keeps Smart DNS from working shows here (DNS of IPv6, other
	// connections with a DNS of their own).
	vpns := 0
	if facts, err := dnsx.Describe(); err == nil {
		var lines []string
		for _, f := range facts {
			lines = append(lines, f.Line())
			if f.Up && !f.Hardware && !report.IsGenericConnection(f.Name) && f.Kind != "петля" {
				vpns++
			}
		}
		out = append(out, report.Section("Подключения и их DNS", lines...))
	}
	serviceVersion := ""
	if diag != nil {
		serviceVersion = diag.Version
	}
	wininet, wininetServer, wininetPAC := netfacts.WinINet()
	winhttp, winhttpServer, winhttpPAC := netfacts.WinHTTP()
	domains := []string{"telegram.org", "t.me", "youtube.com", "discord.com"}
	for _, t := range probe.All {
		domains = append(domains, t.Host)
	}
	out = append(out, report.Section("Что могло помешать", report.Interference(report.InterferenceFacts{
		WinINet: report.ProxyKinds(wininet, wininetServer, wininetPAC), WinHTTP: report.ProxyKinds(winhttp, winhttpServer, winhttpPAC),
		VPNs: vpns, Hosts: report.HostsMentions(netfacts.Hosts(), domains), WindowVersion: Version, ServiceVersion: serviceVersion, UTCOffset: utcOffset(offset),
	})...))

	// The service says what it is and then its log: the log goes into the chronology, the head stays as it is.
	var serviceHead, serviceLog []string
	if diag != nil {
		serviceHead = diag.Lines
		for i, l := range diag.Lines {
			if l == "Журнал службы:" {
				serviceHead, serviceLog = diag.Lines[:i], diag.Lines[i+1:]
				break
			}
		}
		if len(serviceHead) > 0 {
			out = append(out, report.Section("Служба", serviceHead...))
		}
	}
	out = append(out, report.Section("Процесс окна", a.processFacts()...))
	// What Windows itself wrote about the programs of Nimb: the code of a crash, and what the service manager did with the service.
	var winEvents []string
	winEvents = append(winEvents, winevents.Query("Application", "(EventID=1000 or EventID=1001)", 24*time.Hour, []string{"Nimb.exe", "nimb-svc.exe"}, 8)...)
	winEvents = append(winEvents, winevents.Query("System", "Provider[@Name='Service Control Manager'] and (EventID=7000 or EventID=7009 or EventID=7011 or EventID=7023 or EventID=7024 or EventID=7031 or EventID=7034)", 24*time.Hour, []string{"NimbHelper", "Nimb"}, 8)...)
	if len(winEvents) == 0 {
		winEvents = []string{"за последние сутки Windows не записала ни сбоев Nimb, ни аварийных остановок службы"}
	}
	out = append(out, report.Section("События Windows о Nimb (последние сутки)", winEvents...))
	if diag != nil {
		out = append(out, report.Section("Метки службы в журнале туннеля (с начала файла)", report.LogTail(diag.TunnelMarks, 30)...))
		out = append(out, report.Section("Процесс туннеля (последние строки его журнала)", report.LogTail(diag.TunnelLog, 25)...))
	}
	windowLog := tailLog(filepath.Join(dataDir(), "window.log"), 500)
	events := append(report.ParseLog("окно", windowLog, time.Local), report.ParseLog("служба", serviceLog, time.Local)...)
	out = append(out, report.Section("Хронология (последние сутки)", report.Events(events, time.Now(), 24*time.Hour, 60)...))
	if a.previousEndedBadly {
		out = append(out, report.Section("Перед неожиданным завершением (последние строки журнала прошлого запуска)", beforeThisRun(windowLog, 20)...))
	}
	raw := windowLog
	if len(raw) > 60 {
		raw = raw[len(raw)-60:]
	}
	if len(raw) == 0 {
		raw = []string{"пусто"}
	}
	out = append(out, report.Section("Журнал окна (последние строки)", raw...))

	env := reportEnv()
	// The addresses of the providers (their DNS servers and the pools that the check found) stay as they are: nothing of the person is in
	// them, and a bad address is what a report is read for.
	env.Public = probe.Addresses(probed)
	for _, p := range dnsx.Providers {
		env.Public = append(env.Public, p.Addresses...)
	}
	facts := report.Clean(strings.Join(out, "\n\n"), env)
	a.mu.Lock()
	a.reportID, a.reportFacts = id, facts
	a.mu.Unlock()
	return ReportPrep{ID: id, Facts: facts}
}

func joinLines(parts ...[]string) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func utcOffset(seconds int) string {
	sign := "+"
	if seconds < 0 {
		sign, seconds = "-", -seconds
	}
	s := sign + strconv.Itoa(seconds/3600)
	if m := seconds / 60 % 60; m != 0 {
		s += fmt.Sprintf(":%02d", m)
	}
	return s
}

// dnsAnswers asks the system for host the way a program does, and the provider of Smart DNS for the same name. system is nil when the
// system gave nothing; provider is nil when Smart DNS is off or the provider did not answer.
func (a *App) dnsAnswers(host string, on bool, providerID string) (system, provider []string) {
	if !on {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if ips, err := net.DefaultResolver.LookupIP(ctx, "ip4", host); err == nil {
		for _, ip := range ips {
			system = append(system, ip.String())
		}
	}
	if p, ok := dnsx.Find(providerID); ok {
		provider = (&probe.Prober{}).Resolve(ctx, host, p.Addresses)
	}
	return system, provider
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
	logLine("отчёт " + id + ": отправляю")
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := report.Send(ctx, Version, id, text); err != nil {
		logLine("отчёт " + id + ": не отправлен: " + err.Error())
		return Result{Error: err.Error()}
	}
	logLine("отчёт " + id + ": отправлен")
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
	logLine("отчёт " + id + ": скопирован для чата с разработчиком")
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

// cloudflareTrace asks Cloudflare where the traffic leaves from (warp=on means through the tunnel); nil when it does not answer.
func cloudflareTrace() map[string]string {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://www.cloudflare.com/cdn-cgi/trace", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
	facts := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok && (k == "warp" || k == "loc" || k == "colo" || k == "http") {
			facts[k] = v
		}
	}
	return facts
}

func cloudflareLine(facts map[string]string) string {
	if facts == nil {
		return "Cloudflare не ответил за 6 секунд (интернета нет или он закрыт)"
	}
	var parts []string
	for _, k := range []string{"colo", "http", "loc", "warp"} {
		if v, ok := facts[k]; ok {
			parts = append(parts, k+"="+v)
		}
	}
	return "Cloudflare: " + strings.Join(parts, ", ")
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

// uptimeText: "2 ч 05 мин", "3 сут 4 ч".
func uptimeText(d time.Duration) string {
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	minutes := int(d.Minutes()) % 60
	if days > 0 {
		return fmt.Sprintf("%d сут %d ч", days, hours)
	}
	return fmt.Sprintf("%d ч %02d мин", hours, minutes)
}

// updateLine says what the look for a new version found and when: for a report the reasons of a «не удалось проверить» are as useful as
// the version.
func updateLine(u UpdateView) string {
	state := "ещё не проверяли"
	switch {
	case u.Installing != "":
		state = "идёт установка: " + u.Installing
	case u.Error != "":
		state = "не удалось установить: " + u.Error
	case u.Available:
		state = "есть версия " + u.Version
	case u.Checking:
		state = "проверяю"
	case u.Failed:
		state = "последняя проверка не удалась"
	case u.Checked > 0:
		state = "новее нет"
	}
	if u.Checked > 0 {
		state += ", последняя удачная проверка " + time.Unix(u.Checked, 0).Format("2006-01-02 15:04:05")
	}
	return state + "; уведомления о версиях " + map[bool]string{true: "включены", false: "выключены"}[u.Notify]
}

// beforeThisRun are the last n lines of the log of the window before the line that says this run started: what was going on before the
// run that ended unexpectedly.
func beforeThisRun(lines []string, n int) []string {
	start := -1
	for i, l := range lines {
		if strings.Contains(l, "  запуск Nimb ") {
			start = i
		}
	}
	if start <= 0 {
		return []string{"пусто"}
	}
	before := lines[:start]
	if len(before) > n {
		before = before[len(before)-n:]
	}
	return before
}
