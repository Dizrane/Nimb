package probe

import (
	"context"
	"crypto/x509"
	"encoding/binary"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

var chatgpt = Target{"ChatGPT", "chatgpt.com", Site, "/"}
var openaiAPI = Target{"ChatGPT", "api.openai.com", API, "/v1/models"}

func hdr(kv ...string) map[string]string {
	m := map[string]string{}
	for i := 0; i < len(kv); i += 2 {
		m[kv[i]] = kv[i+1]
	}
	return m
}

func TestClassify(t *testing.T) {
	long := strings.Repeat("x", 40_000)
	cases := []struct {
		name    string
		target  Target
		code    int
		size    int
		headers map[string]string
		body    string
		want    Status
		reason  string
	}{
		{"a normal page", chatgpt, 200, 5000, nil, "<html>hello</html>", OK, ""},
		{"an API without a key", openaiAPI, 401, 120, hdr("content-type", "application/json"), `{"error":"Missing bearer authentication"}`, OK, ""},
		{"a 404 of the service itself", openaiAPI, 404, 10, nil, "not found", OK, ""},
		{"no answer at all", chatgpt, 0, 0, nil, "", Failed, ""},
		{"a server error", chatgpt, 500, 10, nil, "", Failed, ""},
		{"a bad gateway", chatgpt, 502, 10, nil, "", Failed, ""},
		{"451", chatgpt, 451, 10, nil, "", Blocked, "451: недоступно по юридическим причинам"},
		{"429", openaiAPI, 429, 10, nil, "", Blocked, "429: слишком много запросов с этого адреса"},
		{"403 from the service", openaiAPI, 403, 10, nil, "forbidden", Blocked, "403: доступ закрыт"},
		{"403 of the browser check of Cloudflare", chatgpt, 403, 8622, hdr("cf-mitigated", "challenge"), "<html>Just a moment", OK, ""},
		{"a redirect to the page about restrictions", Target{"Gemini", "gemini.google.com", Site, "/app"}, 302, 0,
			hdr("location", "https://www.google.com/sorry/index?continue=x"), "", Blocked, "перенаправление на www.google.com/sorry"},
		{"a redirect to a help page", chatgpt, 302, 0, hdr("location", "https://help.openai.com/en/articles/1"), "", Blocked, "перенаправление на help.openai.com"},
		{"a redirect to a support page", chatgpt, 301, 0, hdr("location", "https://support.example.com/x"), "", Blocked, "перенаправление на support.example.com"},
		{"a redirect with a word of refusal", chatgpt, 302, 0, hdr("location", "https://other.example/unavailable-in-your-country"), "", Blocked, "перенаправление на other.example"},
		{"a redirect inside the service", chatgpt, 302, 0, hdr("location", "https://chatgpt.com/auth/login"), "", OK, ""},
		{"a relative redirect", chatgpt, 302, 0, hdr("location", "/auth/login"), "", OK, ""},
		{"a redirect to the login of another host", chatgpt, 302, 0, hdr("location", "https://auth.openai.com/authorize?x=1"), "", OK, ""},
		{"a redirect that cannot be read", chatgpt, 302, 0, hdr("location", "http://[::bad"), "", OK, ""},
		{"a short page of refusal", chatgpt, 200, 200, nil, "Sorry, ChatGPT is NOT AVAILABLE IN YOUR COUNTRY", Blocked, "«not available in your country»"},
		{"a 403 with an empty body", openaiAPI, 403, 100, nil, "", Blocked, "403: доступ закрыт"},
		{"a refusal of the API with a good code", openaiAPI, 400, 100, hdr("content-type", "application/json"), `{"error":{"code":"unsupported_country_region_territory"}}`, Blocked, "«unsupported_country»"},
		{"user location is not supported", Target{"Gemini", "generativelanguage.googleapis.com", API, "/"}, 400, 100, nil, "User location is not supported for the API use.", Blocked, "«user location is not supported»"},
		{"the phrase inside a big page is a translation", chatgpt, 200, 80_000, nil, "not available in your country", OK, ""},
		{"the phrase in a big JSON still counts", openaiAPI, 200, 80_000, hdr("content-type", "application/json; charset=utf-8"), "request not allowed", Blocked, "«request not allowed»"},
		{"a page just under the limit", chatgpt, 200, 29_999, nil, "access denied", Blocked, "«access denied»"},
		{"a page at the limit", chatgpt, 200, 30_000, nil, "access denied", OK, ""},
		{"a long page", chatgpt, 200, 40_000, nil, long, OK, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Classify(c.target, c.code, 0.4, c.size, c.headers, c.body)
			if got.Status != c.want || got.Reason != c.reason {
				t.Fatalf("got %+v, want status %v reason %q", got, c.want, c.reason)
			}
			if c.want == OK && got.Seconds != 0.4 {
				t.Errorf("the time is lost: %+v", got)
			}
		})
	}
}

func TestServiceStatus(t *testing.T) {
	cases := []struct {
		r    ServiceResult
		want ServiceStatus
	}{
		{ServiceResult{"ChatGPT", 4, 0, 5}, Works},
		{ServiceResult{"ChatGPT", 3, 0, 4}, Works}, // a few dead addresses in a pool still work
		{ServiceResult{"ChatGPT", 2, 0, 5}, Unstable},
		{ServiceResult{"Gemini", 4, 1, 5}, Unstable}, // a refusal page hits every visit that lands on that address
		{ServiceResult{"Claude", 0, 0, 5}, Down},
		{ServiceResult{"Claude", 0, 3, 5}, Refused},
		{ServiceResult{"Claude", 0, 0, 0}, Down},
	}
	for _, c := range cases {
		if got := c.r.Status(); got != c.want {
			t.Errorf("%+v: %s, want %s", c.r, got, c.want)
		}
	}
}

func ok(s Target, addr string, sec float64) Sample {
	return Sample{s, addr, Outcome{Status: OK, Seconds: sec}}
}
func failed(s Target, addr string) Sample { return Sample{s, addr, Outcome{Status: Failed}} }

// every service answers on every one of the addresses
func healthy(p dnsx.Provider, seconds float64) ProviderReport {
	r := ProviderReport{Provider: p}
	for _, t := range All {
		r.Samples = append(r.Samples, ok(t, "10.0.0.1", seconds), ok(t, "10.0.0.2", seconds))
	}
	return r
}

func TestReportCounts(t *testing.T) {
	p := dnsx.Providers[0]
	r := healthy(p, 0.5)
	if r.WorkingCount() != len(Services()) {
		t.Fatalf("working %d of %d", r.WorkingCount(), len(Services()))
	}
	// kill ChatGPT on one address of two: 50% answered, below the share
	for i := range r.Samples {
		s := &r.Samples[i]
		if s.Target.Service == "ChatGPT" && s.Address == "10.0.0.2" {
			s.Outcome = Outcome{Status: Failed}
		}
	}
	if r.WorkingCount() != len(Services())-1 {
		t.Errorf("a half-dead pool should not work: %d", r.WorkingCount())
	}
	if got := r.Count("ChatGPT", Site); got != "1/2" {
		t.Errorf("count %q", got)
	}
	if got := r.DeadAddresses(); len(got) != 0 {
		t.Errorf("10.0.0.2 answers for the other services, it is not dead: %v", got)
	}
}

func TestDeadAddressesAndRefusals(t *testing.T) {
	r := ProviderReport{Provider: dnsx.Providers[0], Samples: []Sample{
		ok(chatgpt, "1.1.1.1", 0.3), failed(chatgpt, "2.2.2.2"), failed(openaiAPI, "2.2.2.2"),
		{chatgpt, "3.3.3.3", Outcome{Status: Blocked, Reason: "403: доступ закрыт"}},
		{openaiAPI, "3.3.3.3", Outcome{Status: Blocked, Reason: "403: доступ закрыт"}},
		failed(openaiAPI, ""),
	}}
	if got, want := r.DeadAddresses(), []string{"2.2.2.2", "3.3.3.3"}; !slices.Equal(got, want) {
		t.Errorf("dead %v, want %v", got, want)
	}
	if got, want := r.Refusals(), []string{"ChatGPT · 3.3.3.3: 403: доступ закрыт"}; !slices.Equal(got, want) {
		// the same refusal of the same service and address is told once, even for the site and the API
		t.Errorf("refusals %v, want %v", got, want)
	}
	d := r.Details()
	for _, line := range []string{"ChatGPT: сайт 1/3, API 0/3", "Отказ: ChatGPT · 3.3.3.3: 403: доступ закрыт", "Без нормального ответа адреса: 2.2.2.2, 3.3.3.3"} {
		if !strings.Contains(d, line) {
			t.Errorf("no %q in\n%s", line, d)
		}
	}
}

func TestMedianIsTheMiddleOfTheAnswers(t *testing.T) {
	r := ProviderReport{Samples: []Sample{ok(chatgpt, "a", 0.2), ok(chatgpt, "b", 3.0), ok(chatgpt, "c", 0.4), failed(chatgpt, "d")}}
	if m, found := r.Median(); !found || m != 0.4 {
		t.Errorf("median %v %v", m, found)
	}
	if _, found := (ProviderReport{Samples: []Sample{failed(chatgpt, "a")}}).Median(); found {
		t.Error("no answers, no median")
	}
}

func TestRanking(t *testing.T) {
	ps := dnsx.Providers
	slow, fast := healthy(ps[0], 1.0), healthy(ps[1], 0.5)
	if !fast.IsBetter(slow) || slow.IsBetter(fast) {
		t.Error("at the same number of services the clearly faster wins")
	}
	near := healthy(ps[2], 0.95)
	if near.IsBetter(slow) || slow.IsBetter(near) {
		t.Error("a difference below 0.1 s is noise")
	}
	broken := healthy(ps[3], 0.1)
	for i := range broken.Samples {
		if broken.Samples[i].Target.Service == "Grok" {
			broken.Samples[i].Outcome = Outcome{Status: Failed}
		}
	}
	if !slow.IsBetter(broken) || broken.IsBetter(slow) {
		t.Error("more working services beats speed")
	}
	if best := Best([]ProviderReport{broken, slow, fast, near}); best == nil || best.Provider.ID != ps[1].ID {
		t.Errorf("best %+v", best)
	}
	if best := Best([]ProviderReport{slow, near}); best.Provider.ID != ps[0].ID {
		t.Error("the first of equals wins")
	}
	if Best(nil) != nil {
		t.Error("nothing to choose from")
	}
	if none := (ProviderReport{}); !fast.IsBetter(none) || none.IsBetter(fast) {
		t.Error("a report with no answers is the worst")
	}
}

func TestView(t *testing.T) {
	v := healthy(dnsx.Providers[1], 0.5).View()
	if v.ID != dnsx.Providers[1].ID || v.Working != 5 || v.Total != 5 || v.Median == nil || *v.Median != 0.5 || len(v.Services) != 5 {
		t.Errorf("%+v", v)
	}
	if v.Services[0].Name != "ChatGPT" || v.Services[0].Status != Works || v.Services[0].Site != "2/2" || v.Services[0].API != "2/2" {
		t.Errorf("%+v", v.Services[0])
	}
	if v.Refusals == nil || v.Dead == nil {
		t.Error("the page expects lists, not null")
	}
}

// ---- the lists must be the ones of the Mac app ----------------------------------------------------------------------------

func macProbe(t *testing.T) string {
	raw, err := os.ReadFile("../../../Sources/Nimb/ServiceProbe.swift")
	if err != nil {
		t.Skip("the repository root is not here")
	}
	return string(raw)
}

func TestTargetsAreTheOnesOfTheMacApp(t *testing.T) {
	src := macProbe(t)
	re := regexp.MustCompile(`ProbeTarget\(service: "([^"]+)", host: "([^"]+)", kind: \.(site|api)(?:, path: "([^"]+)")?\)`)
	found := re.FindAllStringSubmatch(src, -1)
	if len(found) != len(All) {
		t.Fatalf("the Mac app has %d targets, this list has %d", len(found), len(All))
	}
	for i, m := range found {
		kind, path := Site, "/"
		if m[3] == "api" {
			kind = API
		}
		if m[4] != "" {
			path = m[4]
		}
		if want := (Target{m[1], m[2], kind, path}); All[i] != want {
			t.Errorf("target %d: mac %+v, here %+v", i, want, All[i])
		}
	}
}

func swiftList(t *testing.T, src, name string) []string {
	m := regexp.MustCompile(`(?s)` + name + `[^=]*= \[(.*?)\]\n`).FindStringSubmatch(src)
	if m == nil {
		t.Fatalf("no %s in the Mac app", name)
	}
	var out []string
	for _, s := range regexp.MustCompile(`"([^"]*)"`).FindAllStringSubmatch(m[1], -1) {
		out = append(out, s[1])
	}
	return out
}

func TestWordsAndThresholdsAreTheOnesOfTheMacApp(t *testing.T) {
	src := macProbe(t)
	if got := swiftList(t, src, "refusalWords"); !slices.Equal(got, refusalWords) {
		t.Errorf("words: mac %v, here %v", got, refusalWords)
	}
	if got := swiftList(t, src, "refusalPhrases"); !slices.Equal(got, refusalPhrases) {
		t.Errorf("phrases: mac %v, here %v", got, refusalPhrases)
	}
	for _, c := range []struct {
		name string
		v    string
	}{{"workingShare", "0.75"}, {"noticeableDifference", "0.1"}} {
		if !strings.Contains(src, "static let "+c.name+" = "+c.v) {
			t.Errorf("%s is not %s in the Mac app", c.name, c.v)
		}
	}
	if WorkingShare != 0.75 || NoticeableDifference != 0.1 || bigBody != 30_000 {
		t.Error("thresholds")
	}
}

// ---- the network part, against servers on this computer ----------------------------------------------------------------------

// fakeDNS answers every A question with the given addresses (and nothing else), the way a provider does. It counts the questions.
func fakeDNS(t *testing.T, answers []string) (port string, asked *atomic.Int32) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skip("no UDP here")
	}
	t.Cleanup(func() { conn.Close() })
	asked = new(atomic.Int32)
	go func() {
		buf := make([]byte, 512)
		for {
			n, from, err := conn.ReadFrom(buf)
			if err != nil {
				return
			}
			asked.Add(1)
			q := buf[:n]
			end := 12
			for end < n && q[end] != 0 {
				end += int(q[end]) + 1
			}
			question := q[12 : end+5] // name, zero, type, class
			qtype := binary.BigEndian.Uint16(q[end+1:])
			resp := append([]byte{}, q[:2]...)
			count := uint16(0)
			if qtype == 1 {
				count = uint16(len(answers))
			}
			resp = append(resp, 0x81, 0x80, 0, 1, byte(count>>8), byte(count), 0, 0, 0, 0)
			resp = append(resp, question...)
			if qtype == 1 {
				for _, a := range answers {
					ip := net.ParseIP(a).To4()
					resp = append(resp, 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4)
					resp = append(resp, ip...)
				}
			}
			conn.WriteTo(resp, from)
		}
	}()
	_, port, _ = net.SplitHostPort(conn.LocalAddr().String())
	return port, asked
}

func TestResolveTakesTheIPv4AnswersOfTheProviderServer(t *testing.T) {
	port, asked := fakeDNS(t, []string{"203.0.113.7", "203.0.113.8", "0.0.0.0", "127.0.0.1"})
	p := &Prober{DNSPort: port}
	got := p.resolve(context.Background(), "chatgpt.com", []string{"127.0.0.1"})
	if !slices.Equal(got, []string{"203.0.113.7", "203.0.113.8"}) {
		t.Errorf("got %v: the zero address and the loopback are not usable", got)
	}
	if asked.Load() == 0 {
		t.Error("the server was not asked")
	}
}

func TestResolveFallsBackToTheSecondServer(t *testing.T) {
	port, _ := fakeDNS(t, []string{"203.0.113.9"})
	// nothing listens on 127.0.0.2, so the first server gives no answer and the second one is asked
	p := &Prober{DNSPort: port}
	got := p.resolve(context.Background(), "claude.ai", []string{"127.0.0.2", "127.0.0.1"})
	if !slices.Equal(got, []string{"203.0.113.9"}) {
		t.Errorf("got %v", got)
	}
}

// tlsPool starts a server with a certificate for example.com and returns a prober that goes to it.
func tlsPool(t *testing.T, h http.HandlerFunc) *Prober {
	srv := httptest.NewTLSServer(h)
	t.Cleanup(srv.Close)
	_, port, _ := net.SplitHostPort(srv.Listener.Addr().String())
	roots := x509.NewCertPool()
	roots.AddCert(srv.Certificate())
	return &Prober{HTTPSPort: port, RootCAs: roots, loopback: true}
}

func TestRequestJudgesTheAnswer(t *testing.T) {
	site := Target{"Test", "example.com", Site, "/page?x=1"}
	cases := []struct {
		name   string
		h      http.HandlerFunc
		want   Status
		reason string
	}{
		{"a normal answer", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("hello")) }, OK, ""},
		{"a redirect is not followed and judged", func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, "https://www.google.com/sorry/index", http.StatusFound)
		}, Blocked, "перенаправление на www.google.com/sorry"},
		{"a refusal page", func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(403)
			w.Write([]byte("nope"))
		}, Blocked, "403: доступ закрыт"},
		{"the browser check of Cloudflare", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cf-Mitigated", "challenge")
			w.WriteHeader(403)
		}, OK, ""},
		{"a server error", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) }, Failed, ""},
		{"a phrase of refusal", func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte("This service is not available in your region."))
		}, Blocked, "«not available in your region»"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := tlsPool(t, c.h)
			got := p.request(context.Background(), site, "127.0.0.1")
			if got.Status != c.want || got.Reason != c.reason {
				t.Fatalf("got %+v", got)
			}
		})
	}
}

func TestRequestSendsTheNameOfTheTarget(t *testing.T) {
	var host, path, agent string
	p := tlsPool(t, func(w http.ResponseWriter, r *http.Request) {
		host, path, agent = r.Host, r.URL.RequestURI(), r.UserAgent()
	})
	got := p.request(context.Background(), Target{"Test", "example.com", API, "/v1/models?key=x"}, "127.0.0.1")
	if got.Status != OK || host != "example.com" || path != "/v1/models?key=x" || !strings.HasPrefix(agent, "curl/") {
		t.Errorf("%+v host %q path %q agent %q", got, host, path, agent)
	}
}

func TestRequestRefusesACertificateOfAnotherName(t *testing.T) {
	p := tlsPool(t, func(w http.ResponseWriter, r *http.Request) {})
	// the certificate of the test server is for example.com: for any other name the check must not count it as an answer
	if got := p.request(context.Background(), Target{"Test", "chatgpt.com", Site, "/"}, "127.0.0.1"); got.Status != Failed {
		t.Errorf("got %+v", got)
	}
}

func TestRequestGivesUpOnASlowAnswer(t *testing.T) {
	if testing.Short() {
		t.Skip("takes six seconds")
	}
	p := tlsPool(t, func(w http.ResponseWriter, r *http.Request) { time.Sleep(requestTimeout + time.Second) })
	start := time.Now()
	got := p.request(context.Background(), Target{"Test", "example.com", Site, "/"}, "127.0.0.1")
	if got.Status != Failed || time.Since(start) > requestTimeout+time.Second {
		t.Errorf("got %+v after %v", got, time.Since(start))
	}
}

func TestRequestNoServer(t *testing.T) {
	p := &Prober{HTTPSPort: "1", loopback: true}
	if got := p.request(context.Background(), Target{"Test", "example.com", Site, "/"}, "127.0.0.1"); got.Status != Failed {
		t.Errorf("got %+v", got)
	}
}

func TestRunMakesOneReportForEachProviderAndCountsTheRequests(t *testing.T) {
	port, _ := fakeDNS(t, []string{"203.0.113.5", "203.0.113.6"})
	providers := []dnsx.Provider{
		{ID: "a", Name: "A", Addresses: []string{"127.0.0.1"}},
		{ID: "silent", Name: "S", Addresses: []string{"127.0.0.2"}}, // nothing listens there: no addresses at all
	}
	p := &Prober{DNSPort: port, HTTPSPort: "1"} // 203.0.113.0/24 is a documentation range: the connection fails
	var last, total atomic.Int32
	reports := p.Run(context.Background(), providers, func(done, n int) { last.Store(int32(done)); total.Store(int32(n)) })
	if len(reports) != 2 || reports[0].Provider.ID != "a" || reports[1].Provider.ID != "silent" {
		t.Fatalf("%+v", reports)
	}
	if got, want := len(reports[0].Samples), 2*len(All); got != want {
		t.Errorf("provider a: %d samples, want %d (two addresses for every target)", got, want)
	}
	if got, want := len(reports[1].Samples), len(All); got != want {
		t.Errorf("silent provider: %d samples, want %d (one failure for every target)", got, want)
	}
	for _, s := range reports[1].Samples {
		if s.Address != "" || s.Outcome.Status != Failed {
			t.Fatalf("%+v", s)
		}
	}
	if last.Load() != total.Load() || int(total.Load()) != 3*len(All) {
		t.Errorf("progress %d of %d", last.Load(), total.Load())
	}
	if reports[0].WorkingCount() != 0 || Best(reports).WorkingCount() != 0 {
		t.Error("nothing could be reached")
	}
}

func TestLinesOfAReport(t *testing.T) {
	r := healthy(dnsx.Providers[0], 0.5)
	for i := range r.Samples {
		if s := &r.Samples[i]; s.Target.Service == "Gemini" && s.Address == "10.0.0.2" {
			s.Outcome = Outcome{Status: Blocked, Reason: "403: доступ закрыт"}
		}
	}
	lines := Lines([]ProviderReport{r})
	want := []string{
		dnsx.Providers[0].Name + ": работает 4 из 5 (ChatGPT 4/4, Claude 4/4, Gemini 2/4, Grok 4/4, ElevenLabs 4/4), медиана 0.5 с",
		"  отказ: Gemini · 10.0.0.2: 403: доступ закрыт",
		"  без нормального ответа: ",
	}
	if len(lines) != 2 || lines[0] != want[0] || lines[1] != want[1] {
		t.Errorf("got\n%s", strings.Join(lines, "\n"))
	}
	if got := Addresses([]ProviderReport{r, r}); !slices.Equal(got, []string{"10.0.0.1", "10.0.0.2"}) {
		t.Errorf("addresses %v", got)
	}
}
