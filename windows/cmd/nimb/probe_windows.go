//go:build windows

package main

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/browserdns"
	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/ipc"
	"github.com/Dizrane/Nimb/windows/internal/probe"
)

// probeKeep is how long the result of a check is good for a report: the report does not run it again within this time.
const probeKeep = 10 * time.Minute

// probeState is the check of the providers: what is going on and the last result.
type probeState struct {
	mu      sync.Mutex
	running bool
	phase   string // "addresses" while the DNS of the providers is asked, "requests", "enabling"
	done    int
	total   int
	reports []probe.ProviderReport
	at      time.Time
}

// ProbeView is the check as the page draws it.
type ProbeView struct {
	Running bool                 `json:"running"`
	Phase   string               `json:"phase"`
	Done    int                  `json:"done"`
	Total   int                  `json:"total"`
	Reports []probe.ProviderView `json:"reports"`
	Best    string               `json:"best"` // the provider to recommend: the best one, if any service works through it
}

func (p *probeState) view() ProbeView {
	p.mu.Lock()
	defer p.mu.Unlock()
	v := ProbeView{Running: p.running, Phase: p.phase, Done: p.done, Total: p.total, Reports: []probe.ProviderView{}}
	for _, r := range p.reports {
		v.Reports = append(v.Reports, r.View())
	}
	if best := probe.Best(p.reports); best != nil && best.WorkingCount() > 0 {
		v.Best = best.Provider.ID
	}
	return v
}

// ProbeStart starts the check of every provider (without touching the DNS of the system). The page reads the progress from the state.
func (a *App) ProbeStart() Result { return a.startProbe(false) }

// EnableBest is the one button of the first setup: it checks every provider, takes the best one and turns Smart DNS on with it.
func (a *App) EnableBest() Result { return a.startProbe(true) }

func (a *App) startProbe(enable bool) Result {
	a.probe.mu.Lock()
	if a.probe.running {
		a.probe.mu.Unlock()
		return Result{Error: "Проверка уже идёт."}
	}
	a.probe.running, a.probe.phase, a.probe.done, a.probe.total, a.probe.reports = true, "addresses", 0, 0, nil
	a.probe.mu.Unlock()
	goSafe("проверка DNS", func() { a.runProbe(enable) })
	return Result{OK: true}
}

func (a *App) runProbe(enable bool) {
	reports := a.runProbeOnce(context.Background(), func(done, total int) {
		a.probe.mu.Lock()
		a.probe.done, a.probe.total = done, total
		if total > 0 {
			a.probe.phase = "requests"
		}
		a.probe.mu.Unlock()
	})
	best := probe.Best(reports)
	a.probe.mu.Lock()
	a.probe.reports, a.probe.at = reports, time.Now()
	if enable {
		a.probe.phase = "enabling"
	} else {
		a.probe.running = false
	}
	a.probe.mu.Unlock()
	for _, r := range reports {
		m, _ := r.Median()
		logLine(fmt.Sprintf("проверка DNS: %s (%s) работает %d из %d, медиана %.2f с", r.Provider.Name, r.Provider.ID, r.WorkingCount(), len(probe.Services()), m))
	}
	if !enable {
		return
	}
	defer func() { a.probe.mu.Lock(); a.probe.running = false; a.probe.mu.Unlock() }()
	if best != nil && best.WorkingCount() > 0 {
		a.settings.update(func(s *Settings) { s.Provider = best.Provider.ID })
	}
	// As on the Mac: with no provider that works the chosen one is turned on all the same, and it moves to the best one when it is on.
	a.SetProvider(a.settings.get().Provider)
	if resp, err := callService(ipc.Request{Cmd: ipc.Status}); err == nil && resp.DNS != nil && resp.DNS.Active {
		return
	}
	a.SetAI(true)
}

// runProbeOnce asks every provider; the whole check is cut off after two minutes.
func (a *App) runProbeOnce(ctx context.Context, progress func(done, total int)) []probe.ProviderReport {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	return (&probe.Prober{}).Run(ctx, dnsx.Providers, progress)
}

// reportsForReport are the results of a check that is not older than probeKeep, or a new one (for a report about a problem the
// providers are asked at once: the person has not had to press anything).
func (a *App) probeForReport() []probe.ProviderReport {
	a.probe.mu.Lock()
	if !a.probe.running && len(a.probe.reports) > 0 && time.Since(a.probe.at) < probeKeep {
		r := a.probe.reports
		a.probe.mu.Unlock()
		return r
	}
	busy := a.probe.running
	a.probe.mu.Unlock()
	if busy {
		return nil
	}
	reports := a.runProbeOnce(context.Background(), func(int, int) {})
	a.probe.mu.Lock()
	if !a.probe.running {
		a.probe.reports, a.probe.at = reports, time.Now()
	}
	a.probe.mu.Unlock()
	return reports
}

// browserHint is the line about Firefox (or ""), read from the disk at most once a minute.
func (a *App) browserHint() string {
	a.hintMu.Lock()
	defer a.hintMu.Unlock()
	if time.Since(a.hintAt) > time.Minute {
		a.hint, a.hintAt = browserdns.Current(), time.Now()
	}
	return a.hint
}
