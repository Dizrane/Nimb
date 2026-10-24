//go:build windows

// Package helper is what the service of Nimb does when the window asks: bring the tunnel up and down and look after the
// anonymous account that the tunnel uses. It runs as the system, so it takes nothing from the window except the name of a
// command (see package ipc). The account and the settings live in a folder that only the system and the administrators can read.
package helper

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/windows"

	"github.com/Dizrane/Nimb/windows/internal/awgconf"
	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
	"github.com/Dizrane/Nimb/windows/internal/logfile"
	"github.com/Dizrane/Nimb/windows/internal/tgproxy"
	"github.com/Dizrane/Nimb/windows/internal/tunnel"
	"github.com/Dizrane/Nimb/windows/internal/tunneldrop"
	"github.com/Dizrane/Nimb/windows/internal/tunnelrestart"
	"github.com/Dizrane/Nimb/windows/internal/version"
	"github.com/Dizrane/Nimb/windows/internal/warp"
)

// tunnelLogReport is how many of the last lines of the log of the tunnel go into a report.
const tunnelLogReport = 25

// tunnelMarksReport is how many of the marks of the service in that log go into a report, from the whole file.
const tunnelMarksReport = 30

// DataDir is where the service keeps its files.
func DataDir() string {
	base := os.Getenv("ProgramData")
	if base == "" {
		base = `C:\ProgramData`
	}
	return filepath.Join(base, "Nimb")
}

// The DNS of the tunnel when Smart DNS is off. Without it the system keeps asking the router of the home network, which the
// tunnel does not reach.
var defaultTunnelDNS = []netip.Addr{netip.MustParseAddr("1.1.1.1"), netip.MustParseAddr("1.0.0.1")}

// Helper carries out the commands.
type Helper struct {
	dir  string
	logf func(format string, args ...any)

	mu  sync.Mutex
	tun *tunnel.Tunnel

	// backup is what the adapters had before Smart DNS; nil when Smart DNS is off.
	backup  *dnsx.Backup
	watch   *dnsWatcher
	started time.Time

	// stopWatch is closed when the tunnel is taken down by hand, so that the end of its program is not taken for a stop by itself (see
	// package tunneldrop). drop is the note of the last time the tunnel stopped by itself.
	stopWatch chan struct{}
	drop      *tunneldrop.Note

	// The proxy of Telegram (see telegram_windows.go): its settings, the engine once it was made, a word for the window when it could not be kept
	// going, and the channel that stops its watcher.
	tg            tgproxy.Settings
	engine        *tgproxy.Engine
	telegramError string
	tgStop        chan struct{}

	// While the program of the tunnel is being started again after it ended by itself: when that began (the window is told that the tunnel
	// is on for as long as the mark is fresh) and the channel that is closed to take the restart back (the person switched the tunnel off or on).
	lastStatus    atomic.Pointer[ipc.Response] // the last answer to «status» (see Handle)
	lastClosed    time.Time                    // when the last tunnel was closed (zero: none yet)
	restarting    time.Time
	restartCancel chan struct{}
	// tlog is the log of the program of the tunnel.
	tlog *tunnelLog
}

// New prepares the folder (closed to everybody but the system and the administrators) and returns a helper.
func New(dir string, logf func(string, ...any)) (*Helper, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	if err := secureDir(dir); err != nil {
		return nil, fmt.Errorf("папка службы: %w", err)
	}
	h := &Helper{dir: dir, logf: logf, started: time.Now(), tlog: newTunnelLog(filepath.Join(dir, "tunnel.log"))}
	h.backup = h.loadBackup()
	h.drop = h.loadDrop()
	h.loadTelegram()
	h.startWatching()
	h.startTelegramWatch()
	return h, nil
}

// Close takes the tunnel down. Smart DNS stays as it is: the settings are on the adapters and the backup is on the disk, and
// the window (or the uninstaller) gives them back when the person asks.
func (h *Helper) Close() {
	h.stopWatching()
	if h.tgStop != nil {
		close(h.tgStop)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.engine != nil {
		h.engine.Stop() // the settings say it was on: it comes back with the service
	}
	h.down()
}

// Handle implements ipc.Handler.
func (h *Helper) Handle(ctx context.Context, req ipc.Request) ipc.Response {
	// A start of the tunnel can take half a minute with the lock held. The window asks for the status every few seconds and must not stand
	// waiting for it: while the lock is taken it is given the last status that was made (the window itself knows that it is busy).
	switch req.Cmd {
	case ipc.Ping:
		return ipc.Response{OK: true}
	case ipc.Status:
		if !h.mu.TryLock() {
			if last := h.lastStatus.Load(); last != nil {
				return *last
			}
			h.mu.Lock()
		}
	default:
		h.mu.Lock()
	}
	defer h.mu.Unlock()
	switch req.Cmd {
	case ipc.Status:
		resp := ipc.Response{OK: true, Tunnel: h.status(), DNS: h.dnsStatus(), Telegram: h.telegramStatus()}
		h.lastStatus.Store(&resp)
		return resp
	case ipc.Diag:
		return ipc.Response{OK: true, Lines: h.diag(), Version: version.Version, TunnelLog: h.tlog.Tail(tunnelLogReport), TunnelMarks: h.tlog.Marks(tunnelMarksReport), ServicePrevious: logfile.Tail(logfile.PreviousPath(filepath.Join(h.dir, "service.log")), 25), TunnelPrevious: logfile.Tail(logfile.PreviousPath(filepath.Join(h.dir, "tunnel.log")), 20)}
	case ipc.DNSSet:
		provider, ok := dnsx.Find(req.Provider)
		if !ok {
			return ipc.Response{Error: "неизвестный провайдер DNS", DNS: h.dnsStatus()}
		}
		if err := h.dnsSet(provider); err != nil {
			h.logf("DNS: включить %s (%s) не вышло: %v", provider.Name, provider.ID, err)
			return ipc.Response{Error: err.Error(), DNS: h.dnsStatus()}
		}
		return ipc.Response{OK: true, DNS: h.dnsStatus()}
	case ipc.DNSRestore:
		if err := h.dnsRestore(); err != nil {
			h.logf("DNS: вернуть прежние не вышло: %v", err)
			return ipc.Response{Error: err.Error(), DNS: h.dnsStatus()}
		}
		return ipc.Response{OK: true, DNS: h.dnsStatus()}
	case ipc.TunnelUp:
		h.cancelRestart() // the person decides now: nothing that was started before them goes on
		if err := h.up(ctx); err != nil {
			h.logf("туннель: включить не вышло: %v", err)
			return ipc.Response{Error: err.Error(), Tunnel: h.status()}
		}
		return ipc.Response{OK: true, Tunnel: h.status()}
	case ipc.TunnelDown:
		h.down()
		return ipc.Response{OK: true, Tunnel: h.status()}
	case ipc.TelegramUp:
		if err := h.telegramUp(req.Secret, req.Port); err != nil {
			h.logf("прокси Telegram: включить не вышло: %v", err)
			return ipc.Response{Error: err.Error(), Telegram: h.telegramStatus()}
		}
		return ipc.Response{OK: true, Telegram: h.telegramStatus()}
	case ipc.TelegramDown:
		h.telegramDown()
		return ipc.Response{OK: true, Telegram: h.telegramStatus()}
	case ipc.TunnelUnregister:
		h.down()
		h.unregister(ctx)
		return ipc.Response{OK: true, Tunnel: h.status()}
	}
	return ipc.Response{Error: "неизвестная команда"}
}

func (h *Helper) status() *ipc.TunnelStatus {
	st := &ipc.TunnelStatus{HandshakeAgo: -1, HasAccount: h.hasAccount()}
	if h.tun != nil {
		st.Up = true
		if hs := h.tun.Handshake(); !hs.IsZero() {
			st.HandshakeAgo = int(time.Since(hs).Seconds())
		}
		st.Received, st.Sent = h.tun.Counters()
	}
	if h.tun == nil && h.restartCancel != nil && tunnelrestart.IsActive(h.restarting, time.Now()) {
		st.Up, st.Restarting = true, true
	}
	if h.drop != nil {
		st.DroppedAt, st.DropReason = h.drop.When.Unix(), h.drop.Reason
	}
	for _, r := range tunnelrestart.Recent(h.readRestarts(), time.Now(), 24*time.Hour) {
		st.Restarts = append(st.Restarts, r.Unix())
	}
	return st
}

func (h *Helper) up(ctx context.Context) error {
	if h.tun != nil {
		return nil
	}
	acc, err := h.account(ctx)
	if err != nil {
		return err
	}
	cfg, err := awgconf.Parse(acc.Config)
	if err != nil {
		return fmt.Errorf("настройки туннеля не прошли проверку: %w", err)
	}
	if wait := tunnelrestart.SettleWait(time.Since(h.lastClosed), !h.lastClosed.IsZero()); wait > 0 {
		h.logf("туннель: прошлый закрыт только что, жду %.0f с, чтобы он ушёл совсем", wait.Seconds())
		time.Sleep(wait)
	}
	h.logf("включаю туннель")
	var t *tunnel.Tunnel
	for attempt, timeout := range tunnelrestart.AttemptTimeouts {
		t, err = tunnel.Up(cfg, tunnel.Options{Name: "Nimb", DNS: h.tunnelDNS(), Logf: h.logf, DeviceLogf: h.tlog.Logf, HandshakeTimeout: timeout})
		// Two things went wrong at a start right after a stop, and both were gone on a second try: no answer to the handshake, and an adapter
		// that Windows did not know yet («Element not found» while the routes were set). The tunnel of the failed attempt is already taken
		// down. One more try, so that the person does not see an error for a start that a moment later would have worked.
		retryable := errors.Is(err, tunnel.ErrNoHandshake) || errors.Is(err, tunnel.ErrAdapter) || errors.Is(err, windows.ERROR_NOT_FOUND)
		if !retryable || attempt == len(tunnelrestart.AttemptTimeouts)-1 {
			break
		}
		h.tlog.Mark("start failed, trying once more: " + err.Error())
		h.logf("туннель: не вышло (%v), пробую ещё раз", err)
		time.Sleep(tunnelrestart.RetryPause)
	}
	if err != nil {
		if errors.Is(err, tunnel.ErrNoHandshake) {
			return errors.New("сервер не ответил, интернет остался прежним")
		}
		return err
	}
	h.tun = t
	h.clearDrop()
	h.watchTunnel(t)
	h.tlog.Mark("up")
	return nil
}

// down takes the tunnel down for good: a restart that is going on is taken back too, nothing is started after the person's switching off.
func (h *Helper) down() {
	h.cancelRestart()
	h.closeTunnel()
}

func (h *Helper) closeTunnel() {
	if h.stopWatch != nil {
		close(h.stopWatch)
		h.stopWatch = nil
	}
	if h.tun != nil {
		h.tun.Close()
		h.tun = nil
		h.lastClosed = time.Now()
	}
}

func (h *Helper) dropPath() string { return filepath.Join(h.dir, "tunnel.dropped") }

func (h *Helper) loadDrop() *tunneldrop.Note {
	raw, err := os.ReadFile(h.dropPath())
	if err != nil {
		return nil
	}
	if n, ok := tunneldrop.ParseNote(string(raw)); ok {
		return &n
	}
	return nil
}

// clearDrop forgets the note: the tunnel is up again.
func (h *Helper) clearDrop() {
	h.drop = nil
	os.Remove(h.dropPath())
}

// watchTunnel looks after the tunnel that has just come up: if its program ends without being asked to, the tunnel is cleaned up.
func (h *Helper) watchTunnel(t *tunnel.Tunnel) {
	stop := make(chan struct{})
	h.stopWatch = stop
	go func() {
		if tunneldrop.Unexpected(stop, t.Exited()) {
			h.tunnelEnded(t, stop)
		}
	}()
}

// tunnelEnded: the program of the tunnel ended by itself. First the routes go (the internet goes on working while it is started again), then
// the rest of the tunnel (DNS of the adapter, the adapter). Then the program is started again, up to three times in ten minutes; the person
// is not told, the switch of the window stays on. Only when that does not work does the note of the stop come, and the window tells the
// person. Nothing else ever takes the tunnel down.
func (h *Helper) tunnelEnded(t *tunnel.Tunnel, stop chan struct{}) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.tun != t || h.stopWatch != stop {
		return // taken down by hand in the meantime
	}
	h.logf("программа туннеля закончила сама: закрываю туннель")
	h.tlog.Mark("daemon-exited")
	t.DropRoutes()
	h.closeTunnel()
	if !tunnelrestart.Allowed(tunnelrestart.Recent(h.readRestarts(), time.Now(), tunnelrestart.Window), time.Now()) {
		h.tlog.Mark("restart skipped: three in ten minutes")
		h.giveUp()
		return
	}
	cancel := make(chan struct{})
	h.restartCancel, h.restarting = cancel, time.Now()
	go h.restart(cancel)
}

// restart starts the program of the tunnel again, with a pause before each try. A switching off or on by the person closes cancel and
// ends it.
func (h *Helper) restart(cancel chan struct{}) {
	for _, wait := range tunnelrestart.Waits {
		select {
		case <-cancel:
			return
		case <-time.After(wait):
		}
		h.mu.Lock()
		if h.restartCancel != cancel {
			h.mu.Unlock()
			return
		}
		h.tlog.Mark("restarting")
		ctx, stop := context.WithTimeout(context.Background(), time.Minute)
		err := h.up(ctx)
		stop()
		if err == nil {
			h.saveRestart(time.Now())
			h.tlog.Mark("restarted")
			h.restartCancel, h.restarting = nil, time.Time{}
			h.mu.Unlock()
			return
		}
		h.logf("перезапуск туннеля не вышел: %v", err)
		h.mu.Unlock()
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.restartCancel != cancel {
		return
	}
	h.tlog.Mark("restart failed")
	h.restartCancel, h.restarting = nil, time.Time{}
	h.giveUp()
}

// cancelRestart takes back a restart that is going on.
func (h *Helper) cancelRestart() {
	if h.restartCancel != nil {
		close(h.restartCancel)
		h.restartCancel, h.restarting = nil, time.Time{}
	}
}

// giveUp leaves the note that the tunnel stopped by itself: the window tells the person.
func (h *Helper) giveUp() {
	note := tunneldrop.Note{When: time.Now(), Reason: tunneldrop.DaemonExited}
	h.drop = &note
	if err := os.WriteFile(h.dropPath(), []byte(note.Format()), 0o600); err != nil {
		h.logf("заметку об остановке записать не вышло: %v", err)
	}
}

func (h *Helper) restartsPath() string { return filepath.Join(h.dir, "tunnel.restarts") }

func (h *Helper) readRestarts() string {
	raw, _ := os.ReadFile(h.restartsPath())
	return string(raw)
}

// saveRestart remembers a restart that worked (the last fifty), for the limit and for the report.
func (h *Helper) saveRestart(when time.Time) {
	if err := os.WriteFile(h.restartsPath(), []byte(tunnelrestart.Add(h.readRestarts(), when)), 0o600); err != nil {
		h.logf("запись о перезапуске сохранить не вышло: %v", err)
	}
}

// account returns the account of this installation, making one on the first use.
func (h *Helper) account(ctx context.Context) (*warp.Account, error) {
	if acc, err := h.loadAccount(); err == nil {
		return acc, nil
	}
	h.logf("создаю анонимный аккаунт WARP")
	acc, err := warp.Register(ctx)
	if err != nil {
		return nil, err
	}
	if err := h.saveAccount(acc); err != nil {
		// Without a place to keep it the account is useless and would stay at Cloudflare for nothing.
		warp.Unregister(ctx, acc.ID, acc.Token)
		return nil, fmt.Errorf("не удалось сохранить аккаунт: %w", err)
	}
	return acc, nil
}

func (h *Helper) accountPath() string { return filepath.Join(h.dir, "account.json") }

func (h *Helper) hasAccount() bool {
	_, err := os.Stat(h.accountPath())
	return err == nil
}

func (h *Helper) loadAccount() (*warp.Account, error) {
	raw, err := os.ReadFile(h.accountPath())
	if err != nil {
		return nil, err
	}
	var acc warp.Account
	if err := json.Unmarshal(raw, &acc); err != nil || acc.ID == "" || acc.Config == "" {
		return nil, errors.New("файл аккаунта повреждён")
	}
	return &acc, nil
}

func (h *Helper) saveAccount(acc *warp.Account) error {
	raw, err := json.Marshal(acc)
	if err != nil {
		return err
	}
	tmp := h.accountPath() + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, h.accountPath())
}

// unregister deletes the account at Cloudflare and the file. If Cloudflare does not answer the file goes anyway: an account
// that nobody uses expires by itself, and a copy of its key must not stay on the disk.
func (h *Helper) unregister(ctx context.Context) {
	acc, err := h.loadAccount()
	if err != nil {
		os.Remove(h.accountPath())
		return
	}
	if err := warp.Unregister(ctx, acc.ID, acc.Token); err != nil {
		h.logf("удалить аккаунт WARP не вышло: %v", err)
	}
	os.Remove(h.accountPath())
}

// secureDir creates the folder and gives it to the system and the administrators only.
func secureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString("D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}
