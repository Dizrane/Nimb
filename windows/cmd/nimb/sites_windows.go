//go:build windows

package main

import (
	"context"
	"sync"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/sitecheck"
)

// siteState is the check of YouTube and Discord: whether it is going on and what the last one found.
type siteState struct {
	mu      sync.Mutex
	running bool
	checks  []sitecheck.Check
}

// SiteView is the check as the page draws it.
type SiteView struct {
	Running bool             `json:"running"`
	Checks  []sitecheck.View `json:"checks"`
}

func (s *siteState) view() SiteView {
	s.mu.Lock()
	defer s.mu.Unlock()
	v := SiteView{Running: s.running, Checks: []sitecheck.View{}}
	for _, c := range s.checks {
		v.Checks = append(v.Checks, c.View())
	}
	return v
}

// CheckSites asks YouTube and Discord for small answers at several addresses and keeps what came. The requests go out from this
// program, through the tunnel or not, as a browser's do.
func (a *App) CheckSites() Result {
	a.sites.mu.Lock()
	if a.sites.running {
		a.sites.mu.Unlock()
		return Result{Error: "Проверка уже идёт."}
	}
	a.sites.running = true
	a.sites.mu.Unlock()
	goSafe("проверка YouTube и Discord", func() {
		defer func() { a.sites.mu.Lock(); a.sites.running = false; a.sites.mu.Unlock() }()
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
		defer cancel()
		checks := sitecheck.Run(ctx, sitecheck.Targets, sitecheck.Ask)
		a.sites.mu.Lock()
		a.sites.checks = checks
		a.sites.mu.Unlock()
		logLine(sitecheck.Line(checks))
	})
	return Result{OK: true}
}
