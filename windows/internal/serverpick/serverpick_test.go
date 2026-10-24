package serverpick

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

var errNoShake = errors.New("сервер не ответил")
var errOther = errors.New("не удалось создать адаптер")

// fake is a pretend network: which servers give a handshake, which open YouTube, whether the internet works.
type fake struct {
	shake    map[string]bool // host ("" is the settings) gives a handshake
	video    map[string]bool // host opens YouTube and Discord
	webDown  bool
	up       string // the server that is up now
	kept     string
	searched time.Time
	now      time.Time
	ups      []string // every BringUp, in order
	log      []string
}

func newFake() *fake {
	return &fake{shake: map[string]bool{"": true, "162.159.192.1": true, "188.114.97.1": true, "188.114.99.1": true}, video: map[string]bool{}, now: time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)}
}

func (f *fake) steps() Steps {
	return Steps{
		BringUp: func(host string) error {
			f.ups = append(f.ups, host)
			f.up = ""
			if !f.shake[host] {
				return errNoShake
			}
			f.up = host
			return nil
		},
		NoAnswer:     func(err error) bool { return errors.Is(err, errNoShake) },
		Web:          func() bool { return !f.webDown },
		Opens:        func() bool { return f.video[f.up] },
		Saved:        func() string { return f.kept },
		Save:         func(h string) { f.kept = h },
		SearchedAt:   func() time.Time { return f.searched },
		MarkSearched: func(t time.Time) { f.searched = t },
		Now:          func() time.Time { return f.now },
		Log:          func(format string, args ...any) { f.log = append(f.log, fmt.Sprintf(format, args...)) },
	}
}

func (f *fake) logged(part string) bool {
	for _, l := range f.log {
		if strings.Contains(l, part) {
			return true
		}
	}
	return false
}

func TestWhenYouTubeOpensAtTheServerOfTheSettingsNothingIsSearched(t *testing.T) {
	f := newFake()
	f.video[""] = true
	cur, err := Start(f.steps(), true)
	if err != nil || cur != "" || len(f.ups) != 1 || f.kept != "" {
		t.Errorf("cur=%q err=%v ups=%v kept=%q", cur, err, f.ups, f.kept)
	}
}

func TestYouTubeDoesNotOpenTheNextServerThatDoesIsKept(t *testing.T) {
	f := newFake()
	f.video["188.114.97.1"] = true
	cur, err := Start(f.steps(), true)
	if err != nil || cur != "188.114.97.1" {
		t.Fatalf("cur=%q err=%v", cur, err)
	}
	if f.kept != "188.114.97.1" || !f.searched.IsZero() {
		t.Errorf("kept %q, searched %v", f.kept, f.searched)
	}
	// The order: the settings first, then the servers one after another, and the search stops at the first that opens both.
	want := []string{"", "162.159.192.1", "188.114.97.1"}
	if strings.Join(f.ups, "|") != strings.Join(want, "|") {
		t.Errorf("ups %v, want %v", f.ups, want)
	}
	// The next start uses the kept server and does not search again.
	f.ups = nil
	cur, _ = Start(f.steps(), true)
	if cur != "188.114.97.1" || len(f.ups) != 1 || f.ups[0] != "188.114.97.1" {
		t.Errorf("next start: cur=%q ups=%v", cur, f.ups)
	}
}

func TestTheKeptServerStoppedOpeningYouTubeTheSettingsAreTriedAndTheKeptOneForgotten(t *testing.T) {
	f := newFake()
	f.kept = "188.114.97.1"
	f.video[""] = true // the kept one is up, but YouTube does not open at it any more; the settings open it
	cur, err := Start(f.steps(), true)
	if err != nil || cur != "" || f.kept != "" {
		t.Errorf("cur=%q err=%v kept=%q ups=%v", cur, err, f.kept, f.ups)
	}
}

func TestNoServerOpensYouTubeBackToTheSettingsAndNoSearchForTenMinutes(t *testing.T) {
	f := newFake()
	cur, err := Start(f.steps(), true)
	if err != nil || cur != "" || f.kept != "" {
		t.Fatalf("cur=%q err=%v kept=%q", cur, err, f.kept)
	}
	if f.searched != f.now || !f.logged("ни один сервер") {
		t.Errorf("searched %v, log %v", f.searched, f.log)
	}
	if f.up != "" {
		t.Errorf("the tunnel is left at %q, not at the settings", f.up)
	}
	// Five minutes later: no new search (a start only).
	f.ups = nil
	f.now = f.now.Add(5 * time.Minute)
	Start(f.steps(), true)
	if len(f.ups) != 1 {
		t.Errorf("searched again after five minutes: %v", f.ups)
	}
	// Eleven minutes after the first: it is searched again.
	f.ups = nil
	f.now = f.now.Add(6 * time.Minute)
	Start(f.steps(), true)
	if len(f.ups) < 4 {
		t.Errorf("not searched after ten minutes: %v", f.ups)
	}
}

func TestWhenTheInternetItselfIsDownThereIsNoSearch(t *testing.T) {
	f := newFake()
	f.webDown = true
	Start(f.steps(), true)
	if len(f.ups) != 1 || !f.searched.IsZero() {
		t.Errorf("ups %v searched %v", f.ups, f.searched)
	}
}

func TestARestartMadeByTheServiceDoesNotSearch(t *testing.T) {
	f := newFake()
	cur, err := Start(f.steps(), false) // YouTube would not open anywhere
	if err != nil || cur != "" || len(f.ups) != 1 {
		t.Errorf("cur=%q err=%v ups=%v", cur, err, f.ups)
	}
}

func TestNoHandshakeAtTheSettingsTheOtherServersAreTriedBeforeTheStartFails(t *testing.T) {
	f := newFake()
	f.shake[""] = false
	f.shake["162.159.192.1"] = false
	f.video["188.114.97.1"] = true
	cur, err := Start(f.steps(), true)
	if err != nil || cur != "188.114.97.1" || f.kept != "188.114.97.1" || !f.logged("отвечает, а сервер из настроек нет") {
		t.Errorf("cur=%q err=%v kept=%q log=%v", cur, err, f.kept, f.log)
	}
}

func TestNoServerAnswersTheStartFailsWithTheFirstError(t *testing.T) {
	f := newFake()
	for k := range f.shake {
		f.shake[k] = false
	}
	cur, err := Start(f.steps(), true)
	if !errors.Is(err, errNoShake) || cur != "" || f.kept != "" || len(f.ups) != 4 {
		t.Errorf("cur=%q err=%v kept=%q ups=%v", cur, err, f.kept, f.ups)
	}
}

func TestAnErrorThatIsNotAMissingHandshakeIsNotTriedAtOtherServers(t *testing.T) {
	f := newFake()
	s := f.steps()
	n := 0
	s.BringUp = func(host string) error { n++; return errOther }
	if _, err := Start(s, true); !errors.Is(err, errOther) || n != 1 {
		t.Errorf("err=%v tries=%d", err, n)
	}
}

func TestTheKeptServerDoesNotAnswerTheSettingsAreTried(t *testing.T) {
	f := newFake()
	f.kept = "162.159.192.1"
	f.shake["162.159.192.1"] = false
	f.video[""] = true
	cur, err := Start(f.steps(), true)
	if err != nil || cur != "" || f.ups[0] != "162.159.192.1" || f.ups[1] != "" || !f.logged("не ответил") {
		t.Errorf("cur=%q err=%v ups=%v log=%v", cur, err, f.ups, f.log)
	}
}

func TestOnlyKnownServersAreKeptAndThePortStays(t *testing.T) {
	if !Valid("188.114.97.1\n") || Valid("1.2.3.4") || Valid("") {
		t.Error("Valid")
	}
	if got, err := WithHost("162.159.195.4:2408", "188.114.99.1"); err != nil || got != "188.114.99.1:2408" {
		t.Errorf("%q %v", got, err)
	}
	if got, _ := WithHost("162.159.195.4:2408", ""); got != "162.159.195.4:2408" {
		t.Errorf("the settings' endpoint changed: %q", got)
	}
	if _, err := WithHost("nonsense", "188.114.99.1"); err == nil {
		t.Error("an endpoint without a port")
	}
}

func TestASiteOpensWhenItAnswersWithAnyStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/204":
			w.WriteHeader(204)
		case "/403":
			w.WriteHeader(403) // a refusal is an answer: the handshake of TLS went through
		case "/slow":
			time.Sleep(6 * time.Second)
		}
	}))
	defer srv.Close()
	ctx := context.Background()
	if !Opens(ctx, srv.Client(), srv.URL+"/204") || !Opens(ctx, srv.Client(), srv.URL+"/403") {
		t.Error("an answer did not count")
	}
	if Opens(ctx, srv.Client(), "http://127.0.0.1:1/") {
		t.Error("a closed port opened")
	}
	if !OpenBoth(ctx, srv.Client(), srv.URL+"/204", srv.URL+"/403") || OpenBoth(ctx, srv.Client(), srv.URL+"/204", "http://127.0.0.1:1/") {
		t.Error("OpenBoth")
	}
}
