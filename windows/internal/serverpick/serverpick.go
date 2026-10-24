// Package serverpick chooses which WARP server the tunnel is started at. The server in the account is reached by the person's provider at one
// city of Cloudflare, and some cities sit behind networks that filter YouTube (seen on the Mac: the endpoint of the account left at Moscow,
// where a TLS handshake to YouTube is dropped, while the other servers of Cloudflare left at Stockholm and YouTube opened). Which city a server
// leaves from depends on the provider, so it cannot be fixed in the program: it is looked for at the start of the tunnel, never while it works
// (a call in Discord must not be cut). It is the port of try_servers and search_server of Resources/nimb-tunnel.sh.
//
// The rules, as on the Mac:
//   - the same keys work at every server, only the address changes (the port stays);
//   - at a start: the server that opened YouTube last time first, then the one of the account; if the one of the account gives no handshake
//     at all, the others are tried before the start fails;
//   - after the handshake: YouTube and Discord are asked through the tunnel. If both answer, nothing more. If one does not and the internet
//     itself works, the other servers are tried one after another and the first at which both answer is kept for the next starts;
//   - if none does, back to the server of the settings, and no new search for ten minutes.
package serverpick

import (
	"context"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Servers are the other WARP addresses to try (the same on the Mac).
var Servers = []string{"162.159.192.1", "188.114.97.1", "188.114.99.1"}

// SearchPause: after a search that found nothing there is no new search for this long (YouTube may be down everywhere, and every start
// would wait for it).
const SearchPause = 10 * time.Minute

// The addresses that are asked through the tunnel.
const (
	ProbeWeb   = "https://www.cloudflare.com/cdn-cgi/trace"
	ProbeVideo = "https://www.youtube.com/generate_204"
	ProbeChat  = "https://discord.com/"
)

// Valid says whether a kept server is one of the known ones (a file that holds anything else is ignored).
func Valid(host string) bool {
	host = strings.TrimSpace(host)
	for _, s := range Servers {
		if s == host {
			return true
		}
	}
	return false
}

// WithHost gives the endpoint "host:port" the address of another server and keeps its port. host "" returns the endpoint as it is.
func WithHost(endpoint, host string) (string, error) {
	if host == "" {
		return endpoint, nil
	}
	_, port, err := net.SplitHostPort(endpoint)
	if err != nil {
		return "", err
	}
	return net.JoinHostPort(host, port), nil
}

// Opens says whether a site answers through the tunnel: any answer of the server counts, since the name and the handshake of TLS went through.
func Opens(ctx context.Context, client *http.Client, url string) bool {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, url, nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

// OpenBoth asks both sites at the same time.
func OpenBoth(ctx context.Context, client *http.Client, a, b string) bool {
	var wg sync.WaitGroup
	var okA, okB bool
	wg.Add(2)
	go func() { defer wg.Done(); okA = Opens(ctx, client, a) }()
	go func() { defer wg.Done(); okB = Opens(ctx, client, b) }()
	wg.Wait()
	return okA && okB
}

// Steps are what the choice needs from the program; tests put their own.
type Steps struct {
	// BringUp takes the tunnel that is up down and starts one at the server host ("" is the server of the settings). It says why it did not
	// work. NoAnswer tells the error of a start that got no handshake.
	BringUp  func(host string) error
	NoAnswer func(err error) bool
	// Web: the internet itself works through the tunnel. Opens: YouTube and Discord both open through it.
	Web, Opens func() bool
	// Saved reads the server that was kept ("" when none); Save keeps one ("" forgets it).
	Saved func() string
	Save  func(host string)
	// SearchedAt reads when the last search found nothing (zero: never); MarkSearched writes it, a zero time clears it.
	SearchedAt   func() time.Time
	MarkSearched func(time.Time)
	Now          func() time.Time
	Log          func(format string, args ...any)
}

// Start brings the tunnel up at the right server and says which one it is ("" is the server of the settings). search says whether the
// search for a server that opens YouTube is allowed (it is not at a restart that the service itself makes after the program of the tunnel ended:
// that is quick and does not search).
func Start(s Steps, search bool) (current string, err error) {
	saved := s.Saved()
	started := false
	if saved != "" {
		if e := s.BringUp(saved); e == nil {
			started, current = true, saved
		} else {
			s.Log("сервер %s не ответил: пробую сервер из настроек", saved)
		}
	}
	if !started {
		e := s.BringUp("")
		switch {
		case e == nil:
			started, current = true, ""
		case search && s.NoAnswer(e):
			// No handshake at all: the network may close this address. The others are tried before the start fails (and a start that
			// fails counts towards new keys elsewhere; keys that are fine must not be thrown away).
			for _, cand := range Servers {
				if cand == saved {
					continue
				}
				if s.BringUp(cand) == nil {
					started, current = true, cand
					s.Save(cand)
					s.Log("сервер %s отвечает, а сервер из настроек нет", cand)
					break
				}
			}
			if !started {
				return "", e
			}
		default:
			return "", e
		}
	}
	if !search {
		return current, nil
	}
	return searchServer(s, current)
}

// searchServer looks, after a start, for a server that opens YouTube and Discord when the one that is up does not.
func searchServer(s Steps, current string) (string, error) {
	if !s.Web() || s.Opens() {
		return current, nil
	}
	if last := s.SearchedAt(); !last.IsZero() && s.Now().Sub(last) < SearchPause {
		return current, nil
	}
	name := func(h string) string {
		if h == "" {
			return "из настроек"
		}
		return h
	}
	s.Log("сервер %s не открывает YouTube или Discord, пробую другие", name(current))
	saved := s.Saved()
	candidates := append([]string(nil), Servers...)
	if saved != "" { // the one of the settings is a candidate too, once a kept server has been in use
		candidates = append(candidates, "")
	}
	for _, cand := range candidates {
		if cand == current {
			continue
		}
		if s.BringUp(cand) != nil {
			continue
		}
		if s.Opens() {
			s.Save(cand) // "" forgets the kept one
			s.MarkSearched(time.Time{})
			s.Log("сервер %s открывает YouTube и Discord", name(cand))
			return cand, nil
		}
	}
	// None does: back where it was (the kept server, or the one of the settings), and no new search for ten minutes.
	s.Log("ни один сервер не открывает YouTube и Discord: возвращаю %s", name(saved))
	s.MarkSearched(s.Now())
	if err := s.BringUp(saved); err != nil {
		if saved != "" && s.BringUp("") == nil {
			return "", nil // the kept one stopped answering: the one of the settings
		}
		return "", err
	}
	return saved, nil
}
