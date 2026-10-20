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

	if err := h.dnsRestore(); err != nil {
		problems = append(problems, err.Error())
	}
	if adapters, err := dnsx.Adapters(); err == nil {
		for _, a := range adapters {
			for _, p := range dnsx.Providers {
				if dnsx.Same(a.NameServer, p.Servers()) {
					logf("cleanup: %q still had %s, given back to the network", a.Name, p.ID)
					a.NameServer = ""
					if err := dnsx.Write(a); err != nil {
						problems = append(problems, fmt.Sprintf("DNS не вернулся на «%s»", a.Name))
					}
				}
			}
		}
		dnsx.Flush()
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	h.unregister(ctx)

	if err := os.RemoveAll(dir); err != nil {
		problems = append(problems, "не удалось удалить папку службы: "+err.Error())
	}
	return problems
}
