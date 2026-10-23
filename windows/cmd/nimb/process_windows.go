//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"github.com/wailsapp/wails/v2/pkg/logger"

	"github.com/Dizrane/Nimb/windows/internal/tunnelrestart"
	"github.com/Dizrane/Nimb/windows/internal/winevents"
)

// A program that sits in the tray for days and then is simply gone must say why. This file is that: where a panic goes, the reason of
// a normal exit, a pulse that shows when the program was last alive, and what Windows wrote about it. All of it goes to the log of the
// window and to the section «Процесс окна» of a report.

var processStarted = time.Now()

// afterWebView2Crash: this process was started by the one that ended because WebView2 did.
var afterWebView2Crash bool

func crashPath() string         { return filepath.Join(dataDir(), "crash.log") }
func crashPreviousPath() string { return filepath.Join(dataDir(), "crash-previous.log") }
func alivePath() string         { return filepath.Join(dataDir(), "alive.stamp") }

// previousCrash is what the last run wrote when it died of a panic or of a fatal error of the runtime (a deadlock, concurrent map writes,
// out of memory): the message and the stacks of all goroutines. It is read at the start and put into the log and into the report.
var previousCrash []string

// setupDiagnostics is the first thing the program does. The runtime writes a panic that nobody caught, or a fatal error, to the standard
// error; a program of the window has none, and the message was lost. Since Go 1.23 it can be told to write it to a file too.
func setupDiagnostics() {
	os.MkdirAll(dataDir(), 0o700)
	if raw, err := os.ReadFile(crashPath()); err == nil && len(strings.TrimSpace(string(raw))) > 0 {
		os.Rename(crashPath(), crashPreviousPath())
		lines := strings.Split(strings.TrimRight(string(raw), "\r\n"), "\n")
		if len(lines) > 60 {
			lines = lines[:60]
		}
		previousCrash = lines
	}
	if f, err := os.OpenFile(crashPath(), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600); err == nil {
		debug.SetCrashOutput(f, debug.CrashOptions{}) // the file stays open for as long as the program runs
	}
}

// logPanic writes a recovered panic with its stack to the log of the window (the stack lines have no time: they belong to the line above).
func logPanic(where string, value any, stack []byte) {
	logLine(fmt.Sprintf("ПАНИКА (остановлена, программа продолжает) в «%s»: %v", where, value))
	logMu.Lock()
	defer logMu.Unlock()
	if f, err := os.OpenFile(filepath.Join(dataDir(), "window.log"), os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
		defer f.Close()
		lines := strings.Split(strings.TrimRight(string(stack), "\n"), "\n")
		if len(lines) > 40 {
			lines = lines[:40]
		}
		for _, l := range lines {
			fmt.Fprintln(f, "    "+strings.TrimRight(l, "\r"))
		}
	}
}

// goSafe runs f in a goroutine that does not take the program down with it if it panics: the panic and its stack go to the log.
func goSafe(name string, f func()) {
	go func() {
		defer func() {
			if v := recover(); v != nil {
				logPanic(name, v, debug.Stack())
			}
		}()
		f()
	}()
}

// safely runs f here and now and does not let a panic out of it: it is logged with its stack. For the goroutines that wait for others.
func safely(name string, f func()) {
	defer func() {
		if v := recover(); v != nil {
			logPanic(name, v, debug.Stack())
		}
	}()
	f()
}

// goKeep runs a loop that is to live as long as the program: after a panic it is logged and the loop is started again, after a pause and
// not more than ten times (a loop that dies at once every time is left alone, and the log says so).
func goKeep(name string, f func()) {
	go func() {
		for attempt := 1; ; attempt++ {
			stopped := func() (died bool) {
				defer func() {
					if v := recover(); v != nil {
						logPanic(name, v, debug.Stack())
						died = true
					}
				}()
				f()
				return false
			}()
			if !stopped {
				return
			}
			if attempt >= 10 {
				logLine("«" + name + "» упала в десятый раз, больше не запускаю")
				return
			}
			time.Sleep(5 * time.Second)
			logLine("«" + name + "»: запускаю снова после паники")
		}
	}()
}

// ---- the pulse ---------------------------------------------------------------------------------------------------------------

// lastAlive is the time the previous run last wrote its pulse, and its process number; zero when there is none.
var lastAlive time.Time
var lastAlivePID int

// startPulse writes the time to a small file every thirty seconds. A run that ended unexpectedly was alive until the last of them, and the
// next start says so; what Windows wrote about the program in between is looked for in that window of time.
func startPulse() {
	if raw, err := os.ReadFile(alivePath()); err == nil {
		fields := strings.Fields(string(raw))
		if len(fields) >= 2 {
			if sec, err := strconv.ParseInt(fields[0], 10, 64); err == nil {
				lastAlive = time.Unix(sec, 0)
			}
			lastAlivePID, _ = strconv.Atoi(fields[1])
		}
	}
	write := func() {
		os.WriteFile(alivePath(), []byte(fmt.Sprintf("%d %d\n", time.Now().Unix(), os.Getpid())), 0o600)
	}
	write()
	goSafe("пульс", func() {
		for range time.Tick(30 * time.Second) {
			write()
		}
	})
}

// explainPreviousEnd writes to the log what is known about a run that ended unexpectedly: when it was last alive, what Windows wrote about
// the program since, and what the runtime wrote when it fell.
func explainPreviousEnd() {
	if !lastAlive.IsZero() {
		logLine(fmt.Sprintf("прошлый запуск (процесс %d) последний раз был жив в %s, то есть закончился между этим моментом и %s", lastAlivePID, lastAlive.Format("15:04:05"), time.Now().Format("15:04:05")))
	}
	for _, l := range previousCrashEvents() {
		logLine("Windows записала о Nimb: " + l)
	}
	if len(previousCrash) > 0 {
		logLine("прошлый запуск упал с паникой или фатальной ошибкой, вот что записала среда выполнения Go (первые строки):")
		logMu.Lock()
		if f, err := os.OpenFile(filepath.Join(dataDir(), "window.log"), os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
			for _, l := range previousCrash[:min(len(previousCrash), 25)] {
				fmt.Fprintln(f, "    "+strings.TrimRight(l, "\r"))
			}
			f.Close()
		}
		logMu.Unlock()
	}
}

// previousCrashEvents are the crashes of Nimb.exe that Windows wrote since a minute before the last pulse.
func previousCrashEvents() []string {
	within := time.Hour
	if !lastAlive.IsZero() {
		within = time.Since(lastAlive) + time.Minute
	}
	return winevents.Query("Application", "(EventID=1000 or EventID=1001)", within, []string{"Nimb.exe"}, 5)
}

// ---- the reason of an exit -----------------------------------------------------------------------------------------------------

var exitOnce sync.Once

// logExit writes why the program is ending, once.
func logExit(reason string) {
	exitOnce.Do(func() { logLine("выход: " + reason) })
}

// ---- what Wails says -------------------------------------------------------------------------------------------------------------

// wailsLog gives the log of Wails to the log of the window. Wails ends the program by itself when the browser process of WebView2 exits
// (os.Exit(-1) after a message that is not seen while the window is hidden), and writes a line about it just before; without this the line
// went nowhere.
type wailsLog struct{}

func (wailsLog) Print(message string)   { logLine("wails: " + strings.TrimSpace(message)) }
func (wailsLog) Println(message string) { logLine("wails: " + strings.TrimSpace(message)) }
func (wailsLog) Trace(string)           {}
func (wailsLog) Debug(string)           {}
func (wailsLog) Info(string)            {}
func (wailsLog) Warning(message string) { logLine("wails: предупреждение: " + message) }
func (wailsLog) Error(message string) {
	logLine("wails: ОШИБКА: " + message)
	if strings.Contains(message, "WebVie2wProcess failed with kind 0") { // the browser process of WebView2 is gone
		restartAfterWebView2Crash()
	}
}
func (wailsLog) Fatal(message string) { logLine("wails: ФАТАЛЬНАЯ ОШИБКА: " + message) }

var _ logger.Logger = wailsLog{}

// ---- for a report --------------------------------------------------------------------------------------------------------------------

// processFacts are the lines of the section «Процесс окна» of a report.
func (a *App) processFacts() []string {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	lines := []string{
		fmt.Sprintf("Процесс окна %d, запущен %s (работает %s)", os.Getpid(), processStarted.Format("2006-01-02 15:04:05"), uptimeText(time.Since(processStarted))),
		fmt.Sprintf("Память Go: куча %d МБ, всего у системы %d МБ; горутин %d", m.HeapAlloc>>20, m.Sys>>20, runtime.NumGoroutine()),
		"Среда окна: WebView2 " + webView2Version(),
	}
	if !lastAlive.IsZero() {
		lines = append(lines, fmt.Sprintf("Прошлый запуск (процесс %d) последний раз был жив в %s", lastAlivePID, lastAlive.Format("2006-01-02 15:04:05")))
	}
	if len(previousCrash) > 0 {
		lines = append(lines, "Прошлый запуск упал с паникой или фатальной ошибкой, записано средой выполнения Go:")
		for _, l := range previousCrash[:min(len(previousCrash), 30)] {
			lines = append(lines, "    "+l)
		}
	}
	return lines
}

// webView2Version is the version of the WebView2 runtime that the program uses (the one that is installed for all or for the person).
func webView2Version() string {
	const id = `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`
	for _, where := range []struct {
		root registry.Key
		path string
	}{
		{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\` + id},
		{registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\EdgeUpdate\Clients\` + id},
		{registry.CURRENT_USER, `Software\Microsoft\EdgeUpdate\Clients\` + id},
	} {
		if k, err := registry.OpenKey(where.root, where.path, registry.QUERY_VALUE); err == nil {
			v, _, err := k.GetStringValue("pv")
			k.Close()
			if err == nil && v != "" {
				return v
			}
		}
	}
	return "версия не найдена"
}

// ---- the browser process of WebView2 is gone --------------------------------------------------------------------------------

// When the browser process of WebView2 exits (it is killed, or the runtime is replaced, or a cleaner takes it), Wails writes the line that
// wailsLog sees, shows a message box (in English, owned by a window that is hidden while Nimb sits in the tray) and then ends the whole
// program with os.Exit(-1): the icon at the clock goes, and the proxy of Telegram goes with it, while the service goes on with the DNS and
// the tunnel. A person sees the tray icon vanish and Telegram stop, nothing more (reproduced in the VM by ending that process).
// The way out that is within reach: start the program again by ourselves, at once, before Wails does what it does. The new process waits for
// this one to go (it holds the lock of the single instance), and comes up in the tray (or with the window, if the window was in front).

// restartAfterWebView2Crash starts a new Nimb and ends this process; it returns only when it decided not to (too often, or it could not).
func restartAfterWebView2Crash() {
	text, _ := os.ReadFile(webView2RestartsPath())
	now := time.Now()
	if !tunnelrestart.Allowed(tunnelrestart.Recent(string(text), now, tunnelrestart.Window), now) {
		logLine("WebView2 завершается слишком часто (три раза за десять минут): сам не перезапускаюсь, дальше всё как у Wails")
		return
	}
	exe, err := os.Executable()
	if err != nil {
		logLine("перезапуск после падения WebView2: не нашёл свой файл: " + err.Error())
		return
	}
	args := []string{fmt.Sprintf("--wait-pid=%d", os.Getpid()), "--after-webview2-crash"}
	if !windowInFront() {
		args = append(args, "--hidden")
	}
	cmd := exec.Command(exe, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.DETACHED_PROCESS | windows.CREATE_NEW_PROCESS_GROUP}
	if err := cmd.Start(); err != nil {
		logLine("перезапуск после падения WebView2 не вышел: " + err.Error())
		return
	}
	os.WriteFile(webView2RestartsPath(), []byte(tunnelrestart.Add(string(text), now)), 0o600)
	logExit(fmt.Sprintf("браузерный процесс WebView2 завершился, Nimb запускается заново (новый процесс %d)", cmd.Process.Pid))
	endSession()
	os.Exit(0)
}

func webView2RestartsPath() string { return filepath.Join(dataDir(), "webview2.restarts") }

// waitForPreviousProcess is at the start of a process that was started by restartAfterWebView2Crash: it waits for the old one to go.
func waitForPreviousProcess() (afterCrash bool) {
	for _, arg := range os.Args[1:] {
		if arg == "--after-webview2-crash" {
			afterCrash = true
		}
		if v, ok := strings.CutPrefix(arg, "--wait-pid="); ok {
			if pid, err := strconv.Atoi(v); err == nil {
				if h, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid)); err == nil {
					windows.WaitForSingleObject(h, 30_000)
					windows.CloseHandle(h)
				}
			}
		}
	}
	return afterCrash
}
