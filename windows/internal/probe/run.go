package probe

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

// The limits are the ones of the Mac app: 2 seconds for a DNS server, 3 for a connection, 6 for a whole request.
const (
	dnsTimeout     = 2 * time.Second
	connectTimeout = 3 * time.Second
	requestTimeout = 6 * time.Second
	perProvider    = 16 // the same per-provider limit as macOS; no shared queue behind a slow provider
)

// Prober runs the check. The zero value is the real thing; the fields are for tests.
type Prober struct {
	DNSPort   string                                           // "53"
	HTTPSPort string                                           // "443"
	RootCAs   *x509.CertPool                                   // nil: the system's
	loopback  bool                                             // keep 127.x answers (a test server)
	lookup    func(context.Context, string, []string) []string // nil: real DNS
	fetch     func(context.Context, Target, string) Outcome    // nil: real HTTPS
}

// Run checks every provider, one report for each, in the order of providers. progress is told how many of the requests are done
// (total is 0 while the addresses are still being asked for). It does not touch the DNS of the system.
func (p *Prober) Run(ctx context.Context, providers []dnsx.Provider, progress func(done, total int)) []ProviderReport {
	type pair struct {
		provider int
		target   Target
	}
	var pairs []pair
	for i := range providers {
		for _, t := range All {
			pairs = append(pairs, pair{i, t})
		}
	}
	progress(0, 0)
	resolve, request := p.resolve, p.request
	if p.lookup != nil {
		resolve = p.lookup
	}
	if p.fetch != nil {
		request = p.fetch
	}

	// Each provider has its own HTTPS workers. Resolve and request overlap: a silent DNS must not delay all healthy providers.
	type job struct {
		pair, sample int
		address      string
	}
	samples := make([][]Sample, len(pairs))
	queues := make([]chan job, len(providers))
	var workers sync.WaitGroup
	var mu sync.Mutex
	resolved, total, done := 0, 0, 0
	for provider := range providers {
		queue := make(chan job, perProvider)
		queues[provider] = queue
		for worker := 0; worker < perProvider; worker++ {
			workers.Go(func() {
				for j := range queue {
					target := pairs[j.pair].target
					out := Outcome{Status: Failed, Reason: "DNS: не получен IPv4-адрес"}
					if ctx.Err() != nil {
						out.Reason = "Проверка: отменена или истекло общее время ожидания"
					}
					if j.address != "" && ctx.Err() == nil {
						out = request(ctx, target, j.address)
						if out.Status == Failed && ctx.Err() == nil {
							out = request(ctx, target, j.address)
						}
					}
					samples[j.pair][j.sample] = Sample{Target: target, Address: j.address, Outcome: out}
					mu.Lock()
					done++
					if resolved == len(pairs) {
						progress(done, total)
					}
					mu.Unlock()
				}
			})
		}
	}
	eachInLanes(len(pairs), len(providers), func(i int) int { return pairs[i].provider }, func(i int) {
		pr := pairs[i]
		addresses := resolve(ctx, pr.target.Host, providers[pr.provider].Addresses)
		if len(addresses) == 0 {
			addresses = []string{""}
		}
		samples[i] = make([]Sample, len(addresses))
		mu.Lock()
		total += len(addresses)
		resolved++
		if resolved == len(pairs) {
			progress(done, total)
		}
		mu.Unlock()
		for j, address := range addresses {
			queues[pr.provider] <- job{i, j, address}
		}
	})
	for _, queue := range queues {
		close(queue)
	}
	workers.Wait()

	reports := make([]ProviderReport, len(providers))
	for i := range providers {
		reports[i].Provider = providers[i]
	}
	for i, pr := range pairs {
		reports[pr.provider].Samples = append(reports[pr.provider].Samples, samples[i]...)
	}
	return reports
}

// eachInLanes limits each provider separately, so a large or slow pool cannot occupy another provider's slots.
func eachInLanes(n, lanes int, laneOf func(int) int, f func(int)) {
	indices := make([][]int, lanes)
	for i := 0; i < n; i++ {
		lane := laneOf(i)
		indices[lane] = append(indices[lane], i)
	}
	var wg sync.WaitGroup
	for _, lane := range indices {
		jobs := make(chan int, len(lane))
		for _, i := range lane {
			jobs <- i
		}
		close(jobs)
		for worker := 0; worker < min(perProvider, len(lane)); worker++ {
			wg.Go(func() {
				for i := range jobs {
					f(i)
				}
			})
		}
	}
	wg.Wait()
}

// Resolve is resolve for other programs: the IPv4 addresses that the servers give for host (the first server that answers).
func (p *Prober) Resolve(ctx context.Context, host string, servers []string) []string {
	return p.resolve(ctx, host, servers)
}

// resolve gives the IPv4 answers of the provider's own DNS server for host; the second server is a fallback.
func (p *Prober) resolve(ctx context.Context, host string, servers []string) []string {
	port := or(p.DNSPort, "53")
	for attempt := 0; attempt < 2 && ctx.Err() == nil; attempt++ {
		for _, server := range servers {
			server := net.JoinHostPort(server, port)
			r := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
				return (&net.Dialer{Timeout: dnsTimeout}).DialContext(ctx, network, server)
			}}
			c, cancel := context.WithTimeout(ctx, dnsTimeout)
			ips, err := r.LookupNetIP(c, "ip4", host+".")
			cancel()
			if err != nil {
				continue
			}
			var out []string
			for _, ip := range ips {
				if a := ip.Unmap().String(); p.usable(a) {
					out = append(out, a)
				}
			}
			if len(out) > 0 {
				return out
			}
		}
	}
	return nil
}

func (p *Prober) usable(a string) bool {
	ip := net.ParseIP(a)
	if ip == nil || ip.To4() == nil || ip.IsUnspecified() {
		return false
	}
	return p.loopback || !ip.IsLoopback()
}

// request asks the target at address (the provider's proxy) over HTTPS, with the name of the target for the certificate and the
// Host header, and judges the answer. It does not follow redirects: the place they lead to is part of the answer.
func (p *Prober) request(ctx context.Context, target Target, address string) Outcome {
	ctx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()
	dialer := &net.Dialer{Timeout: connectTimeout}
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, net.JoinHostPort(address, or(p.HTTPSPort, "443")))
		},
		TLSClientConfig:     &tls.Config{ServerName: target.Host, RootCAs: p.RootCAs, MinVersion: tls.VersionTLS12},
		ForceAttemptHTTP2:   true,
		DisableCompression:  true,
		DisableKeepAlives:   true,
		TLSHandshakeTimeout: connectTimeout,
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

	req, err := http.NewRequestWithContext(ctx, "GET", "https://"+target.Host+target.Path, nil)
	if err != nil {
		return Outcome{Status: Failed}
	}
	// The Mac app asks with curl; the same name and nothing else keeps the answers of the two apps comparable.
	req.Header.Set("User-Agent", "curl/8.7.1")
	req.Header.Set("Accept", "*/*")
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		var cert *tls.CertificateVerificationError
		var network net.Error
		reason := "HTTPS: не удалось соединиться с адресом или соединение прервано"
		if errors.As(err, &cert) {
			reason = "TLS: ошибка проверки сертификата"
		} else if errors.As(err, &network) && network.Timeout() {
			reason = "HTTPS: истекло время ожидания соединения или ответа"
		}
		return Outcome{Status: Failed, Reason: reason}
	}
	seconds := time.Since(start).Seconds()
	defer resp.Body.Close()

	headers := map[string]string{}
	for name, values := range resp.Header {
		headers[strings.ToLower(name)] = strings.TrimSpace(values[len(values)-1])
	}
	// A body that does not arrive in time still leaves the answer: the status and the first bytes are what is judged.
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, bigBody+1))
	size := len(raw)
	if size > bigBody {
		raw = raw[:bigBody]
	}
	outcome := Classify(target, resp.StatusCode, seconds, size, headers, string(raw))
	if outcome.Status == Failed {
		outcome.Reason = fmt.Sprintf("HTTP: ответ %d", resp.StatusCode)
	}
	return outcome
}

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
