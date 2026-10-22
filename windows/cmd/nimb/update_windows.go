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

	"golang.org/x/sys/windows"

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
	lastLog    string          // the last line of a check that was written to the log (the same line is written once)
}

// UpdateView is what the page shows.
type UpdateView struct {
	Available  bool   `json:"available"`
	Version    string `json:"version,omitempty"`
	Installing string `json:"installing,omitempty"`
	Error      string `json:"error,omitempty"`
	Notify     bool   `json:"notify"` // the notifications about new versions are on
	Checking   bool   `json:"checking"`
	Failed     bool   `json:"failed"`            // the last check did not work
	Checked    int64  `json:"checked,omitempty"` // when a check last worked (unix seconds), for «проверено сегодня»
}

func (u *updateState) view() UpdateView {
	u.mu.Lock()
	defer u.mu.Unlock()
	v := UpdateView{Installing: u.installing, Error: u.err, Checking: u.checking, Failed: u.failed}
	if !u.checked.IsZero() {
		v.Checked = u.checked.Unix()
	}
	if u.release != nil {
		v.Available, v.Version = true, u.release.Version
	}
	return v
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
		a.logCheck("обновления: для Windows пока нет релизов (" + err.Error() + ")")
		return
	}
	if err != nil {
		// A try that fails is quiet: the offered version, if there is one, stays where it is.
		a.upd.failed, a.upd.retrySoon = true, !errors.Is(err, update.ErrLimit)
		a.upd.mu.Unlock()
		a.logCheck("обновления: не удалось проверить: " + err.Error())
		return
	}
	newer := update.IsNewer(rel.Version, Version)
	a.upd.failed, a.upd.retrySoon, a.upd.checked = false, false, time.Now()
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
	a.upd.installing, a.upd.err = "Загрузка…", ""
	a.upd.mu.Unlock()
	go a.install(*rel)
	return Result{OK: true}
}

func (a *App) install(rel update.Release) {
	set := func(s string) { a.upd.mu.Lock(); a.upd.installing = s; a.upd.mu.Unlock() }
	fail := func(msg string) {
		logLine("обновления: не удалось: " + msg)
		a.upd.mu.Lock()
		a.upd.installing, a.upd.err = "", msg
		a.upd.mu.Unlock()
	}
	dir, err := os.MkdirTemp("", "nimb-update-")
	if err != nil {
		fail("Не удалось подготовить папку для загрузки.")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()
	path, err := a.upd.client.Download(ctx, rel, dir, set)
	if err != nil {
		os.RemoveAll(dir)
		fail(err.Error())
		return
	}
	set("Установка…")
	logLine("обновления: запускаю установщик версии " + rel.Version)
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, _ := syscall.UTF16PtrFromString(path)
	args, _ := syscall.UTF16PtrFromString("/S /relaunch")
	if err := windows.ShellExecute(0, verb, file, args, nil, windows.SW_SHOWNORMAL); err != nil {
		os.RemoveAll(dir)
		if err == windows.ERROR_CANCELLED {
			fail("Установка отменена: Windows не получила разрешения.")
		} else {
			fail("Не удалось запустить установщик.")
		}
		return
	}
	// The installer stops this program in a moment; if it does not (it failed), the page says so after a minute.
	go func() {
		time.Sleep(2 * time.Minute)
		a.upd.mu.Lock()
		a.upd.installing = ""
		a.upd.mu.Unlock()
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
