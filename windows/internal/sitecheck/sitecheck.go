// Package sitecheck asks YouTube and Discord for small answers at several addresses each and reports what came: the port of
// SiteChecker.swift, SiteProbe.swift and SiteCheck.swift of the Mac app. The requests go out from the program itself, through the
// tunnel or not, as a browser's do. All of them go out at once, and each address is tried by several connections at a time, the way a
// browser does: through the tunnel, Cloudflare leaves part of the connections to Google's sites without an answer (measured at about
// every second one), so a single connection that fails is not an outage.
package sitecheck

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Target is a site and the addresses that are asked for it.
type Target struct {
	Name   string
	Probes []Address
}

// Address is one thing that is asked: what it is called and where it is.
type Address struct{ Name, URL string }

// Targets are what is asked, the same as on the Mac.
var Targets = []Target{
	{"YouTube", []Address{
		{"Сайт", "https://www.youtube.com/"},
		{"Проверочный адрес", "https://www.youtube.com/generate_204"},
		{"Картинки", "https://i.ytimg.com/"},
		{"Видео", "https://redirector.googlevideo.com/"},
	}},
	{"Discord", []Address{
		{"Сайт", "https://discord.com/"},
		{"Служебный адрес", "https://discord.com/api/v9/gateway"},
		{"Файлы", "https://cdn.discordapp.com/"},
		{"Сообщения", "https://gateway.discord.gg/"},
	}},
}

// Probe is one request to one address of a site, and what came of it.
type Probe struct {
	Name, URL string
	Code      int // the answer of the server, 0 if there was none
	Seconds   float64
	Failure   string // why there was no answer, in words
}

// Answered: the server answered with something other than an error of its own: the site is reachable.
func (p Probe) Answered() bool { return p.Failure == "" && p.Code >= 200 && p.Code < 500 }

// Host is the name of the server of the address.
func (p Probe) Host() string {
	if u, err := url.Parse(p.URL); err == nil && u.Host != "" {
		return u.Hostname()
	}
	return p.URL
}

// Summary is the line shown next to the name.
func (p Probe) Summary() string {
	if p.Failure != "" {
		return p.Failure
	}
	if p.Answered() {
		return fmt.Sprintf("ответ %d · %s с", p.Code, tenth(p.Seconds))
	}
	return fmt.Sprintf("ответ %d (ошибка сервера)", p.Code)
}

// tenth writes seconds with one digit after the comma, as the Mac does.
func tenth(s float64) string { return strings.Replace(fmt.Sprintf("%.1f", s), ".", ",", 1) }

// Verdict is how a site did.
type Verdict string

const (
	Works   Verdict = "works"
	Partial Verdict = "partial"
	Down    Verdict = "down"
)

// Check is a site as several probes: the page, an address that answers with nothing, the files and videos. One slow answer is not an
// outage, so the verdict looks at all of them.
type Check struct {
	Name   string
	Probes []Probe
}

// Answered is how many of the probes were answered.
func (c Check) Answered() int {
	n := 0
	for _, p := range c.Probes {
		if p.Answered() {
			n++
		}
	}
	return n
}

// Verdict: all answered is works, none is down, anything between is partial.
func (c Check) Verdict() Verdict {
	switch n := c.Answered(); {
	case n == len(c.Probes):
		return Works
	case n == 0:
		return Down
	default:
		return Partial
	}
}

// Median is the median time of the answers that came; ok is false when none did.
func (c Check) Median() (seconds float64, ok bool) {
	var times []float64
	for _, p := range c.Probes {
		if p.Answered() {
			times = append(times, p.Seconds)
		}
	}
	if len(times) == 0 {
		return 0, false
	}
	slices.Sort(times)
	return times[len(times)/2], true
}

// Result is the line of the verdict: "открывается 0,4 с", "частично: 3 из 4", "не отвечает".
func (c Check) Result() string {
	switch c.Verdict() {
	case Works:
		if m, ok := c.Median(); ok {
			return "открывается " + tenth(m) + " с"
		}
		return "открывается"
	case Partial:
		return fmt.Sprintf("частично: %d из %d", c.Answered(), len(c.Probes))
	}
	return "не отвечает"
}

// ProbeView and View are what the page draws.
type ProbeView struct {
	Name     string `json:"name"`
	Host     string `json:"host"`
	Answered bool   `json:"answered"`
	Summary  string `json:"summary"`
}

type View struct {
	Name    string      `json:"name"`
	Verdict Verdict     `json:"verdict"`
	Result  string      `json:"result"`
	Probes  []ProbeView `json:"probes"`
}

// View is the check as the page draws it.
func (c Check) View() View {
	v := View{Name: c.Name, Verdict: c.Verdict(), Result: c.Result(), Probes: []ProbeView{}}
	for _, p := range c.Probes {
		v.Probes = append(v.Probes, ProbeView{Name: p.Name, Host: p.Host(), Answered: p.Answered(), Summary: p.Summary()})
	}
	return v
}

// Line is the checks as one line of the log: "проверка: YouTube открывается 0,4 с; Discord частично: 3 из 4".
func Line(checks []Check) string {
	var parts []string
	for _, c := range checks {
		parts = append(parts, c.Name+" "+c.Result())
	}
	return "проверка: " + strings.Join(parts, "; ")
}

// Reason says in words why a request got no answer.
func Reason(err error) string {
	var dns *net.DNSError
	var cert *tls.CertificateVerificationError
	var record tls.RecordHeaderError
	switch {
	case errors.As(err, &dns):
		if dns.IsTimeout {
			return "время ожидания вышло"
		}
		return "не нашлось адреса сайта"
	case errors.Is(err, context.DeadlineExceeded) || isTimeout(err):
		return "время ожидания вышло"
	case errors.As(err, &cert) || errors.As(err, &record) || strings.Contains(err.Error(), "tls:") || strings.Contains(err.Error(), "x509:"):
		return "ошибка защищённого соединения"
	case errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNABORTED) ||
		strings.Contains(err.Error(), "forcibly closed") || strings.Contains(err.Error(), "connection reset"):
		return "соединение оборвалось"
	case errors.Is(err, syscall.ECONNREFUSED) || strings.Contains(err.Error(), "dial") || strings.Contains(err.Error(), "connect"):
		return "не удалось соединиться"
	}
	return "ошибка проверки"
}

func isTimeout(err error) bool {
	var t interface{ Timeout() bool }
	return errors.As(err, &t) && t.Timeout()
}

// Connections tried at once for one address, and how many times that is repeated while none of them has answered.
const (
	attempts = 4
	rounds   = 2
)

// Doer sends a request; *http.Client is one. The tests make their own.
type Doer func(ctx context.Context, address string) Probe

// Run asks every target; the checks come in the order of the targets.
func Run(ctx context.Context, targets []Target, ask Doer) []Check {
	checks := make([]Check, len(targets))
	var wg sync.WaitGroup
	for i, t := range targets {
		checks[i] = Check{Name: t.Name, Probes: make([]Probe, len(t.Probes))}
		for j, a := range t.Probes {
			wg.Add(1)
			go func() {
				defer wg.Done()
				checks[i].Probes[j] = answer(ctx, a, ask)
			}()
		}
	}
	wg.Wait()
	return checks
}

// answer is the fastest answer of a round of simultaneous connections; the next round only if none of them answered.
func answer(ctx context.Context, a Address, ask Doer) Probe {
	failed := Probe{Name: a.Name, URL: a.URL, Failure: "нет ответа"}
	for r := 0; r < rounds; r++ {
		results := make([]Probe, attempts)
		var wg sync.WaitGroup
		for k := range results {
			wg.Add(1)
			go func() {
				defer wg.Done()
				p := ask(ctx, a.URL)
				p.Name, p.URL = a.Name, a.URL
				results[k] = p
			}()
		}
		wg.Wait()
		var best *Probe
		for k := range results {
			if results[k].Answered() && (best == nil || results[k].Seconds < best.Seconds) {
				best = &results[k]
			}
		}
		if best != nil {
			return *best
		}
		failed = results[0]
	}
	return failed
}

// Ask is the real request: 8 seconds for all of it, 5 to connect, no redirect followed (the answer of the first server is the answer).
func Ask(ctx context.Context, address string) Probe {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	tr := &http.Transport{DialContext: (&net.Dialer{Timeout: 5 * time.Second}).DialContext, TLSHandshakeTimeout: 5 * time.Second, DisableKeepAlives: true,
		ForceAttemptHTTP2: true, Proxy: http.ProxyFromEnvironment}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, err := http.NewRequestWithContext(ctx, "GET", address, nil)
	if err != nil {
		return Probe{Failure: "ошибка проверки"}
	}
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return Probe{Seconds: time.Since(start).Seconds(), Failure: Reason(err)}
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 256<<10))
	return Probe{Code: resp.StatusCode, Seconds: time.Since(start).Seconds()}
}
