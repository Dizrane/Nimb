//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/windows"

	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/runtime"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
	"github.com/Dizrane/Nimb/windows/internal/tgproxy"
	"github.com/Dizrane/Nimb/windows/internal/version"
)

// Version of the Windows app. It is not tied to the number of the Mac app.
var Version = version.Version

// App is what the page can call.
type App struct {
	ctx      context.Context
	settings *settingsStore
	tg       *tgproxy.Engine
	tgPort   uint16

	mu   sync.Mutex // one switch at a time
	busy map[string]bool
	errs map[string]string

	// for a report about a problem
	reportID, reportFacts string
	previousEndedBadly    bool

	probe probeState // the check of the providers

	hintMu sync.Mutex // the line about the DNS of Firefox
	hint   string
	hintAt time.Time
}

// NewApp makes the application object.
func NewApp() *App {
	return &App{settings: loadSettings(), busy: map[string]bool{}, errs: map[string]string{}}
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.previousEndedBadly = beginSession()
	logLine("start " + Version)
	engine, err := tgproxy.New(a.settings.get().TelegramSecret, tgproxy.DefaultConfig())
	if err == nil {
		a.tg = engine
	}
	if a.settings.get().TelegramAuto {
		go a.startTelegram()
	}
	go a.watchTelegram()
	startTray(a)
}

// beforeClose: closing the window hides it (HideWindowOnClose); Nimb goes on working from the tray.
func (a *App) beforeClose(ctx context.Context) bool { return false }

func (a *App) secondInstance(options.SecondInstanceData) { a.ShowWindow() }

// ShowWindow brings the window forward.
func (a *App) ShowWindow() {
	if a.ctx == nil {
		return
	}
	runtime.WindowUnminimise(a.ctx)
	runtime.WindowShow(a.ctx)
}

// Quit closes Nimb. The proxy of Telegram stops with it; DNS and the tunnel stay as they are, as on the Mac.
func (a *App) Quit() {
	endSession()
	if a.tg != nil {
		a.tg.Stop()
	}
	stopTray()
	runtime.Quit(a.ctx)
}

// ---- the state the page draws ----------------------------------------------------------------------------------------

// Provider is a Smart DNS provider as the page lists it.
type Provider struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// State is everything the page shows.
type State struct {
	Version      string `json:"version"`
	ServiceOK    bool   `json:"serviceOk"`
	ServiceError string `json:"serviceError,omitempty"`

	AI struct {
		On       bool     `json:"on"`
		Provider string   `json:"provider"` // the one chosen (and in use when On)
		Busy     bool     `json:"busy"`
		Error    string   `json:"error,omitempty"`
		Warnings []string `json:"warnings"` // what may keep Smart DNS from working, while it is on
	} `json:"ai"`
	Telegram struct {
		On    bool          `json:"on"`
		Busy  bool          `json:"busy"`
		Error string        `json:"error,omitempty"`
		Port  int           `json:"port"`
		Link  string        `json:"link"`
		Stats tgproxy.Stats `json:"stats"`
	} `json:"telegram"`
	Media struct {
		On           bool   `json:"on"`
		Busy         bool   `json:"busy"`
		Error        string `json:"error,omitempty"`
		HandshakeAgo int    `json:"handshakeAgo"`
	} `json:"media"`
	Providers []Provider `json:"providers"`
	Probe     ProbeView  `json:"probe"`
}

func providerList() []Provider {
	var out []Provider
	for _, p := range dnsx.Providers {
		out = append(out, Provider{p.ID, p.Name})
	}
	return out
}

// GetState reads the state of the three services.
func (a *App) GetState() State {
	var st State
	st.Version = Version
	st.Providers = providerList()
	st.Probe = a.probe.view()
	st.AI.Warnings = []string{}
	set := a.settings.get()
	st.AI.Provider = set.Provider

	a.mu.Lock()
	busy, errs := map[string]bool{}, map[string]string{}
	for k, v := range a.busy {
		busy[k] = v
	}
	for k, v := range a.errs {
		errs[k] = v
	}
	a.mu.Unlock()
	st.AI.Busy, st.AI.Error = busy["ai"], errs["ai"]
	st.Telegram.Busy, st.Telegram.Error = busy["telegram"], errs["telegram"]
	st.Media.Busy, st.Media.Error = busy["media"], errs["media"]

	if resp, err := callService(ipc.Request{Cmd: ipc.Status}); err != nil {
		st.ServiceError = err.Error()
	} else {
		st.ServiceOK = true
		if resp.DNS != nil && resp.DNS.Active {
			st.AI.On = true
			st.AI.Provider = resp.DNS.Provider
			if hint := a.browserHint(); hint != "" {
				st.AI.Warnings = append(st.AI.Warnings, hint)
			}
		}
		if resp.Tunnel != nil {
			st.Media.On = resp.Tunnel.Up
			st.Media.HandshakeAgo = resp.Tunnel.HandshakeAgo
		}
	}
	if a.tg != nil && a.tg.IsListening() {
		st.Telegram.On = true
		st.Telegram.Port = int(a.tg.Port())
		st.Telegram.Link = a.telegramLink()
		st.Telegram.Stats = a.tg.Stats()
	}
	return st
}

// Result is the answer to an action of the page.
type Result struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

func (a *App) begin(name string) {
	a.mu.Lock()
	a.busy[name] = true
	delete(a.errs, name)
	a.mu.Unlock()
}

func (a *App) end(name string, err error) Result {
	a.mu.Lock()
	delete(a.busy, name)
	if err != nil {
		a.errs[name] = err.Error()
	}
	a.mu.Unlock()
	if err != nil {
		logLine(name + ": " + err.Error())
		return Result{Error: err.Error()}
	}
	return Result{OK: true}
}

// SetAI turns Smart DNS on or off.
func (a *App) SetAI(on bool) Result {
	a.begin("ai")
	var err error
	if on {
		_, err = callService(ipc.Request{Cmd: ipc.DNSSet, Provider: a.settings.get().Provider})
	} else {
		_, err = callService(ipc.Request{Cmd: ipc.DNSRestore})
	}
	return a.end("ai", err)
}

// SetProvider chooses a provider; if Smart DNS is on it moves to it at once.
func (a *App) SetProvider(id string) Result {
	if _, ok := dnsx.Find(id); !ok {
		return Result{Error: "неизвестный провайдер"}
	}
	a.settings.update(func(s *Settings) { s.Provider = id })
	if resp, err := callService(ipc.Request{Cmd: ipc.Status}); err == nil && resp.DNS != nil && resp.DNS.Active {
		return a.SetAI(true)
	}
	return Result{OK: true}
}

// SetMedia turns the tunnel on or off.
func (a *App) SetMedia(on bool) Result {
	a.begin("media")
	cmd := ipc.TunnelDown
	if on {
		cmd = ipc.TunnelUp
	}
	_, err := callService(ipc.Request{Cmd: cmd})
	return a.end("media", err)
}

// SetTelegram turns the proxy on or off.
func (a *App) SetTelegram(on bool) Result {
	a.begin("telegram")
	if !on {
		if a.tg != nil {
			a.tg.Stop()
		}
		a.settings.update(func(s *Settings) { s.TelegramAuto = false })
		return a.end("telegram", nil)
	}
	return a.end("telegram", a.startTelegram())
}

// SetAll turns the three services on or off together.
func (a *App) SetAll(on bool) Result {
	logLine(fmt.Sprintf("SetAll(%v)", on))
	var wg sync.WaitGroup
	results := make([]Result, 3)
	for i, f := range []func(bool) Result{a.SetAI, a.SetTelegram, a.SetMedia} {
		wg.Add(1)
		go func() { defer wg.Done(); results[i] = f(on) }()
	}
	wg.Wait()
	logLine(fmt.Sprintf("SetAll(%v) done: %+v", on, results))
	for _, r := range results {
		if !r.OK {
			return r
		}
	}
	return Result{OK: true}
}

func (a *App) startTelegram() error {
	if a.tg == nil {
		return fmt.Errorf("прокси не удалось подготовить")
	}
	if a.tg.IsListening() {
		return nil
	}
	preferred := uint16(1443)
	if p := a.settings.get().TelegramPort; p >= 1024 && p <= 65535 {
		preferred = uint16(p)
	}
	port, err := a.tg.Start(preferred)
	if err != nil {
		return fmt.Errorf("не удалось запустить прокси: %w", err)
	}
	a.settings.update(func(s *Settings) { s.TelegramPort = int(port); s.TelegramAuto = true })
	return nil
}

// watchTelegram brings the port back when it stops listening (a sleep, another program took it), up to three tries.
func (a *App) watchTelegram() {
	for range time.Tick(6 * time.Second) {
		if a.tg == nil || !a.settings.get().TelegramAuto || a.tg.IsListening() {
			continue
		}
		wanted := a.tg.Port()
		a.tg.Stop()
		ok := false
		for attempt := 1; attempt <= 3 && !ok; attempt++ {
			time.Sleep(time.Duration(attempt) * time.Second)
			if port, err := a.tg.Start(max(wanted, 1024)); err == nil {
				a.settings.update(func(s *Settings) { s.TelegramPort = int(port) })
				ok = true
			}
		}
		if !ok {
			a.settings.update(func(s *Settings) { s.TelegramAuto = false })
			a.mu.Lock()
			a.errs["telegram"] = "Прокси остановился и не смог запуститься снова: порт, возможно, занят другой программой. Включите его ещё раз."
			a.mu.Unlock()
		}
	}
}

func (a *App) telegramLink() string {
	return fmt.Sprintf("tg://proxy?server=127.0.0.1&port=%d&secret=dd%s", a.tg.Port(), a.settings.get().TelegramSecret)
}

// OpenTelegram opens the "add proxy" window of Telegram Desktop.
func (a *App) OpenTelegram() Result {
	if a.tg == nil || !a.tg.IsListening() {
		return Result{Error: "прокси выключен"}
	}
	cmd := exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", a.telegramLink())
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Start(); err != nil {
		return Result{Error: "Не удалось открыть Telegram. Скопируйте ссылку и отправьте её себе в «Избранное»."}
	}
	return Result{OK: true}
}

// CopyLink puts the link of the proxy on the clipboard.
func (a *App) CopyLink() Result {
	if a.tg == nil || !a.tg.IsListening() {
		return Result{Error: "прокси выключен"}
	}
	if err := runtime.ClipboardSetText(a.ctx, a.telegramLink()); err != nil {
		return Result{Error: "Не удалось скопировать ссылку."}
	}
	return Result{OK: true}
}

// InitialPage is the page to open first: the home page, or the one named by --page=NAME (for trying and for screenshots).
func (a *App) InitialPage() string {
	for _, arg := range os.Args[1:] {
		if name, ok := strings.CutPrefix(arg, "--page="); ok {
			return name
		}
	}
	return "home"
}

// Log writes a line from the page into the log of the window (%AppData%\Nimb\window.log), which a person can send with a report.
// It is short and never gets secrets: the page has none.
func (a *App) Log(line string) {
	if len(line) > 500 {
		line = line[:500]
	}
	logLine(line)
}

// Onboarded says whether the first setup has been gone through.
func (a *App) Onboarded() bool { return a.settings.get().OnboardingDone }

// FinishOnboarding remembers that the first setup is over.
func (a *App) FinishOnboarding() { a.settings.update(func(s *Settings) { s.OnboardingDone = true }) }

// RestartOnboarding makes the first setup show again.
func (a *App) RestartOnboarding() { a.settings.update(func(s *Settings) { s.OnboardingDone = false }) }

// GetAutostart says whether Nimb starts with Windows.
func (a *App) GetAutostart() bool { return autostartOn() }

// SetAutostart makes Nimb start with Windows (quietly, to the tray) or not.
func (a *App) SetAutostart(on bool) Result {
	if err := setAutostart(on); err != nil {
		logLine("autostart: " + err.Error())
		return Result{Error: "Не удалось изменить автозапуск."}
	}
	return Result{OK: true}
}

// Uninstall starts the uninstaller of Nimb (Windows asks for the administrator rights itself). It takes the DNS back and removes the
// service, the account at Cloudflare, the driver and the files.
func (a *App) Uninstall() Result {
	exe, err := os.Executable()
	if err != nil {
		return Result{Error: "Не удалось найти программу удаления."}
	}
	path := filepath.Join(filepath.Dir(exe), "Uninstall.exe")
	if _, err := os.Stat(path); err != nil {
		return Result{Error: "Программы удаления нет рядом с Nimb. Удалите Nimb в «Параметры → Приложения»."}
	}
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, _ := syscall.UTF16PtrFromString(path)
	if err := windows.ShellExecute(0, verb, file, nil, nil, windows.SW_SHOWNORMAL); err != nil {
		logLine("uninstall: " + err.Error())
		return Result{Error: "Не удалось запустить удаление."}
	}
	return Result{OK: true}
}

// OpenTerms opens the terms of Cloudflare WARP in the browser.
func (a *App) OpenTerms() {
	runtime.BrowserOpenURL(a.ctx, "https://www.cloudflare.com/application/terms/")
}

// OpenChannel opens the channel of Nimb in the browser.
func (a *App) OpenChannel() { runtime.BrowserOpenURL(a.ctx, "https://t.me/NimbProject") }
