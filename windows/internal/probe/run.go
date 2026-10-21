package probe

import (
	"context"
	"crypto/tls"
	"crypto/x509"
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
	parallel       = 24 // the requests wait for the network, so more than the cores; few enough not to look like an attack
)

// Prober runs the check. The zero value is the real thing; the fields are for tests.
type Prober struct {
	DNSPort   string         // "53"
	HTTPSPort string         // "443"
	RootCAs   *x509.CertPool // nil: the system's
	loopback  bool           // keep 127.x answers (a test server)
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

	// 1. Ask each provider's DNS for every target.
	resolved := make([][]string, len(pairs))
	each(len(pairs), func(i int) {
		resolved[i] = p.resolve(ctx, pairs[i].target.Host, providers[pairs[i].provider].Addresses)
	})

	// 2. Request every returned address. A target with no usable answer counts as one failure.
	type job struct {
		provider int
		target   Target
		address  string
	}
	var jobs []job
	for i, pr := range pairs {
		if len(resolved[i]) == 0 {
			jobs = append(jobs, job{pr.provider, pr.target, ""})
			continue
		}
		for _, a := range resolved[i] {
			jobs = append(jobs, job{pr.provider, pr.target, a})
		}
	}
	samples := make([]Sample, len(jobs))
	var mu sync.Mutex
	done := 0
	progress(0, len(jobs))
	each(len(jobs), func(i int) {
		j := jobs[i]
		out := Outcome{Status: Failed}
		if j.address != "" {
			out = p.request(ctx, j.target, j.address)
		}
		samples[i] = Sample{Target: j.target, Address: j.address, Outcome: out}
		mu.Lock()
		done++
		n := done
		mu.Unlock()
		progress(n, len(jobs))
	})

	reports := make([]ProviderReport, len(providers))
	for i := range providers {
		reports[i].Provider = providers[i]
	}
	for i, j := range jobs {
		reports[j.provider].Samples = append(reports[j.provider].Samples, samples[i])
	}
	return reports
}

// each runs f for 0..n-1, a limited number at a time, and waits for all.
func each(n int, f func(i int)) {
	var wg sync.WaitGroup
	slots := make(chan struct{}, parallel)
	for i := 0; i < n; i++ {
		wg.Add(1)
		slots <- struct{}{}
		go func() {
			defer func() { <-slots; wg.Done() }()
			f(i)
		}()
	}
	wg.Wait()
}

// resolve gives the IPv4 answers of the provider's own DNS server for host; the second server is a fallback.
func (p *Prober) resolve(ctx context.Context, host string, servers []string) []string {
	port := or(p.DNSPort, "53")
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
		return Outcome{Status: Failed}
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
	return Classify(target, resp.StatusCode, seconds, size, headers, string(raw))
}

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
