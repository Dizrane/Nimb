//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/windows"

	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/runtime"

	"github.com/Dizrane/Nimb/windows/internal/autoreport"
	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
	"github.com/Dizrane/Nimb/windows/internal/netfacts"
	"github.com/Dizrane/Nimb/windows/internal/tgproxy"
	"github.com/Dizrane/Nimb/windows/internal/tunneldrop"
	"github.com/Dizrane/Nimb/windows/internal/tunnelrestart"
	"github.com/Dizrane/Nimb/windows/internal/version"
)

// Version of the Windows app. It is not tied to the number of the Mac app.
var Version = version.Version

// App is what the page can call.
type App struct {
	ctx      context.Context
	settings *settingsStore
	tgPort   uint16

	mu   sync.Mutex // one switch at a time
	busy map[string]bool
	// tunnelEpoch grows each time the tunnel starts or stops being switched (under mu): a check of the providers that saw it change is not
	// to be believed.
	tunnelEpoch int
	errs        map[string]string

	// for a report about a problem
	reportID, reportFacts string
	previousEndedBadly    bool

	// restoring: the tunnel that was on before the computer was restarted is being switched on again (restoreTunnel).
	restoring atomic.Bool

	serviceMu   sync.Mutex
	serviceDown bool // the service did not answer the last time it was asked (see noteService)

	wrongKeyMu sync.Mutex
	wrongKey   tgproxy.RecentCount // the connections of Telegram that came with another key
	failures   tgproxy.RecentCount // the connections that did not get to Telegram

	reach dnsReach    // whether the provider answers in this network (dnswarn_windows.go)
	probe probeState  // the check of the providers
	upd   updateState // the look for a new version
	sites siteState   // the check of YouTube and Discord

	auto autoState // «Помогать тестированию» (autoreport_windows.go)

	hintMu sync.Mutex // the line about the DNS of Firefox
	hint   string
	hintAt time.Time
}

// NewApp makes the application object.
func NewApp() *App {
	return &App{settings: loadSettings(), busy: map[string]bool{}, errs: map[string]string{}}
}

func (a *App) startup(ctx context.Context) {
	setupDiagnostics() // the program is the one instance now: its log and its crash output are its own
	a.ctx = ctx
	a.sizeWindow()
	var upgradedFrom string
	a.previousEndedBadly, upgradedFrom = beginSession(Version, previousLastLine)
	a.watchSessionEnd()
	balloonClick = a.balloonClicked
	hideTitleBarIcon()
	startPulse()
	logLine(fmt.Sprintf("запуск Nimb %s (процесс %d)", Version, os.Getpid()))
	if afterWebView2Crash {
		logLine("Nimb запущен заново: прошлый процесс закончился, потому что завершился браузерный процесс WebView2 (строка «wails: … kind 0» выше)")
	}
	if a.previousEndedBadly {
		logLine("прошлый запуск закончился неожиданно (сбой, принудительное закрытие или выключение питания)")
		explainPreviousEnd()
	} else if upgradedFrom != "" {
		from := ""
		if upgradedFrom != "прежней" { // «прежней»: an old kind of mark that has no version in it (see session.Interpret)
			from = " с версии " + upgradedFrom
		}
		logLine("Nimb обновлён" + from + ": установщик закрыл прошлый запуск, это не сбой")
	}
	goSafe("перенос прокси Telegram в службу", a.migrateTelegram)
	goKeep("проверка обновлений", a.updateLoop)
	goKeep("чёрный ящик", a.blackBoxLoop)
	if a.previousEndedBadly {
		// Told a little after the start, when the network is there.
		goSafe("отчёт о неожиданном завершении", func() { time.Sleep(60 * time.Second); a.notifyAuto(autoreport.PreviousEndedBadly) })
	}
	goSafe("возврат туннеля после перезагрузки", a.restoreTunnel)
	startTray(a)
}

// beforeClose: with the working in the background on, closing the window hides it (HideWindowOnClose) and Nimb goes on working from the
// tray; with it off, closing the window quits Nimb as «Выйти» of the menu of the icon does (it asks when an update is being installed;
// if the person says no, the window stays). The question is asked off the thread of the window, which is told at once that the close is taken.
func (a *App) beforeClose(ctx context.Context) bool {
	if a.settings.get().ClosingQuits() {
		go a.quitFrom("закрытие окна при выключенной работе в фоне")
		return true
	}
	return false
}

// FrameLog says whether the page should tour itself and count its frames (NIMB_FRAMELOG=1, for trying the smoothness on a real machine).
func (a *App) FrameLog() bool { return os.Getenv("NIMB_FRAMELOG") == "1" }

// SetBackground turns the working in the background on or off.
func (a *App) SetBackground(on bool) Result {
	a.settings.update(func(s *Settings) { s.Enable(on) })
	if on {
		logLine("работа в фоне: включена (закрытие окна оставляет Nimb у часов)")
	} else {
		logLine("работа в фоне: выключена (закрытие окна завершает Nimb)")
	}
	return Result{OK: true}
}

func (a *App) secondInstance(options.SecondInstanceData) { a.ShowWindow() }

// ShowWindow brings the window forward.
func (a *App) ShowWindow() {
	if a.ctx == nil {
		return
	}
	runtime.WindowUnminimise(a.ctx)
	runtime.WindowShow(a.ctx)
}

// Quit closes Nimb. The proxy of Telegram, DNS and the tunnel stay as they are: they live in the service.
func (a *App) Quit() { a.quitFrom("кнопка «Выйти из Nimb» в окне") }

// quitFrom closes Nimb and writes down who asked for it.
func (a *App) quitFrom(reason string) bool {
	// The update is being installed: a quit now would stop it half-way (the same question as on the Mac).
	a.upd.mu.Lock()
	installing := a.upd.installing != "" && !a.upd.restarting
	a.upd.mu.Unlock()
	if installing {
		title, _ := syscall.UTF16PtrFromString("Идёт обновление")
		text, _ := syscall.UTF16PtrFromString("Если выйти сейчас, оно прервётся и начнётся заново при следующей попытке. Обычно оно занимает около минуты.\n\nВыйти всё равно?")
		const yesNo, warning, defaultNo, topmost = 0x4, 0x30, 0x100, 0x40000
		if answer, _ := windows.MessageBox(0, text, title, yesNo|warning|defaultNo|topmost); answer != 6 { // IDYES
			logLine("выход: пока идёт обновление человек решил подождать")
			return false
		}
	}
	logExit("по команде человека: " + reason)
	endSession()
	stopTray()
	runtime.Quit(a.ctx)
	return true
}

// ---- the state the page draws ----------------------------------------------------------------------------------------

// Provider is a Smart DNS provider as the page lists it.
type Provider struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// State is everything the page shows.
type State struct {
	Version string `json:"version"`
	// Modified: this build is not an official one (no key of a release, or a file next to the program is not the one the build made); its
	// reports are paused, and the bar at the bottom says «MOD». Why is in the report.
	Modified     bool   `json:"modified"`
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
		// WrongKeyRecently: Telegram came with another key a moment ago (a proxy of an older install is still saved in it). True only while
		// that goes on: ten seconds without such a connection and it is false again.
		WrongKeyRecently bool `json:"wrongKeyRecently"`
		// TunnelAdvice is the words that advise the tunnel when nothing or almost nothing reaches Telegram and the tunnel is off (empty
		// otherwise); see tgproxy.AdviceFor.
		TunnelAdvice string `json:"tunnelAdvice,omitempty"`
	} `json:"telegram"`
	Media struct {
		On           bool    `json:"on"`
		Busy         bool    `json:"busy"`
		Error        string  `json:"error,omitempty"`
		HandshakeAgo int     `json:"handshakeAgo"`
		DroppedAt    int64   `json:"droppedAt,omitempty"`
		DropReason   string  `json:"dropReason,omitempty"`
		Restarts     []int64 `json:"restarts,omitempty"` // when the program of the tunnel was started again (unix), the last day
		Restarting   bool    `json:"restarting,omitempty"`
	} `json:"media"`
	Providers []Provider `json:"providers"`
	Probe     ProbeView  `json:"probe"`
	Update    UpdateView `json:"update"`
	Sites     SiteView   `json:"sites"`
	Help      HelpView   `json:"help"`
	// Background: closing the window keeps Nimb at the clock (on) or quits it (off).
	Background bool `json:"background"`
}

func providerList() []Provider {
	var out []Provider
	for _, p := range dnsx.ByName() {
		out = append(out, Provider{p.ID, p.Name})
	}
	return out
}

// GetState reads the state of the three services.
func (a *App) GetState() State {
	var st State
	st.Version = Version
	st.Modified = buildProblem() != ""
	st.Providers = providerList()
	st.Probe = a.probe.view()
	st.Update = a.upd.view()
	st.Sites = a.sites.view()
	st.Help = a.helpView()
	st.Background = a.settings.get().Enabled()
	st.Update.Notify = !a.settings.get().UpdateNotifyOff
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

	var tg *ipc.TelegramStatus
	if resp, err := callService(ipc.Request{Cmd: ipc.Status}); err != nil {
		st.ServiceError = err.Error()
		a.noteService(false, err.Error())
	} else {
		st.ServiceOK = true
		a.noteService(true, "")
		tg = resp.Telegram
		if resp.DNS != nil && resp.DNS.Active {
			st.AI.On = true
			st.AI.Provider = resp.DNS.Provider
			if hint := a.browserHint(); hint != "" {
				st.AI.Warnings = append(st.AI.Warnings, hint)
			}
			if p, ok := dnsx.Find(resp.DNS.Provider); ok {
				if unreachable := a.unreachableWarning(p); unreachable != "" {
					st.AI.Warnings = append([]string{unreachable}, st.AI.Warnings...)
				}
			}
		}
		if resp.Tunnel != nil {
			st.Media.On = resp.Tunnel.Up
			st.Media.HandshakeAgo = resp.Tunnel.HandshakeAgo
			st.Media.DroppedAt, st.Media.DropReason = resp.Tunnel.DroppedAt, resp.Tunnel.DropReason
			st.Media.Restarts = resp.Tunnel.Restarts
			st.Media.Restarting = resp.Tunnel.Restarting
			a.noticeRestarts(resp.Tunnel)
			// What the person has on is what comes back after a restart of the computer (the restore itself is in restoreTunnel).
			if resp.Tunnel.Up && !a.restoring.Load() && !a.settings.get().TunnelWanted {
				a.settings.update(func(s *Settings) { s.TunnelWanted = true })
			}
			if a.noticeDrop(resp.Tunnel) {
				st.Media.Error = tunneldrop.MessageFor(resp.Tunnel.DropReason)
			}
		}
	}
	if tg != nil && tg.On {
		st.Telegram.On = true
		st.Telegram.Port = tg.Port
		st.Telegram.Link = telegramLink(tg)
		st.Telegram.Stats = tg.Stats
		st.Telegram.WrongKeyRecently = a.watchWrongKey(tg.Stats.WrongSecret)
		failing := a.watchFailures(tg.Stats.Failures)
		st.Telegram.TunnelAdvice = tgproxy.AdviceFor(tg.Stats.Failures, tg.Stats.WebSocket+tg.Stats.DirectTCP, failing, !st.Media.On && !st.Media.Busy).Words()
	} else {
		a.watchWrongKey(0, true)
		a.watchFailures(0, true)
		if tg != nil && tg.Error != "" && st.Telegram.Error == "" {
			st.Telegram.Error = tg.Error
		}
	}
	return st
}

// watchWrongKey takes the count of the connections with another key and says whether it grew a moment ago; reset forgets it (the
// proxy is stopped).
func (a *App) watchWrongKey(count int, reset ...bool) bool {
	a.wrongKeyMu.Lock()
	defer a.wrongKeyMu.Unlock()
	a.wrongKey.Quiet = 10 * time.Second
	if len(reset) > 0 && reset[0] {
		a.wrongKey.Reset()
		return false
	}
	return a.wrongKey.Observe(count, time.Now())
}

// watchFailures is watchWrongKey for the connections that did not get to Telegram (ten minutes without a new one and it is past).
func (a *App) watchFailures(count int, reset ...bool) bool {
	a.wrongKeyMu.Lock()
	defer a.wrongKeyMu.Unlock()
	a.failures.Quiet = tgproxy.AdviceQuiet
	if len(reset) > 0 && reset[0] {
		a.failures.Reset()
		return false
	}
	return a.failures.Observe(count, time.Now())
}

// noteService writes to the log, once each, the moment the service stops answering (with the words of the error as they came) and the moment
// it answers again: what the window did in between is read against these two lines.
func (a *App) noteService(ok bool, reason string) {
	a.serviceMu.Lock()
	defer a.serviceMu.Unlock()
	switch {
	case !ok && !a.serviceDown:
		a.serviceDown = true
		logLine("служба не отвечает: " + reason)
	case ok && a.serviceDown:
		a.serviceDown = false
		logLine("служба снова отвечает")
	}
}

// noticeRestarts: the program of the tunnel ended by itself and the service started it again. Only the log hears of it: the switch
// stays on and the tunnel works; the restarts go to the log and to the report, so that a problem behind them can be seen.
func (a *App) noticeRestarts(t *ipc.TunnelStatus) {
	fresh := tunnelrestart.Unseen(unixTimes(t.Restarts), a.settings.get().TunnelRestartsSeen)
	if len(fresh) == 0 {
		return
	}
	a.settings.update(func(s *Settings) { s.TunnelRestartsSeen = fresh[len(fresh)-1].Unix() })
	logLine(fmt.Sprintf("туннель: программа туннеля остановилась сама, помощник запустил её снова (раз: %d)", len(fresh)))
	a.notifyAuto(autoreport.TunnelRestarted)
}

func unixTimes(secs []int64) []time.Time {
	out := make([]time.Time, len(secs))
	for i, s := range secs {
		out[i] = time.Unix(s, 0)
	}
	return out
}

// restoreTunnel: after the computer was restarted the tunnel that was on is switched on again, as soon as there is a network. It runs at
// every start of the program, with the window hidden (the autostart) too.
func (a *App) restoreTunnel() {
	var ts *ipc.TunnelStatus
	for i := 0; i < 30 && ts == nil; i++ { // the service may still be starting
		time.Sleep(time.Second)
		if resp, err := callService(ipc.Request{Cmd: ipc.Status}); err == nil {
			ts = resp.Tunnel
		}
	}
	if ts == nil || !tunnelrestart.ShouldRestore(a.settings.get().TunnelWanted, ts.HasAccount, !ts.Up) || !a.restoring.CompareAndSwap(false, true) {
		return
	}
	defer a.restoring.Store(false)
	logLine("туннель: туннель был включён до выключения компьютера: включаю снова")
	for attempt := 0; attempt < tunnelrestart.Attempts; attempt++ {
		if !waitForNetwork(tunnelrestart.NetworkWait) {
			logLine("туннель: сети нет: туннель не включён")
			return
		}
		// The person may have decided in the meantime (switched it on or off, removed Nimb).
		resp, err := callService(ipc.Request{Cmd: ipc.Status})
		if !a.settings.get().TunnelWanted || (err == nil && resp.Tunnel != nil && resp.Tunnel.Up) {
			return
		}
		a.begin("media")
		_, err = callService(ipc.Request{Cmd: ipc.TunnelUp})
		if a.end("media", err).OK {
			return
		}
		if !tunnelrestart.TriesAgain(true, attempt) {
			break
		}
		a.mu.Lock()
		delete(a.errs, "media")
		a.mu.Unlock()
		time.Sleep(tunnelrestart.Pause)
	}
	logLine("туннель: туннель не включился сам: включите вручную")
}

// waitForNetwork waits until the computer has a network with a way out, at most timeout.
func waitForNetwork(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		if netfacts.HasUplink() {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(2 * time.Second)
	}
}

// noticeDrop: the tunnel stopped by itself (its program ended). The person is told once, on the page and in the
// log (the message stays on the page until the next action, as on the Mac).
func (a *App) noticeDrop(t *ipc.TunnelStatus) bool {
	if t.Up || t.DroppedAt == 0 || !tunneldrop.IsNews(time.Unix(t.DroppedAt, 0), a.settings.get().TunnelDropSeen, time.Now()) {
		return false
	}
	a.settings.update(func(s *Settings) { s.TunnelDropSeen = t.DroppedAt })
	logLine("туннель остановился сам: " + t.DropReason)
	a.mu.Lock()
	a.errs["media"] = tunneldrop.MessageFor(t.DropReason)
	a.mu.Unlock()
	a.notifyAuto(autoreport.TunnelDropped)
	return true
}

// Result is the answer to an action of the page.
type Result struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

func (a *App) begin(name string) {
	a.mu.Lock()
	a.noteSwitch(name)
	a.busy[name] = true
	delete(a.errs, name)
	a.mu.Unlock()
}

// noteSwitch is called (with mu held) when a service starts or stops being switched.
func (a *App) noteSwitch(name string) {
	if name == "media" {
		a.tunnelEpoch++
	}
}

// tunnelState says whether the tunnel is being switched now and a number that changes whenever that starts or ends.
func (a *App) tunnelState() (switching bool, epoch int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.busy["media"], a.tunnelEpoch
}

// enter is begin that refuses when the service is still being switched: a click that comes while the same service is busy is ignored (a
// switch pressed many times in a second rewrote the DNS of every connection each time).
func (a *App) enter(name string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.busy[name] {
		return false
	}
	a.noteSwitch(name)
	a.busy[name] = true
	delete(a.errs, name)
	return true
}

// ignored is the answer to a switch pressed while the service is still being switched.
func (a *App) ignored(name string) Result {
	logLine(serviceName(name) + ": переключатель нажат, пока прошлое переключение не закончилось, нажатие пропущено")
	return Result{OK: true}
}

func (a *App) end(name string, err error) Result {
	a.mu.Lock()
	a.noteSwitch(name)
	delete(a.busy, name)
	if err != nil {
		a.errs[name] = err.Error()
	}
	a.mu.Unlock()
	if err != nil {
		logLine(serviceName(name) + ": ОШИБКА: " + err.Error())
		a.autoError(name, err)
		return Result{Error: err.Error()}
	}
	return Result{OK: true}
}

// serviceName is what a service is called in the log.
func serviceName(key string) string {
	switch key {
	case "ai":
		return "нейросети"
	case "telegram":
		return "Telegram"
	case "media":
		return "туннель (YouTube и Discord)"
	}
	return key
}

// SetAI turns Smart DNS on or off.
func (a *App) SetAI(on bool) Result {
	if !a.enter("ai") {
		return a.ignored("ai")
	}
	return a.applyAI(on)
}

// applyAI does the work of SetAI; the service is already marked as busy.
func (a *App) applyAI(on bool) Result {
	var err error
	if on {
		logLine("нейросети: включаю, провайдер " + providerName(a.settings.get().Provider))
	} else {
		logLine("нейросети: выключаю")
	}
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
	logLine("нейросети: выбран провайдер " + providerName(id))
	if resp, err := callService(ipc.Request{Cmd: ipc.Status}); err == nil && resp.DNS != nil && resp.DNS.Active {
		return a.SetAI(true)
	}
	return Result{OK: true}
}

// SetMedia turns the tunnel on or off.
func (a *App) SetMedia(on bool) Result {
	if !a.enter("media") {
		return a.ignored("media")
	}
	return a.applyMedia(on)
}

// applyMedia does the work of SetMedia; the service is already marked as busy.
func (a *App) applyMedia(on bool) Result {
	if on {
		logLine("туннель: включаю")
	} else {
		logLine("туннель: выключаю")
	}
	cmd := ipc.TunnelDown
	if on {
		cmd = ipc.TunnelUp
	}
	_, err := callService(ipc.Request{Cmd: cmd})
	// What the person did last is what comes back after a restart of the computer.
	a.settings.update(func(s *Settings) { s.TunnelWanted = on && err == nil })
	if err != nil && strings.Contains(err.Error(), "сервер не ответил") {
		// A network of a university, an office or a hotel may close the tunnel; the words of the Mac for it.
		err = errors.New(err.Error() + ". Проверьте интернет и попробуйте ещё раз. В некоторых сетях (вуз, работа, отель) туннель закрыт: тогда поможет другая сеть или мобильный интернет.")
	}
	return a.end("media", err)
}

// SetTelegram turns the proxy on or off.
func (a *App) SetTelegram(on bool) Result {
	if !a.enter("telegram") {
		return a.ignored("telegram")
	}
	return a.applyTelegram(on)
}

// applyTelegram does the work of SetTelegram; the service is already marked as busy.
func (a *App) applyTelegram(on bool) Result {
	if on {
		logLine("Telegram: включаю прокси")
	} else {
		logLine("Telegram: останавливаю прокси")
	}
	cmd := ipc.Request{Cmd: ipc.TelegramDown}
	if on {
		// The key and the port that this window had are offered to the service: the Telegram of the person may know them from before.
		set := a.settings.get()
		cmd = ipc.Request{Cmd: ipc.TelegramUp, Secret: set.TelegramSecret, Port: set.TelegramPort}
	}
	_, err := callService(cmd)
	return a.end("telegram", err)
}

// SetAll turns the three services on or off together.
func (a *App) SetAll(on bool) Result {
	if on {
		logLine("включаю всё")
	} else {
		logLine("выключаю всё")
	}
	var wg sync.WaitGroup
	results := make([]Result, 3)
	// All three are marked as working before any of them starts, so that the page never sees one of them neither working nor done. One
	// that is still being switched by an earlier press is left to finish.
	for i, step := range []struct {
		name  string
		apply func(bool) Result
	}{{"ai", a.applyAI}, {"telegram", a.applyTelegram}, {"media", a.applyMedia}} {
		if !a.enter(step.name) {
			results[i] = a.ignored(step.name)
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			safely("включение службы из «Включить всё»", func() { results[i] = step.apply(on) })
		}()
	}
	wg.Wait()
	// The result of each of the three, with the words of the error as they came (what the old line with the three structures said).
	var parts []string
	for i, name := range []string{"нейросети", "Telegram", "туннель"} {
		if results[i].OK {
			parts = append(parts, name+": готово")
		} else {
			parts = append(parts, name+": ОШИБКА ("+results[i].Error+")")
		}
	}
	if on {
		logLine("включить всё, итог: " + strings.Join(parts, "; "))
	} else {
		logLine("выключить всё, итог: " + strings.Join(parts, "; "))
	}
	for _, r := range results {
		if !r.OK {
			return r
		}
	}
	return Result{OK: true}
}

// telegramFromService asks the service for the state of the proxy (nil when it does not answer).
func (a *App) telegramFromService() *ipc.TelegramStatus {
	resp, err := callService(ipc.Request{Cmd: ipc.Status})
	if err != nil {
		return nil
	}
	return resp.Telegram
}

func telegramLink(tg *ipc.TelegramStatus) string {
	return fmt.Sprintf("tg://proxy?server=127.0.0.1&port=%d&secret=dd%s", tg.Port, tg.Secret)
}

// migrateTelegram: in 0.2.0 and before the proxy lived in this window, and «on» was remembered here. If it was on, the service is asked to
// switch it on, with the key and the port that Telegram already has, and the window forgets it: from now on the service keeps it.
func (a *App) migrateTelegram() {
	if !a.settings.get().TelegramAuto {
		return
	}
	for i := 0; i < 30; i++ {
		set := a.settings.get()
		if _, err := callService(ipc.Request{Cmd: ipc.TelegramUp, Secret: set.TelegramSecret, Port: set.TelegramPort}); err == nil {
			a.settings.update(func(s *Settings) { s.TelegramAuto = false })
			logLine("Telegram: прокси, который был включён в окне, теперь работает в службе (ключ и порт те же)")
			return
		}
		time.Sleep(2 * time.Second)
	}
	logLine("Telegram: не удалось передать включённый прокси службе, он останется выключенным, пока его не включат")
}

// OpenTelegram opens the "add proxy" window of Telegram Desktop.
func (a *App) OpenTelegram() Result {
	tg := a.telegramFromService()
	if tg == nil || !tg.On {
		return Result{Error: "прокси выключен"}
	}
	logLine("Telegram: открываю окно «Добавить прокси»")
	cmd := exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", telegramLink(tg))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Start(); err != nil {
		return Result{Error: "Не удалось открыть Telegram. Скопируйте ссылку и отправьте её себе в «Избранное»."}
	}
	return Result{OK: true}
}

// CopyLink puts the link of the proxy on the clipboard.
func (a *App) CopyLink() Result {
	tg := a.telegramFromService()
	if tg == nil || !tg.On {
		return Result{Error: "прокси выключен"}
	}
	if err := runtime.ClipboardSetText(a.ctx, telegramLink(tg)); err != nil {
		return Result{Error: "Не удалось скопировать ссылку."}
	}
	logLine("Telegram: ссылка скопирована")
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
		logLine("автозапуск: не удалось изменить: " + err.Error())
		return Result{Error: "Не удалось изменить автозапуск."}
	}
	if on {
		logLine("автозапуск с Windows: включён")
	} else {
		logLine("автозапуск с Windows: выключен")
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
	a.settings.update(func(s *Settings) { s.TunnelWanted = false })
	if err := windows.ShellExecute(0, verb, file, nil, nil, windows.SW_SHOWNORMAL); err != nil {
		logLine("удаление: не удалось запустить: " + err.Error())
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
