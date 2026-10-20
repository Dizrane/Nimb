package report

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

var env = Environment{Home: `C:\Users\Anna Petrova`, UserName: "Anna Petrova", ComputerName: "ANNA-LAPTOP"}

// What may leave the computer in a report: nothing that names the person.
func TestHidesAddressesAndEmails(t *testing.T) {
	out := Clean("не удалось 8.8.8.8 и 192.168.1.15, письмо me@example.com, ещё a.b-c@sub.example.co.uk", env)
	for _, bad := range []string{"8.8.8.8", "192.168", "@example", "@sub"} {
		if strings.Contains(out, bad) {
			t.Errorf("%q is still there: %s", bad, out)
		}
	}
	if !strings.Contains(out, "‹ip›") || !strings.Contains(out, "‹e-mail›") {
		t.Errorf("no marks: %s", out)
	}
}

func TestHidesIPv6(t *testing.T) {
	out := Clean("a 2a02:6b8::feed:bad:1234 b", env)
	if !strings.Contains(out, "‹ipv6›") || strings.Contains(out, "2a02") {
		t.Fatal(out)
	}
}

func TestHidesLongKeys(t *testing.T) {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	out := Clean("private_key="+key, env)
	if strings.Contains(out, key) || !strings.Contains(out, "‹ключ›") {
		t.Fatal(out)
	}
}

func TestProviderAddressesBecomeTheirNames(t *testing.T) {
	p := dnsx.Providers[0]
	if out := Clean("DNS: "+strings.Join(p.Addresses, ", "), env); out != "DNS: ‹"+p.Name+"›" {
		t.Fatalf("two addresses of one service read as one name: %q", out)
	}
	// Two different services stay two names.
	a, b := dnsx.Providers[0], dnsx.Providers[1]
	if out := Clean(a.Addresses[0]+", "+b.Addresses[0], env); out != "‹"+a.Name+"›, ‹"+b.Name+"›" {
		t.Fatalf("got %q", out)
	}
}

func TestHidesTheFolderAndTheNamesOfThePerson(t *testing.T) {
	for in, want := range map[string]string{
		`C:\Users\Anna Petrova\AppData\Roaming\Nimb\window.log`: `~\AppData\Roaming\Nimb\window.log`,
		`c:\users\anna petrova\appdata`:                         `~\appdata`,
		`C:/Users/Anna Petrova/Desktop`:                         `~/Desktop`,
		`владелец Anna Petrova на компьютере ANNA-LAPTOP`:       `владелец ‹user› на компьютере ‹pc›`,
		`другой профиль C:\Users\Boris\Documents`:               `другой профиль C:\Users\‹user›\Documents`,
	} {
		if got := Clean(in, env); got != want {
			t.Errorf("%q\n got  %q\n want %q", in, got, want)
		}
	}
}

func TestLeavesTimesVersionsAndWordsAlone(t *testing.T) {
	line := "2026-10-20 14:03:11 [app] запуск Nimb 0.1.0, Windows 11 порт 1443"
	if got := Clean(line, env); got != line {
		t.Fatalf("changed: %q", got)
	}
}

func TestTheHeadHasTheNumberAndWhatWasWritten(t *testing.T) {
	head := Head("AB12CD", "  Не включается туннель  ", "", env)
	if !strings.HasPrefix(head, "Отчёт № AB12CD") || !strings.Contains(head, "Не включается туннель") || strings.Contains(head, "Как ответить") {
		t.Fatal(head)
	}
	if !strings.Contains(Head("AB12CD", "x", "@someone", env), "Как ответить: @someone") {
		t.Fatal("the contact must be added when given")
	}
	if !strings.Contains(Head("AB12CD", "   ", "", env), "(не описано)") {
		t.Fatal("an empty description must be said so")
	}
	if h := Head("AB12CD", "мой ip 93.184.216.34, почта a@b.com", "", env); strings.Contains(h, "93.184") || strings.Contains(h, "a@b.com") {
		t.Fatal("what the person typed must be cleaned too: " + h)
	}
}

func TestIDsAreSixLettersWithoutLookalikes(t *testing.T) {
	for i := 0; i < 500; i++ {
		id := NewID()
		if len(id) != 6 || strings.Trim(id, "ABCDEFGHJKLMNPQRSTUVWXYZ23456789") != "" {
			t.Fatalf("bad id %q", id)
		}
	}
}

func TestFittedKeepsTheHeadAndTheFactsAndDropsTheOldestLines(t *testing.T) {
	var log []string
	for i := 0; i < 300; i++ {
		log = append(log, "2026-10-20 10:00:00 [app] строка журнала номер "+string(rune('A'+i%26)))
	}
	text := strings.Join(append([]string{"Отчёт № AB12CD", "", "— Программа —", "Nimb 0.1.0", "", "— Журнал (последние строки) —"}, log...), "\n")
	got := Fitted(text, 1500)
	if len([]rune(got)) > 1500 || !strings.HasPrefix(got, "Отчёт № AB12CD") || !strings.Contains(got, "Nimb 0.1.0") || !strings.Contains(got, "— Журнал") {
		t.Fatalf("bad cut: %d runes\n%s", len([]rune(got)), got[:200])
	}
	if short := "коротко"; Fitted(short, 100) != short {
		t.Fatal("a short report is not touched")
	}
}

func TestSendPostsTheReportAndSaysWhyWhenItFails(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &got)
		w.WriteHeader(200)
	}))
	defer srv.Close()
	t.Setenv("NIMB_REPORT_URL", srv.URL)
	if err := Send(context.Background(), "0.1.0", "AB12CD", "текст"); err != nil {
		t.Fatal(err)
	}
	if got["platform"] != "windows" || got["id"] != "AB12CD" || got["app"] != "0.1.0" || got["text"] != "текст" || got["v"] != float64(1) {
		t.Fatalf("payload %v", got)
	}

	for code, want := range map[int]string{429: "слишком много", 500: "код 500"} {
		bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(code) }))
		t.Setenv("NIMB_REPORT_URL", bad.URL)
		if err := Send(context.Background(), "0.1.0", "X", "y"); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%d: %v", code, err)
		}
		bad.Close()
	}
	t.Setenv("NIMB_REPORT_URL", "http://127.0.0.1:1/")
	if err := Send(context.Background(), "0.1.0", "X", "y"); err == nil || !strings.Contains(err.Error(), "соединиться") {
		t.Errorf("no server: %v", err)
	}
}

func TestALongReportLosesTheMiddleNotTheEnds(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &got)
	}))
	defer srv.Close()
	t.Setenv("NIMB_REPORT_URL", srv.URL)
	text := "НАЧАЛО" + strings.Repeat("я", 100_000) + "КОНЕЦ"
	if err := Send(context.Background(), "0.1.0", "X", text); err != nil {
		t.Fatal(err)
	}
	s := got["text"].(string)
	if !strings.HasPrefix(s, "НАЧАЛО") || !strings.HasSuffix(s, "КОНЕЦ") || len([]rune(s)) > 60_010 {
		t.Fatalf("bad cut: %d runes", len([]rune(s)))
	}
}
