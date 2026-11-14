//go:build windows

package helper

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

// Cleanup is what the uninstaller asks for once the service is stopped: the DNS of the adapters goes back, the anonymous account
// at Cloudflare is deleted, and the folder of the service is removed. It returns what did not work, so that the person can be told.
//
// DNS comes back from the backup. If the backup is gone (a damaged disk, a hand-made cleanup), the adapters that still have the
// servers of one of our providers are given back to the network, because nobody else would ever do it.
func Cleanup(dir string, logf func(string, ...any)) (problems []string) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	h := &Helper{dir: dir, logf: logf, started: time.Now()}
	h.backup = h.loadBackup()
	hadBackup := h.backup != nil

	if err := h.dnsRestore(); err != nil {
		return []string{err.Error()} // The uninstaller must stop, keeping the installation available for a retry.
	}
	if !hadBackup {
		adapters, err := dnsx.RestoreAdapters()
		if err != nil {
			return []string{"не удалось проверить DNS: " + err.Error()}
		}
		for _, a := range adapters {
			for _, p := range dnsx.Providers {
				if p.Matches(a.NameServer) {
					logf("cleanup: %q still had %s, given back to the network", a.Name, p.ID)
					a.NameServer = ""
					if err := dnsx.Write(a); err != nil {
						problems = append(problems, fmt.Sprintf("DNS не вернулся на «%s»", a.Name))
					}
					if dnsx.Same6(a.NameServer6, p.Servers6()) {
						a.NameServer6 = ""
						if err := h.write6Checked(a); err != nil {
							problems = append(problems, err.Error())
						}
					}
				}
			}
		}
		dnsx.Flush()
	}

	if len(problems) > 0 {
		return problems
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	h.unregister(ctx)

	if err := os.RemoveAll(dir); err != nil {
		problems = append(problems, "не удалось удалить папку службы: "+err.Error())
	}
	return problems
}
