//go:build windows

// nimb-svc is the service of Nimb on Windows (the "NimbHelper" service, running as the system). The installer registers it
// once, and after that the window of Nimb can switch the tunnel without asking for administrator rights every time.
//
//	nimb-svc install    register and start the service (administrator)
//	nimb-svc uninstall  stop and remove the service (administrator)
//	nimb-svc run        run in this console, for debugging (administrator)
//	nimb-svc cleanup    after uninstall: give the DNS back, delete the account at Cloudflare, remove the data and the driver (administrator)
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
	"golang.zx2c4.com/wintun"

	"github.com/Dizrane/Nimb/windows/internal/helper"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
	"github.com/Dizrane/Nimb/windows/internal/logfile"
)

const serviceName = "NimbHelper"

func main() {
	if isService, err := svc.IsWindowsService(); err == nil && isService {
		if err := svc.Run(serviceName, &service{}); err != nil {
			os.Exit(1)
		}
		return
	}
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: nimb-svc install | uninstall | run")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "install":
		err = install()
	case "uninstall":
		err = uninstall()
	case "cleanup":
		err = cleanup()
	case "run":
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
		defer stop()
		err = serve(ctx, log.Printf)
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

type service struct{}

func (s *service) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	logf, closeLog := openLog()
	defer closeLog()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- serve(ctx, logf) }()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case req := <-requests:
			switch req.Cmd {
			case svc.Interrogate:
				status <- req.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				cancel()
				<-done
				return false, 0
			}
		case err := <-done:
			cancel()
			if err != nil {
				logf("служба остановилась с ошибкой: %v", err)
				return false, 1
			}
			return false, 0
		}
	}
}

// serve answers the window until the context ends, then takes the tunnel down.
func serve(ctx context.Context, logf func(string, ...any)) error {
	h, err := helper.New(helper.DataDir(), logf)
	if err != nil {
		return err
	}
	defer h.Close()
	l, err := ipc.Listen()
	if err != nil {
		return fmt.Errorf("не удалось открыть канал: %w", err)
	}
	logf("служба запущена")
	err = ipc.Serve(ctx, l, h)
	logf("служба останавливается")
	return err
}

// openLog writes to a file in the data folder. The log of the last run of the service is put aside as the previous one, so that this file holds
// this run only; a run that writes a lot has it cut to its last lines when it passes a megabyte. It never gets keys.
func openLog() (func(string, ...any), func()) {
	// On a first install the folder does not exist yet (the helper makes it, and closes it to the users, a moment later); without this the
	// log could not be opened and the service would write none until its next start.
	os.MkdirAll(helper.DataDir(), 0o700)
	path := filepath.Join(helper.DataDir(), "service.log")
	logfile.Rotate(path)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return func(string, ...any) {}, func() {}
	}
	var mu sync.Mutex
	writes := 0
	return func(format string, args ...any) {
			mu.Lock()
			defer mu.Unlock()
			fmt.Fprintf(f, "%s  %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
			if writes++; writes%200 == 0 {
				f.Close() // Windows cannot rewrite a file that is open in this way
				logfile.TrimIfOver(path, 1<<20, 2000)
				f, _ = os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
			}
		}, func() {
			mu.Lock()
			defer mu.Unlock()
			if f != nil {
				f.Close()
			}
		}
}

// cleanup is called by the uninstaller after the service is removed.
func cleanup() error {
	logf := func(format string, args ...any) { fmt.Printf(format+"\n", args...) }
	problems := helper.Cleanup(helper.DataDir(), logf)
	// The driver of the adapter (wintun) stays in the system after the program is gone; it is removed here, with its DLL, which sits next to this file.
	if err := wintun.Uninstall(); err != nil {
		fmt.Println("driver:", err)
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	fmt.Println("cleaned")
	return nil
}

func install() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("нужны права администратора: %w", err)
	}
	defer m.Disconnect()
	if s, err := m.OpenService(serviceName); err == nil {
		// An update: the service stays, it only points at the new file; it is started again if it is not running.
		defer s.Close()
		cfg, err := s.Config()
		if err != nil {
			return err
		}
		cfg.BinaryPathName = `"` + exe + `"`
		if err := s.UpdateConfig(cfg); err != nil {
			return err
		}
		if st, err := s.Query(); err == nil && st.State == svc.Stopped {
			if err := s.Start(); err != nil {
				return fmt.Errorf("служба обновлена, но не запустилась: %w", err)
			}
		}
		fmt.Println("service updated")
		return nil
	}
	s, err := m.CreateService(serviceName, exe, mgr.Config{
		DisplayName: "Nimb: помощник",
		Description: "Включает и выключает туннель Nimb, чтобы окну Nimb не нужны были права администратора при каждом переключении.",
		StartType:   mgr.StartAutomatic,
	})
	if err != nil {
		return err
	}
	defer s.Close()
	// If it falls, it gets up again.
	s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
	}, 86400)
	if err := s.Start(); err != nil {
		return fmt.Errorf("служба установлена, но не запустилась: %w", err)
	}
	fmt.Println("service installed and started")
	return nil
}

func uninstall() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("нужны права администратора: %w", err)
	}
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return fmt.Errorf("служба %s не установлена", serviceName)
	}
	defer s.Close()
	if st, err := s.Query(); err == nil && st.State != svc.Stopped {
		s.Control(svc.Stop)
		for i := 0; i < 40; i++ {
			if st, err := s.Query(); err != nil || st.State == svc.Stopped {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
	}
	if err := s.Delete(); err != nil {
		return err
	}
	fmt.Println("service removed")
	return nil
}
