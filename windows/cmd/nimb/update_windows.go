//go:build windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"golang.org/x/sys/windows"

	"github.com/Dizrane/Nimb/windows/internal/autoreport"
	"github.com/Dizrane/Nimb/windows/internal/notice"
	"github.com/Dizrane/Nimb/windows/internal/update"
)

// updateState is the look for a new version and its installation.
type updateState struct {
	mu         sync.Mutex
	client     *update.Client
	lastTry    time.Time
	checking   bool
	checked    time.Time       // when a check last worked
	failed     bool            // the last check did not work
	retrySoon  bool            // ... and the next one comes sooner than usual (not when GitHub refused because of its limit)
	release    *update.Release // a newer version, when there is one
	installing string          // what is going on while the installer is being brought ("Загрузка…")
	err        string          // why the last installation did not happen
	// The installation by stages, for the window of the update.
	stages     [update.StageCount]string // "", "running", "done" or "failed" for each stage
	downloaded int64
	total      int64
	failStage  update.Stage
	restarting bool   // the installer has been given to Windows and takes over in a moment
	showWindow bool   // the tray (or a failure) asks the page to open the window of the update
	lastLog    string // the last line of a check that was written to the log (the same line is written once)
}

// UpdateStageView is one step of the installation as the window of the update draws it.
type UpdateStageView struct {
	Title string `json:"title"`
	State string `json:"state"` // pending, running, done, failed
}

// UpdateView is what the page shows.
type UpdateView struct {
	Available  bool   `json:"available"`
	Version    string `json:"version,omitempty"`
	Installing string `json:"installing,omitempty"`
	Error      string `json:"error,omitempty"`
	// The window of the update: what is new, the stages, how far it has got (0 to 1) and the line over the bar, the stage a failure stopped
	// at, and whether the installer has been handed over (the program is about to be replaced).
	Current     string            `json:"current"`
	Notes       []string          `json:"notes"`
	PageURL     string            `json:"pageUrl,omitempty"`
	Started     bool              `json:"started"` // an installation was begun (it goes, it failed, or it is handed over)
	Stages      []UpdateStageView `json:"stages"`
	Fraction    float64           `json:"fraction"`
	Line        string            `json:"line,omitempty"`
	FailedStage string            `json:"failedStage,omitempty"`
	Restarting  bool              `json:"restarting,omitempty"`
	Show        bool              `json:"show,omitempty"` // the page opens the window of the update (once)
	Notify      bool              `json:"notify"`         // the notifications about new versions are on
	Checking    bool              `json:"checking"`
	Failed      bool              `json:"failed"`            // the last check did not work
	Checked     int64             `json:"checked,omitempty"` // when a check last worked (unix seconds), for «проверено сегодня»
}

func (u *updateState) view() UpdateView {
	u.mu.Lock()
	defer u.mu.Unlock()
	v := UpdateView{Installing: u.installing, Error: u.err, Checking: u.checking, Failed: u.failed}
	if !u.checked.IsZero() {
		v.Checked = u.checked.Unix()
	}
	v.Current, v.Notes, v.Stages = Version, []string{}, []UpdateStageView{}
	if u.release != nil {
		v.Available, v.Version = true, u.release.Version
		v.Notes, v.PageURL = update.WhatsNew(u.release.Notes), u.release.PageURL
		if v.Notes == nil {
			v.Notes = []string{}
		}
	}
	fraction, running := 0.0, -1
	for s := update.Stage(0); s < update.StageCount; s++ {
		state := u.stages[s]
		if state == "" {
			state = "pending"
		}
		v.Stages = append(v.Stages, UpdateStageView{Title: s.Title(), State: state})
		switch state {
		case "done":
			fraction += s.Weight()
		case "running":
			running = int(s)
			if s == update.StageDownload && u.total > 0 {
				fraction += s.Weight() * float64(u.downloaded) / float64(u.total)
			}
		case "failed":
			v.FailedStage = s.Title()
		}
		if state != "pending" {
			v.Started = true
		}
	}
	v.Fraction = min(fraction, 1)
	switch {
	case u.restarting:
		v.Restarting, v.Line, v.Fraction = true, "Готово", 1
	case v.FailedStage != "":
		v.Line = "Остановилось"
	case running == int(update.StageDownload) && u.total > 0:
		v.Line = "Загрузка · " + megabytes(u.downloaded) + " из " + megabytes(u.total)
	case running >= 0:
		v.Line = update.Stage(running).Title()
	case v.Started:
		v.Line = "Начинаю…"
	}
	v.Show = u.showWindow
	return v
}

// megabytes is «4,5 МБ», the way the window of the update says a size.
func megabytes(n int64) string {
	return strings.Replace(strconv.FormatFloat(float64(n)/(1<<20), 'f', 1, 64), ".", ",", 1) + " МБ"
}

// AckUpdateShow is the page saying that it has opened the window of the update that was asked for.
func (a *App) AckUpdateShow() {
	a.upd.mu.Lock()
	a.upd.showWindow = false
	a.upd.mu.Unlock()
}

// OpenUpdateWindow asks the page to open the window of the update (from the tray); the window of Nimb is brought forward.
func (a *App) OpenUpdateWindow() {
	a.upd.mu.Lock()
	a.upd.showWindow = true
	a.upd.mu.Unlock()
	a.ShowWindow()
}

// updateInterval is ten minutes; NIMB_UPDATE_INTERVAL (seconds, at least 5) is for trying it out.
func updateInterval() time.Duration {
	if n, err := strconv.Atoi(os.Getenv("NIMB_UPDATE_INTERVAL")); err == nil && n >= 5 {
		return time.Duration(n) * time.Second
	}
	return update.Interval
}

// updateLoop asks about a new version when the window starts and then every ten minutes, for as long as the program runs (with the
// window closed to the tray too).
func (a *App) updateLoop() {
	a.upd.client = update.NewClient(runtime.GOARCH)
	cleanOldInstallers()
	interval := updateInterval()
	tick := min(30*time.Second, max(time.Second, interval/4))
	for {
		a.upd.mu.Lock()
		due := !a.upd.checking && a.upd.installing == "" && update.IsDue(a.upd.lastTry, time.Now(), update.Wait(interval, a.upd.retrySoon))
		a.upd.mu.Unlock()
		if due {
			a.checkUpdate()
		}
		time.Sleep(tick)
	}
}

// logCheck writes a line about a check to the log, unless it is the same as the last one: a check comes every ten minutes, and the
// same answer a hundred times is not news.
func (a *App) logCheck(line string) {
	a.upd.mu.Lock()
	same := a.upd.lastLog == line
	a.upd.lastLog = line
	a.upd.mu.Unlock()
	if !same {
		logLine(line)
	}
}

func (a *App) checkUpdate() {
	a.upd.mu.Lock()
	a.upd.checking, a.upd.lastTry = true, time.Now()
	a.upd.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rel, err := a.upd.client.Latest(ctx)

	a.upd.mu.Lock()
	a.upd.checking = false
	if errors.Is(err, update.ErrNoRelease) {
		// GitHub answered: there is nothing for Windows to offer yet. That is a check that worked, with no newer version.
		a.upd.failed, a.upd.retrySoon, a.upd.checked, a.upd.release = false, false, time.Now(), nil
		a.upd.mu.Unlock()
		a.resetFailedChecks()
		a.logCheck("обновления: для Windows пока нет релизов (" + err.Error() + ")")
		return
	}
	if err != nil {
		// A try that fails is quiet: the offered version, if there is one, stays where it is.
		a.upd.failed, a.upd.retrySoon = true, !errors.Is(err, update.ErrLimit)
		a.upd.mu.Unlock()
		a.logCheck("обновления: не удалось проверить: " + err.Error())
		// Three failed checks in a row are told (a limit of GitHub is not a failed check: it is the address of the person that is limited).
		// ... nor is one that failed only because there is no network (a computer that has just woken up): no report for it.
		if !errors.Is(err, update.ErrLimit) && internetWorks() {
			a.auto.mu.Lock()
			a.auto.failed++
			told := a.auto.failed == 3
			a.auto.mu.Unlock()
			if told {
				a.notifyAuto(autoreport.UpdateCheck)
			}
		}
		return
	}
	newer := update.IsNewer(rel.Version, Version)
	if a.settings.get().LatestKnown != rel.Version {
		a.settings.update(func(s *Settings) { s.LatestKnown = rel.Version })
	}
	a.upd.failed, a.upd.retrySoon, a.upd.checked = false, false, time.Now()
	a.resetFailedChecks()
	a.upd.err = "" // a check that worked: the error of an installation that did not happen is old news
	if newer {
		a.upd.release = &rel
	} else {
		a.upd.release = nil
	}
	a.upd.mu.Unlock()
	if !newer {
		return
	}
	a.logCheck("обновления: вышла версия " + rel.Version)
	if set := a.settings.get(); !set.UpdateNotifyOff && update.ShouldTell(rel.Version, set.UpdateTold) && (!windowInFront() || notice.ShowsInFront(notice.UpdateTag)) {
		a.settings.update(func(s *Settings) { s.UpdateTold = rel.Version })
		balloon(notice.UpdateTag, 1, "Nimb", "Вышла новая версия "+rel.Version+". Откройте Nimb и нажмите «Обновить».")
	}
}

// InstallUpdate brings the installer of the newer version, checks it and starts it quietly, with the question of Windows about the
// administrator rights. The installer stops Nimb, replaces the files, starts the service again and opens the window.
func (a *App) InstallUpdate() Result {
	a.upd.mu.Lock()
	rel := a.upd.release
	if rel == nil || a.upd.installing != "" {
		a.upd.mu.Unlock()
		return Result{Error: "Новой версии нет."}
	}
	a.upd.installing, a.upd.err = "Подготовка…", ""
	a.upd.stages, a.upd.downloaded, a.upd.total, a.upd.restarting = [update.StageCount]string{}, 0, 0, false
	a.upd.mu.Unlock()
	goSafe("установка обновления", func() { a.install(*rel) })
	return Result{OK: true}
}

func (a *App) install(rel update.Release) {
	stage := func(s update.Stage, state string) {
		a.upd.mu.Lock()
		a.upd.stages[s] = state
		if state == "running" {
			a.upd.installing = s.Title() + "…"
		}
		a.upd.mu.Unlock()
		logLine("обновления: этап «" + s.Title() + "»: " + map[string]string{"running": "начат", "done": "готов", "failed": "не вышел"}[state])
	}
	fail := func(at update.Stage, msg string) {
		logLine("обновления: не удалось на этапе «" + at.Title() + "»: " + msg)
		a.upd.mu.Lock()
		a.upd.stages[at] = "failed"
		a.upd.installing, a.upd.err, a.upd.failStage = "", msg, at
		a.upd.showWindow = true // a failure must not be missed: the window comes back with the reason
		a.upd.mu.Unlock()
		a.ShowWindow()
		if at.IsOurs() {
			a.notifyAuto(autoreport.UpdateInstall(at.Title()))
		}
	}
	stage(update.StagePrepare, "running")
	dir, err := os.MkdirTemp("", "nimb-update-")
	if err != nil {
		fail(update.StagePrepare, "Не удалось подготовить папку для загрузки.")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()
	// Fetch says the preparation ends itself, after it has looked at the release; the folder was part of it.
	path, err := a.upd.client.Fetch(ctx, rel, dir, update.Hooks{
		Stage: func(s update.Stage, state string) { stage(s, state) },
		Bytes: func(done, total int64) {
			a.upd.mu.Lock()
			a.upd.downloaded, a.upd.total = done, total
			a.upd.mu.Unlock()
		},
	})
	if err != nil {
		os.RemoveAll(dir)
		var se *update.StageError
		if errors.As(err, &se) {
			fail(se.Stage, se.Msg)
		} else {
			fail(update.StageDownload, err.Error())
		}
		return
	}
	stage(update.StageInstall, "running")
	logLine("обновления: запускаю установщик версии " + rel.Version)
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, _ := syscall.UTF16PtrFromString(path)
	args, _ := syscall.UTF16PtrFromString("/S /relaunch")
	// The installer stops this program: that is a controlled end, so the mark of a running program goes first (and comes back if the
	// installer does not take over).
	endSession()
	if err := windows.ShellExecute(0, verb, file, args, nil, windows.SW_SHOWNORMAL); err != nil {
		restoreSession()
		os.RemoveAll(dir)
		if err == windows.ERROR_CANCELLED {
			fail(update.StageInstall, "Установка отменена: Windows не получила разрешения.")
		} else {
			fail(update.StageInstall, "Не удалось запустить установщик.")
		}
		return
	}
	a.upd.mu.Lock()
	a.upd.restarting = true
	a.upd.mu.Unlock()
	// The installer stops this program in a moment; if it does not (it failed), the page says so after two minutes.
	go func() {
		time.Sleep(2 * time.Minute)
		restoreSession()
		a.upd.mu.Lock()
		a.upd.installing, a.upd.restarting = "", false
		a.upd.stages[update.StageInstall] = "failed"
		a.upd.err, a.upd.failStage, a.upd.showWindow = "Установщик не заменил Nimb за две минуты. Попробуйте ещё раз.", update.StageInstall, true
		a.upd.mu.Unlock()
		logLine("обновления: установщик не заменил Nimb за две минуты")
	}()
}

// cleanOldInstallers removes the folders of installers that an earlier run left in the temporary folder.
func cleanOldInstallers() {
	matches, _ := filepath.Glob(filepath.Join(os.TempDir(), "nimb-update-*"))
	for _, m := range matches {
		if info, err := os.Stat(m); err == nil && info.IsDir() && strings.HasPrefix(filepath.Base(m), "nimb-update-") && time.Since(info.ModTime()) > time.Hour {
			os.RemoveAll(m)
		}
	}
}

// SetNotify turns the notifications about new versions on or off.
func (a *App) SetNotify(on bool) { a.settings.update(func(s *Settings) { s.UpdateNotifyOff = !on }) }

// lastTest is when the test notification was last made: it is not made oftener than every three seconds.
var lastTest struct {
	mu sync.Mutex
	at time.Time
}

// SendTestNotification shows a notification at once, so that the person can see that they come through. A second press replaces the
// first (the test has one tag of its own), so there is one of it on the screen and the banner comes again. Unlike the real ones it is
// shown when the window of Nimb is in front: it is asked for in that very window. It is only for when the notifications are on.
func (a *App) SendTestNotification() Result {
	if a.settings.get().UpdateNotifyOff {
		return Result{Error: "Уведомления выключены."}
	}
	lastTest.mu.Lock()
	if time.Since(lastTest.at) < 3*time.Second {
		lastTest.mu.Unlock()
		return Result{} // too soon: nothing is made
	}
	lastTest.at = time.Now()
	lastTest.mu.Unlock()
	balloon(notice.TestTag, 2, notice.TestTitle, notice.TestText)
	logLine("уведомления: показано тестовое уведомление")
	return Result{OK: true}
}

// OpenUpdatePage opens the page of the offered release in the browser (only a page of this repository on GitHub).
func (a *App) OpenUpdatePage() {
	a.upd.mu.Lock()
	rel := a.upd.release
	a.upd.mu.Unlock()
	if rel != nil && strings.HasPrefix(rel.PageURL, "https://github.com/") {
		wruntime.BrowserOpenURL(a.ctx, rel.PageURL)
	}
}

// CopyUpdateDetails puts what goes to the developer by hand on the clipboard: the versions, the system, the stage and the words of the error.
func (a *App) CopyUpdateDetails() Result {
	a.upd.mu.Lock()
	rel, msg, stage := a.upd.release, a.upd.err, a.upd.failStage
	a.upd.mu.Unlock()
	to := "?"
	if rel != nil {
		to = rel.Version
	}
	text := "Nimb " + Version + " → " + to + "\nWindows " + windowsVersion() + "\nЭтап: " + stage.Title() + "\nОшибка: " + msg
	if err := wruntime.ClipboardSetText(a.ctx, text); err != nil {
		return Result{Error: "Не удалось скопировать."}
	}
	return Result{OK: true}
}
