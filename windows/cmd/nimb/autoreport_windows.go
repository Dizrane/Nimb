//go:build windows

package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/Dizrane/Nimb/windows/internal/autoreport"
	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/netfacts"
	"github.com/Dizrane/Nimb/windows/internal/report"
)

// «Помогать тестированию» (the port of Sources/Nimb/Report/AutoReporter.swift and BlackBox.swift): the black box writes a line every five
// minutes, and when something goes wrong that Nimb can do something about, the program sends the same report that «Сообщить о проблеме»
// makes, by itself, to the developer. Off until the person turns it on. The rules are in internal/autoreport; this file brings the facts
// of Windows and does the sending. It lives in the window, so it works while the window runs (in the tray too); with the window closed
// by «Выйти из Nimb» nothing is written and nothing is sent.

// autoState is what the automatic reports keep between looks.
type autoState struct {
	mu       sync.Mutex // one decision at a time: the history is read, extended and written
	tracker  autoreport.MismatchTracker
	retrying bool
	boxMu    sync.Mutex // the file of the black box
	failed   int        // checks for updates that failed in a row (a limit of GitHub is not one)
}

func blackBoxPath() string { return filepath.Join(dataDir(), "blackbox.log") }
func pendingPath() string  { return filepath.Join(dataDir(), "pending-reports.json") }

// ---- the black box ------------------------------------------------------------------------------------------------------------------

// blackBoxTail is the last n lines of the black box, oldest first.
func blackBoxTail(n int) []string {
	return tailLog(blackBoxPath(), n)
}

// blackBoxLoop writes the first line a little after the start (the services are being switched on then) and the next ones every five minutes.
func (a *App) blackBoxLoop() {
	time.Sleep(30 * time.Second)
	ticker := time.NewTicker(autoreport.BoxInterval)
	defer ticker.Stop()
	for {
		safely("чёрный ящик", a.recordBlackBox)
		<-ticker.C
	}
}

// look is what one look of the black box found, as it is fed to the rules of the causes.
type look struct {
	dnsAgrees, telegramAgrees, tunnelAgrees, silent bool
}

func (a *App) recordBlackBox() {
	st := a.GetState()
	if !st.ServiceOK {
		// The service does not answer: nothing can be compared. The line says so, and nothing is counted (the log of the window has the moment).
		a.writeBlackBox(autoreport.Line(time.Now(), time.Since(processStarted), autoreport.Facts{
			DNS: "служба не отвечает", DNSAgrees: true, Telegram: "служба не отвечает", TelegramAgrees: true, Tunnel: "служба не отвечает", TunnelAgrees: true,
			Interface: "?", MemoryMegabytes: processMemoryMB()}))
		return
	}
	adapters, _ := dnsx.Adapters()
	var active *dnsx.Provider
	if p, ok := dnsx.Find(st.AI.Provider); ok && st.AI.On {
		active = &p
	}
	// The service says the proxy is on only while its engine listens; the port is asked of the system as well, which is the independent word.
	// A proxy that is off has no port to ask about (another program may hold any port, and that is not ours).
	listening := st.Telegram.On && portListening(st.Telegram.Port)
	routes, via, viaTunnel := netfacts.Routes("Nimb")
	working := st.Media.Busy || st.Media.Restarting || a.restoring.Load()

	f := autoreport.Facts{
		DNS: "выкл", DNSAgrees: autoreport.DNSAgrees(active, adapters),
		Telegram: "выкл", TelegramAgrees: autoreport.TelegramAgrees(st.Telegram.On, listening),
		Tunnel: "выкл", TunnelAgrees: autoreport.TunnelAgrees(st.Media.On, routes, viaTunnel, working),
		Routes: routes, Interface: via, MemoryMegabytes: processMemoryMB(),
	}
	if f.Interface == "" {
		f.Interface = "?"
	}
	if active != nil {
		f.DNS = active.Name
	}
	if st.Telegram.On {
		f.Telegram = "вкл:" + strconv.Itoa(st.Telegram.Port) + " соединений=" + strconv.Itoa(st.Telegram.Stats.Total) + " ошибок=" + strconv.Itoa(st.Telegram.Stats.Failures)
	}
	switch {
	case working:
		f.Tunnel = "в работе"
	case st.Media.On:
		f.Tunnel = "вкл:Nimb"
	}
	var ago *int
	if st.Media.On && st.Media.HandshakeAgo >= 0 {
		n := st.Media.HandshakeAgo
		ago = &n
		f.HandshakeAgo = ago
	}
	a.writeBlackBox(autoreport.Line(time.Now(), time.Since(processStarted), f))

	if !a.settings.get().HelpTesting {
		return
	}
	// What the rules are fed with. The questions to the net are asked only when the answer is needed (a disagreement or a silent server).
	l := look{dnsAgrees: true, telegramAgrees: f.TelegramAgrees, tunnelAgrees: f.TunnelAgrees}
	if !f.DNSAgrees {
		l.dnsAgrees = autoreport.DNSCounts(false, cloudflareTrace() != nil, autoreport.DNSTakenByOthers(active, adapters))
	}
	if ago != nil && *ago > autoreport.StaleAfter {
		trace := cloudflareTrace()
		l.silent = autoreport.TunnelSilent(ago, trace != nil && trace["warp"] == "on")
	}
	a.observeAuto(l)
}

func (a *App) writeBlackBox(line string) {
	a.auto.boxMu.Lock()
	defer a.auto.boxMu.Unlock()
	var kept []string
	if raw, err := os.ReadFile(blackBoxPath()); err == nil {
		for _, l := range strings.Split(string(raw), "\n") {
			if strings.TrimSpace(l) != "" {
				kept = append(kept, strings.TrimRight(l, "\r"))
			}
		}
	}
	kept = autoreport.Trimmed(append(kept, line))
	os.MkdirAll(filepath.Dir(blackBoxPath()), 0o700)
	tmp := blackBoxPath() + ".tmp"
	if os.WriteFile(tmp, []byte(strings.Join(kept, "\n")+"\n"), 0o600) == nil {
		os.Rename(tmp, blackBoxPath())
	}
}

// portListening says whether something listens on the port of the proxy of Telegram. The port is asked for, not called: a call would be a
// connection that the proxy counts. Whoever holds the address of the port makes the question fail.
func portListening(port int) bool {
	if port <= 0 {
		return false
	}
	l, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return true
	}
	l.Close()
	return false
}

var (
	psapi                 = windows.NewLazySystemDLL("psapi.dll")
	pGetProcessMemoryInfo = psapi.NewProc("GetProcessMemoryInfo")
)

// processMemoryMB is the memory that the process of the window holds now (the working set), in megabytes.
func processMemoryMB() int {
	var counters struct {
		cb                         uint32
		PageFaultCount             uint32
		PeakWorkingSetSize         uintptr
		WorkingSetSize             uintptr
		QuotaPeakPagedPoolUsage    uintptr
		QuotaPagedPoolUsage        uintptr
		QuotaPeakNonPagedPoolUsage uintptr
		QuotaNonPagedPoolUsage     uintptr
		PagefileUsage              uintptr
		PeakPagefileUsage          uintptr
	}
	counters.cb = uint32(unsafe.Sizeof(counters))
	if r, _, _ := pGetProcessMemoryInfo.Call(uintptr(windows.CurrentProcess()), uintptr(unsafe.Pointer(&counters)), uintptr(counters.cb)); r == 0 {
		return 0
	}
	return int(counters.WorkingSetSize >> 20)
}

// ---- the causes ---------------------------------------------------------------------------------------------------------------------

// observeAuto is one look of the black box: a service that disagrees with what it should be, for long enough, is a cause.
func (a *App) observeAuto(l look) {
	t := &a.auto
	t.mu.Lock()
	dns, tg, tun, silent := t.tracker.Observe("dns", l.dnsAgrees), t.tracker.Observe("telegram", l.telegramAgrees), t.tracker.Observe("tunnel", l.tunnelAgrees), t.tracker.Observe("handshake", !l.silent)
	t.mu.Unlock()
	if dns {
		a.notifyAuto(autoreport.Mismatch(autoreport.DNS))
	}
	if tg {
		a.notifyAuto(autoreport.Mismatch(autoreport.Telegram))
	}
	if tun {
		a.notifyAuto(autoreport.Mismatch(autoreport.Tunnel))
	}
	if silent {
		a.notifyAuto(autoreport.TunnelSilentCause)
	}
	a.sendDigestIfDue()
	a.retryPending()
}

// autoError: an error that the person is shown when a service is switched on or off. What the network does to the tunnel (the server does
// not answer) is not a fault of Nimb (autoreport.TunnelErrorIsOurs).
func (a *App) autoError(service string, err error) {
	switch service {
	case "ai":
		a.notifyAuto(autoreport.Error(autoreport.DNS))
	case "telegram":
		a.notifyAuto(autoreport.Error(autoreport.Telegram))
	case "media":
		if autoreport.TunnelErrorIsOurs(err.Error()) {
			a.notifyAuto(autoreport.Error(autoreport.Tunnel))
		}
	}
}

// resetFailedChecks: a check for updates that worked ends the row of failed ones.
func (a *App) resetFailedChecks() {
	a.auto.mu.Lock()
	a.auto.failed = 0
	a.auto.mu.Unlock()
}

// notifyAuto sends a report for a cause, if the switch is on and the limits allow it.
func (a *App) notifyAuto(trigger autoreport.Trigger) {
	set := a.settings.get()
	if !set.HelpTesting {
		return
	}
	now := time.Now()
	a.auto.mu.Lock()
	history := autoreport.Pruned(set.HelpHistory, now)
	if !autoreport.Allows(trigger.Key, now, history, trigger.IgnoresHourLimit) {
		a.auto.mu.Unlock()
		return
	}
	// Written down before the sending: a second cause in the same moment does not make a second report, and a failed sending is not repeated.
	history = append(history, autoreport.Sent{Key: trigger.Key, At: now})
	a.settings.update(func(s *Settings) { s.HelpHistory = history })
	a.auto.mu.Unlock()
	goSafe("авто-отчёт: "+trigger.Key, func() { a.deliverAuto(trigger, "") })
}

// sendDigestIfDue: the report of the day goes when a day has passed since the last one (or since the switch was turned on). A computer that
// was asleep sends it at the first look after waking.
func (a *App) sendDigestIfDue() {
	now := time.Now()
	stamp := a.settings.get().HelpDigest
	if stamp <= 0 { // turned on by an older version: the day starts now
		a.settings.update(func(s *Settings) { s.HelpDigest = now.Unix() })
		return
	}
	since := time.Unix(stamp, 0)
	if !autoreport.DigestDue(now, since) {
		return
	}
	a.settings.update(func(s *Settings) { s.HelpDigest = now.Unix() })
	var sent []string
	for _, h := range autoreport.Pruned(a.settings.get().HelpHistory, now) {
		sent = append(sent, h.Key)
	}
	summary := autoreport.Summary(autoreport.LinesSince(blackBoxTail(autoreport.KeepLines), since), sent)
	goSafe("авто-отчёт: сводка", func() { a.deliverAuto(autoreport.DailyDigestCause, summary) })
}

// deliverAuto collects the report and sends it; a report that cannot go is kept for the next looks (the net may be down just because of
// the fault that is being told).
func (a *App) deliverAuto(trigger autoreport.Trigger, summary string) {
	install := a.settings.get().HelpInstall
	if install == "" {
		install = newInstallID()
	}
	id := report.NewID()
	text := report.Head(id, "авто: "+trigger.Title+" (установка "+install+")", "", reportEnv()) + "\n\n"
	if summary != "" {
		text += summary + "\n\n"
	}
	text += a.collectReportFacts()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := report.SendAuto(ctx, Version, id, text, trigger.Key, install); err != nil {
		item := autoreport.PendingItem{ID: id, Trigger: trigger.Key, Install: install, Text: text, At: time.Now()}
		savePending(append(readPending(), item))
		logLine("тестирование: отчёт " + id + " не отправлен, будет ещё попытка: " + err.Error())
		return
	}
	a.recordSent()
	logLine("тестирование: отчёт " + id + " отправлен: " + trigger.Title)
}

func (a *App) recordSent() {
	a.settings.update(func(s *Settings) { s.HelpCount++; s.HelpLast = time.Now().Unix() })
}

// ---- reports that did not go --------------------------------------------------------------------------------------------------------

func readPending() []autoreport.PendingItem {
	raw, err := os.ReadFile(pendingPath())
	if err != nil {
		return nil
	}
	var items []autoreport.PendingItem
	if json.Unmarshal(raw, &items) != nil {
		return nil
	}
	return items
}

// savePending keeps the ones that are still worth sending (not older than a day, the last three).
func savePending(items []autoreport.PendingItem) {
	items = autoreport.FreshPending(items, time.Now())
	if len(items) == 0 {
		os.Remove(pendingPath())
		return
	}
	if raw, err := json.Marshal(items); err == nil {
		os.MkdirAll(filepath.Dir(pendingPath()), 0o700)
		os.WriteFile(pendingPath(), raw, 0o600)
	}
}

// retryPending tries again, at each look of the black box, the reports that did not go, oldest first, until one fails (the net is still down).
func (a *App) retryPending() {
	a.auto.mu.Lock()
	if a.auto.retrying {
		a.auto.mu.Unlock()
		return
	}
	items := autoreport.FreshPending(readPending(), time.Now())
	if len(items) == 0 {
		a.auto.mu.Unlock()
		os.Remove(pendingPath())
		return
	}
	a.auto.retrying = true
	a.auto.mu.Unlock()
	goSafe("авто-отчёт: повторная отправка", func() {
		defer func() { a.auto.mu.Lock(); a.auto.retrying = false; a.auto.mu.Unlock() }()
		left := items
		for _, it := range items {
			ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
			err := report.SendAuto(ctx, Version, it.ID, it.Text, it.Trigger, it.Install)
			cancel()
			if err != nil {
				break
			}
			left = left[1:]
			a.recordSent()
			logLine("тестирование: отчёт " + it.ID + " отправлен позже, когда сеть вернулась")
		}
		savePending(left)
	})
}

// ---- the switch ---------------------------------------------------------------------------------------------------------------------

// HelpView is what the page shows of «Помогать тестированию».
type HelpView struct {
	On    bool  `json:"on"`
	Count int   `json:"count"`
	Last  int64 `json:"last,omitempty"`
}

func (a *App) helpView() HelpView {
	s := a.settings.get()
	return HelpView{On: s.HelpTesting, Count: s.HelpCount, Last: s.HelpLast}
}

func newInstallID() string {
	return autoreport.NewInstallID(func(b []byte) { rand.Read(b) })
}

// SetHelpTesting turns «Помогать тестированию» on or off. On: a new random number of the installation, and the first digest in a day. Off:
// the number and everything that was counted are wiped, and the reports that waited are dropped.
func (a *App) SetHelpTesting(on bool) Result {
	if on == a.settings.get().HelpTesting {
		return Result{OK: true}
	}
	a.auto.mu.Lock()
	a.auto.tracker = autoreport.MismatchTracker{} // the looks of the time before do not count
	a.auto.mu.Unlock()
	if on {
		a.settings.update(func(s *Settings) {
			s.HelpTesting, s.HelpInstall, s.HelpDigest = true, newInstallID(), time.Now().Unix()
		})
		logLine("тестирование: включено: отчёты при сбоях отправляются сами, сводка раз в сутки")
	} else {
		a.settings.update(func(s *Settings) {
			s.HelpTesting, s.HelpInstall, s.HelpHistory, s.HelpCount, s.HelpLast, s.HelpDigest = false, "", nil, 0, 0, 0
		})
		os.Remove(pendingPath())
		logLine("тестирование: выключено: номер установки стёрт")
	}
	return Result{OK: true}
}

// HelpTestingPreview is what a report that goes by itself looks like now (for «Что отправляется»); it takes a few seconds.
func (a *App) HelpTestingPreview() string {
	install := a.settings.get().HelpInstall
	if install == "" {
		install = "…"
	}
	return report.Head("XXXXXX", "авто: <причина> (установка "+install+")", "", reportEnv()) + "\n\n" + a.collectReportFacts()
}
