//go:build windows

package main

import (
	"context"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/notice"
)

// dnsReach is what is known of whether the provider answers in this network. The question is asked in the background, never while the page
// is drawn: each address gets two seconds, and the internet itself four.
type dnsReach struct {
	mu       sync.Mutex
	provider string
	at       time.Time
	text     string
	asking   bool
	told     bool // the notification has been shown for as long as the warning lasts
}

const dnsReachKeep = 2 * time.Minute

// unreachableWarning is the warning of a network that lets no DNS through but its own, or "" (see dnsx.UnreachableWarning). The first call
// for a provider starts the question and answers "" until it is answered.
func (a *App) unreachableWarning(p dnsx.Provider) string {
	r := &a.reach
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.provider != p.ID {
		r.provider, r.at, r.text, r.told = p.ID, time.Time{}, "", false
	}
	if !r.asking && time.Since(r.at) > dnsReachKeep {
		r.asking = true
		goSafe("проверка DNS провайдера в этой сети", func() { a.askReach(p) })
	}
	return r.text
}

func (a *App) askReach(p dnsx.Provider) {
	answers := false
	for _, address := range p.Addresses {
		if providerAnswers(address) {
			answers = true
			break
		}
	}
	internet := false
	if !answers {
		internet = internetWorks()
	}
	text := dnsx.UnreachableWarning(p.Name, answers, internet)
	r := &a.reach
	r.mu.Lock()
	r.asking, r.at = false, time.Now()
	if r.provider == p.ID {
		r.text = text
	}
	tell := text != "" && !r.told
	if text == "" {
		r.told = false
	} else {
		r.told = true
	}
	r.mu.Unlock()
	if text != "" {
		logLine("DNS: " + strings.TrimSuffix(text, " Выключите «Нейросети» или смените сеть."))
	}
	// Once for as long as it lasts, and again when it comes back after a time of working (as on the Mac).
	if tell && !a.settings.get().UpdateNotifyOff {
		balloon(notice.DNSTag, 3, "В этой сети DNS Nimb не отвечает", "Адреса могут не открываться. Откройте Nimb и выключите «Нейросети».")
	}
}

// providerAnswers asks one address of the provider for a name, straight to it.
func providerAnswers(address string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{Timeout: 2 * time.Second}).DialContext(ctx, "udp", net.JoinHostPort(address, "53"))
	}}
	ips, err := resolver.LookupHost(ctx, "example.com")
	return err == nil && len(ips) > 0
}

// internetWorks asks Cloudflare by its address, with no DNS: any answer of the server counts.
func internetWorks() bool {
	client := &http.Client{Timeout: 4 * time.Second, Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true, DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext}}
	resp, err := client.Get("https://1.1.1.1/")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}
