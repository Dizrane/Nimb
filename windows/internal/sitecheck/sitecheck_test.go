package sitecheck

import (
	"context"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
)

func probe(code int, failure string, seconds float64) Probe {
	return Probe{Name: "p", URL: "https://example.test/", Code: code, Seconds: seconds, Failure: failure}
}

func TestAProbeAnswersWithAnythingButAServerError(t *testing.T) {
	for code, want := range map[int]bool{200: true, 204: true, 301: true, 403: true, 404: true, 499: true, 500: false, 503: false, 199: false, 0: false} {
		if got := probe(code, "", 0.4).Answered(); got != want {
			t.Errorf("code %d: %v, want %v", code, got, want)
		}
	}
	if probe(200, "время ожидания вышло", 0.4).Answered() {
		t.Error("a failure is not an answer, whatever the code says")
	}
}

func TestAllAnsweredWorks(t *testing.T) {
	c := Check{Name: "YouTube", Probes: []Probe{probe(200, "", 0.2), probe(204, "", 0.4), probe(301, "", 0.6)}}
	if c.Verdict() != Works || c.Result() != "открывается 0,4 с" {
		t.Errorf("%s %q", c.Verdict(), c.Result())
	}
}

func TestSomeAnsweredIsPartial(t *testing.T) {
	c := Check{Name: "YouTube", Probes: []Probe{probe(200, "", 0.2), probe(0, "x", 0), probe(204, "", 0.4)}}
	if c.Verdict() != Partial || c.Result() != "частично: 2 из 3" {
		t.Errorf("%s %q", c.Verdict(), c.Result())
	}
}

func TestNoneAnsweredIsDown(t *testing.T) {
	c := Check{Name: "Discord", Probes: []Probe{probe(0, "a", 0), probe(500, "", 0.1)}}
	if c.Verdict() != Down || c.Result() != "не отвечает" {
		t.Errorf("%s %q", c.Verdict(), c.Result())
	}
}

func TestTheTimeIsTheMedianOfTheAnswers(t *testing.T) {
	c := Check{Probes: []Probe{probe(200, "", 0.2), probe(200, "", 3.0), probe(200, "", 0.4), probe(0, "x", 9)}}
	if m, ok := c.Median(); !ok || m != 0.4 {
		t.Errorf("median %v %v", m, ok)
	}
	if _, ok := (Check{Probes: []Probe{probe(0, "x", 1)}}).Median(); ok {
		t.Error("no answers, no median")
	}
}

func TestTheSummaryOfAProbe(t *testing.T) {
	for _, c := range []struct {
		p    Probe
		want string
	}{
		{probe(200, "", 0.44), "ответ 200 · 0,4 с"},
		{probe(500, "", 0.1), "ответ 500 (ошибка сервера)"},
		{probe(0, "не удалось соединиться", 0), "не удалось соединиться"},
	} {
		if got := c.p.Summary(); got != c.want {
			t.Errorf("%q, want %q", got, c.want)
		}
	}
	if (Probe{URL: "https://i.ytimg.com/x"}).Host() != "i.ytimg.com" {
		t.Error("host")
	}
}

func TestTheLineOfTheLog(t *testing.T) {
	got := Line([]Check{
		{Name: "YouTube", Probes: []Probe{probe(200, "", 0.4)}},
		{Name: "Discord", Probes: []Probe{probe(200, "", 0.4), probe(0, "x", 0)}},
	})
	if got != "проверка: YouTube открывается 0,4 с; Discord частично: 1 из 2" {
		t.Errorf("%q", got)
	}
}

func TestTheTargetsAreTheOnesOfTheMacApp(t *testing.T) {
	raw, err := readMac()
	if err != nil {
		t.Skip("the repository root is not here")
	}
	for _, target := range Targets {
		for _, a := range target.Probes {
			if !strings.Contains(raw, `("`+a.Name+`", "`+a.URL+`")`) {
				t.Errorf("%s %q %s is not in the Mac app", target.Name, a.Name, a.URL)
			}
		}
	}
}

func TestReasons(t *testing.T) {
	for _, c := range []struct {
		err  error
		want string
	}{
		{&net.DNSError{Err: "no such host", Name: "x", IsNotFound: true}, "не нашлось адреса сайта"},
		{&net.DNSError{Err: "timeout", IsTimeout: true}, "время ожидания вышло"},
		{context.DeadlineExceeded, "время ожидания вышло"},
		{&net.OpError{Op: "dial", Err: syscall.ECONNREFUSED}, "не удалось соединиться"},
		{x509.UnknownAuthorityError{}, "ошибка защищённого соединения"},
		{errors.New("tls: handshake failure"), "ошибка защищённого соединения"},
		{io.ErrUnexpectedEOF, "соединение оборвалось"},
		{syscall.ECONNRESET, "соединение оборвалось"},
		{errors.New("something else"), "ошибка проверки"},
	} {
		if got := Reason(c.err); got != c.want {
			t.Errorf("%v: %q, want %q", c.err, got, c.want)
		}
	}
}

// ---- the requests ----------------------------------------------------------------------------------------------------------------

// Every address is tried by several connections at once, and the fastest answer counts: a failure of some of them is not an outage.
func TestTheFastestAnswerCountsAndSomeFailuresAreNoOutage(t *testing.T) {
	var asked atomic.Int32
	ask := func(ctx context.Context, address string) Probe {
		if asked.Add(1)%2 == 1 { // about every second connection fails
			return Probe{Failure: "соединение оборвалось"}
		}
		return Probe{Code: 200, Seconds: 0.3}
	}
	checks := Run(context.Background(), []Target{{"A", []Address{{"x", "https://a.test/"}}}}, ask)
	if checks[0].Verdict() != Works || asked.Load() != attempts {
		t.Errorf("%+v, %d requests in the first round", checks[0], asked.Load())
	}
}

func TestADeadAddressIsTriedTwiceAndThenGivenUp(t *testing.T) {
	var asked atomic.Int32
	ask := func(ctx context.Context, address string) Probe {
		asked.Add(1)
		return Probe{Failure: "время ожидания вышло"}
	}
	checks := Run(context.Background(), []Target{{"A", []Address{{"x", "https://a.test/"}, {"y", "https://b.test/"}}}}, ask)
	if checks[0].Verdict() != Down || asked.Load() != 2*attempts*rounds || checks[0].Probes[0].Failure != "время ожидания вышло" {
		t.Errorf("%+v, %d requests", checks[0], asked.Load())
	}
}

func TestTheChecksComeInTheOrderOfTheTargets(t *testing.T) {
	ask := func(ctx context.Context, address string) Probe { return Probe{Code: 204, Seconds: 0.1} }
	checks := Run(context.Background(), Targets, ask)
	if len(checks) != 2 || checks[0].Name != "YouTube" || checks[1].Name != "Discord" || len(checks[0].Probes) != 4 || checks[1].Probes[3].Name != "Сообщения" {
		t.Fatalf("%+v", checks)
	}
}

func TestAskAgainstAServerOnThisComputer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/moved":
			http.Redirect(w, r, "https://elsewhere.test/", http.StatusFound)
		case "/broken":
			w.WriteHeader(502)
		default:
			w.WriteHeader(204)
		}
	}))
	defer srv.Close()
	for path, want := range map[string]int{"/": 204, "/moved": 302, "/broken": 502} {
		p := Ask(context.Background(), srv.URL+path)
		if p.Code != want || p.Failure != "" {
			t.Errorf("%s: %+v", path, p)
		}
	}
	if p := Ask(context.Background(), "http://127.0.0.1:1/"); p.Failure == "" || p.Answered() {
		t.Errorf("nothing listens: %+v", p)
	}
}
