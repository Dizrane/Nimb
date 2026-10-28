package autoreport

import (
	"strings"
	"testing"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

func ptr(n int) *int { return &n }

func TestTelegramAgreesByListeningOnly(t *testing.T) {
	if !TelegramAgrees(true, true) || !TelegramAgrees(false, false) {
		t.Fatal("on and listening, or off and not listening, agree")
	}
	if TelegramAgrees(true, false) || TelegramAgrees(false, true) {
		t.Fatal("on and not listening, or off and still listening, disagree")
	}
}

func TestTunnelErrorsThatAreTheNetworksAreNotOurs(t *testing.T) {
	for _, msg := range []string{
		"сервер не ответил: рукопожатия нет",
		"сервер не ответил, интернет остался прежним",
		"Туннель остановился сам: его программа неожиданно завершилась.",
		"Туннель выключился сам: Cloudflare не отвечал несколько минут.",
	} {
		if TunnelErrorIsOurs(msg) {
			t.Errorf("%q must not be a fault of ours", msg)
		}
	}
	for _, msg := range []string{"настройки туннеля не прошли проверку: что-то", "не удалось сохранить аккаунт: доступ запрещён"} {
		if !TunnelErrorIsOurs(msg) {
			t.Errorf("%q is ours", msg)
		}
	}
}

func adapter(name, servers string) dnsx.Adapter { return dnsx.Adapter{Name: name, NameServer: servers} }

func TestDNSAgreesByTheSettings(t *testing.T) {
	p, _ := dnsx.Find("geohide-eu")
	ours := p.Servers()
	if !DNSAgrees(&p, []dnsx.Adapter{adapter("Wi-Fi", ours), adapter("Ethernet", ours)}) {
		t.Error("on and on every connection agrees")
	}
	if DNSAgrees(&p, []dnsx.Adapter{adapter("Wi-Fi", ours), adapter("Ethernet", "")}) {
		t.Error("one connection with the automatic DNS disagrees")
	}
	if DNSAgrees(&p, nil) {
		t.Error("on with no connection at all disagrees")
	}
	if !DNSAgrees(nil, []dnsx.Adapter{adapter("Wi-Fi", ""), adapter("Ethernet", "8.8.8.8")}) {
		t.Error("off and nothing of Nimb left agrees")
	}
	if DNSAgrees(nil, []dnsx.Adapter{adapter("Wi-Fi", ours)}) {
		t.Error("off but the DNS of Nimb is still there disagrees")
	}
}

func TestADnsOfAnotherProgramIsNotOurFault(t *testing.T) {
	p, _ := dnsx.Find("geohide-eu")
	ours := p.Servers()
	if !DNSTakenByOthers(&p, []dnsx.Adapter{adapter("Wi-Fi", ours), adapter("VPN", "10.8.0.1")}) {
		t.Error("a connection with the DNS of someone else is taken by others")
	}
	if DNSTakenByOthers(&p, []dnsx.Adapter{adapter("Wi-Fi", ours), adapter("Ethernet", "")}) {
		t.Error("a connection with no DNS of its own is a gap of Nimb, not of others")
	}
	if DNSTakenByOthers(&p, []dnsx.Adapter{adapter("Wi-Fi", "10.8.0.1"), adapter("Ethernet", "")}) {
		t.Error("one gap that is ours is enough")
	}
	if DNSTakenByOthers(nil, []dnsx.Adapter{adapter("Wi-Fi", "10.8.0.1")}) {
		t.Error("off: nothing to be taken")
	}
}

func TestADisagreementOfTheDNSCountsOnlyWhileTheNetAnswersAndWhenItIsOurs(t *testing.T) {
	if !DNSCounts(true, true, false) {
		t.Error("an agreement counts as an agreement")
	}
	if DNSCounts(false, true, false) {
		t.Error("a disagreement with the net up is a disagreement")
	}
	if !DNSCounts(false, false, false) {
		t.Error("with the net gone it says nothing about Nimb")
	}
	if !DNSCounts(false, true, true) {
		t.Error("taken by another program is not ours")
	}
}

func TestTheTunnelAgreesWithItsRoutes(t *testing.T) {
	if !TunnelAgrees(true, 3, true, false) || TunnelAgrees(true, 0, false, false) || TunnelAgrees(true, 3, false, false) {
		t.Error("on needs routes and the traffic through the tunnel")
	}
	if !TunnelAgrees(false, 0, false, false) || TunnelAgrees(false, 2, false, false) {
		t.Error("off needs no routes")
	}
	if !TunnelAgrees(true, 0, false, true) || !TunnelAgrees(false, 2, true, true) {
		t.Error("nothing is compared while it is being switched")
	}
}

func TestASilentTunnelIsOneWithNoAnswerAndNoInternetThroughIt(t *testing.T) {
	if TunnelSilent(nil, false) {
		t.Error("an age that is not known is not silence")
	}
	if TunnelSilent(ptr(120), false) || TunnelSilent(ptr(StaleAfter), false) {
		t.Error("a healthy tunnel answers every two minutes")
	}
	if !TunnelSilent(ptr(StaleAfter+1), false) {
		t.Error("silent and nothing through it is a fault")
	}
	if TunnelSilent(ptr(900), true) {
		t.Error("the traffic still goes through it: not a fault")
	}
}

func TestCausesHaveKeysAndWords(t *testing.T) {
	keys := map[string]bool{}
	for _, tr := range []Trigger{PreviousEndedBadly, TunnelRestarted, TunnelDropped, Mismatch(DNS), Mismatch(Telegram), Mismatch(Tunnel),
		Error(DNS), Error(Telegram), Error(Tunnel), UpdateCheck, TunnelSilentCause, NewKeysFailed, DailyDigestCause} {
		if tr.Key == "" || tr.Title == "" || len(tr.Key) > 40 {
			t.Errorf("a cause without a key or words: %+v", tr)
		}
		for _, r := range tr.Key {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
				t.Errorf("the key %q must be plain latin letters, digits and hyphens (the relay takes nothing else)", tr.Key)
			}
		}
		if keys[tr.Key] {
			t.Errorf("the key %q is used twice", tr.Key)
		}
		keys[tr.Key] = true
	}
	if !strings.Contains(Mismatch(Tunnel).Title, "YouTube и Discord") {
		t.Error("the words name the service")
	}
}

func TestTheFirstReportGoesAndTheSameCauseWaitsSixHours(t *testing.T) {
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	if !Allows("crash", now, nil, false) {
		t.Fatal("the first one goes")
	}
	history := []Sent{{"crash", now.Add(-5 * time.Hour)}}
	if Allows("crash", now, history, false) {
		t.Error("the same cause is not told twice in six hours")
	}
	if !Allows("crash", now.Add(2*time.Hour), history, false) {
		t.Error("after six hours it is told again")
	}
}

func TestNotMoreThanOneAnHourAndFiveADay(t *testing.T) {
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	if Allows("a", now, []Sent{{"b", now.Add(-30 * time.Minute)}}, false) {
		t.Error("a second report within the hour waits")
	}
	if !Allows("a", now, []Sent{{"b", now.Add(-90 * time.Minute)}}, false) {
		t.Error("an hour later it goes")
	}
	var day []Sent
	for i := 0; i < 5; i++ {
		day = append(day, Sent{string(rune('b' + i)), now.Add(-time.Duration(2+3*i) * time.Hour)})
	}
	if Allows("a", now, day, false) {
		t.Error("the sixth in a day waits")
	}
	if Allows("a", now, day, true) {
		t.Error("the limit of the day holds even for the one that ignores the hour")
	}
}

func TestTheReportThatNewKeysDidNotHelpIsNotHeldBackByTheHourLimit(t *testing.T) {
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	history := []Sent{{"crash", now.Add(-10 * time.Minute)}}
	if Allows(Error(DNS).Key, now, history, false) {
		t.Error("an ordinary cause waits")
	}
	if !NewKeysFailed.IgnoresHourLimit || !Allows(NewKeysFailed.Key, now, history, NewKeysFailed.IgnoresHourLimit) {
		t.Error("the keys that did not help go at once")
	}
	if Mismatch(DNS).IgnoresHourLimit || DailyDigestCause.IgnoresHourLimit {
		t.Error("only the keys ignore the hour")
	}
}

func TestOnlyTheLastDayOfHistoryIsKept(t *testing.T) {
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	kept := Pruned([]Sent{{"old", now.Add(-25 * time.Hour)}, {"new", now.Add(-time.Hour)}}, now)
	if len(kept) != 1 || kept[0].Key != "new" {
		t.Errorf("kept %v", kept)
	}
}

func TestADisagreementMustLastTwoLooksAndIsToldOnce(t *testing.T) {
	var m MismatchTracker
	if m.Observe("dns", false) {
		t.Error("one look is a moment of switching")
	}
	if !m.Observe("dns", false) {
		t.Error("two in a row is a fault")
	}
	if m.Observe("dns", false) {
		t.Error("told once")
	}
	m.Observe("dns", true)
	if m.Observe("dns", false) {
		t.Error("after an agreement it counts from the start")
	}
	if m.Observe("telegram", false) {
		t.Error("the services are counted apart")
	}
}

func TestAReportThatCouldNotGoWaitsADayAtMostAndOnlyThreeAreKept(t *testing.T) {
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	item := func(id string, ago time.Duration) PendingItem { return PendingItem{ID: id, At: now.Add(-ago)} }
	got := FreshPending([]PendingItem{item("OLD", 25*time.Hour), item("A", 5*time.Hour), item("B", 4*time.Hour), item("C", 3*time.Hour), item("D", time.Hour)}, now)
	if len(got) != 3 || got[0].ID != "B" || got[2].ID != "D" {
		t.Errorf("kept %v", got)
	}
}

func TestTheNumberOfTheInstallationIsEightPlainCharacters(t *testing.T) {
	id := NewInstallID(func(b []byte) {
		for i := range b {
			b[i] = byte(i * 37)
		}
	})
	if len(id) != 8 {
		t.Fatalf("%q", id)
	}
	for _, r := range id {
		if strings.ContainsRune("01IO", r) || !(r >= 'A' && r <= 'Z' || r >= '2' && r <= '9') {
			t.Errorf("%q has a character that is mistaken for another or is not A-Z0-9", id)
		}
	}
}

func facts() Facts {
	return Facts{DNS: "GeoHide (EU)", DNSAgrees: true, Telegram: "вкл:1450 соединений=12 ошибок=3", TelegramAgrees: true, Tunnel: "вкл:Nimb", TunnelAgrees: true,
		Routes: 2, Interface: "Nimb", MemoryMegabytes: 41}
}

func TestTheBlackBoxLineIsReadableByAProgram(t *testing.T) {
	now := time.Date(2026, 10, 29, 12, 5, 0, 0, time.Local)
	line := Line(now, 3*time.Hour+7*time.Minute, facts())
	for _, want := range []string{"2026-10-29 12:05:00", "работает=3ч07м", "dns=GeoHide (EU) совпало=да", "telegram=вкл:1450 соединений=12 ошибок=3 совпало=да",
		"туннель=вкл:Nimb совпало=да маршрутов=2", "трафик_через=Nimb", "память=41МБ"} {
		if !strings.Contains(line, want) {
			t.Errorf("no %q in %q", want, line)
		}
	}
	if strings.Contains(line, "рукопожатие") {
		t.Error("the age of the answer is only there when it is known")
	}
	f := facts()
	f.HandshakeAgo, f.DNSAgrees = ptr(95), false
	line = Line(now, 0, f)
	if !strings.Contains(line, "рукопожатие=95с") || !strings.Contains(line, "dns=GeoHide (EU) совпало=НЕТ") {
		t.Errorf("%q", line)
	}
}

func TestTheBlackBoxKeepsADayOfLines(t *testing.T) {
	var lines []string
	for i := 0; i < 300; i++ {
		lines = append(lines, string(rune('a'+i%26)))
	}
	kept := Trimmed(lines)
	if len(kept) != KeepLines || kept[len(kept)-1] != lines[299] {
		t.Errorf("kept %d lines", len(kept))
	}
	if len(Trimmed(lines[:10])) != 10 {
		t.Error("a short box stays as it is")
	}
}

func TestTheDigestGoesOnceADay(t *testing.T) {
	last := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	if DigestDue(last.Add(23*time.Hour), last) || !DigestDue(last.Add(24*time.Hour), last) {
		t.Error("a day between the digests")
	}
}

func TestTheDigestCountsWhatCameAfterTheLastDigestAndNothingBefore(t *testing.T) {
	base := time.Date(2026, 10, 28, 8, 0, 0, 0, time.Local)
	var all []string
	for i := 0; i < 10; i++ {
		f := facts()
		f.TelegramAgrees = i%2 == 0
		all = append(all, Line(base.Add(time.Duration(i)*5*time.Minute), 0, f))
	}
	// The last digest was at 08:20: the lines of 08:25 and later are new (the one at 08:20 itself was counted before).
	got := LinesSince(all, base.Add(20*time.Minute))
	if len(got) != 5 || !strings.HasPrefix(got[0], "2026-10-28 08:25:00") {
		t.Fatalf("got %d lines, first %q", len(got), got[0])
	}
	again := LinesSince(all, base.Add(20*time.Minute+time.Second))
	if len(again) != 5 {
		t.Error("a second after, the same lines")
	}
	if len(LinesSince(all, base.Add(time.Hour))) != 0 || len(LinesSince([]string{"мусор", ""}, base)) != 0 {
		t.Error("nothing newer, and lines without a time are skipped")
	}
}

func TestTheDigestSaysWhatDidNotAgreeAndWhenTheServerWasSilent(t *testing.T) {
	base := time.Date(2026, 10, 28, 8, 0, 0, 0, time.Local)
	var lines []string
	for i := 0; i < 6; i++ {
		f := facts()
		f.TelegramAgrees = i != 1
		f.MemoryMegabytes = 40 + i
		if i >= 3 {
			f.HandshakeAgo = ptr(400 + i)
			f.TunnelAgrees = false
		} else {
			f.HandshakeAgo = ptr(60)
		}
		lines = append(lines, Line(base.Add(time.Duration(i)*5*time.Minute), 0, f))
	}
	text := Summary(lines, []string{"mismatch-tunnel", "daily"})
	for _, want := range []string{"Записей чёрного ящика: 6 из 288", "с 2026-10-28 08:00:00 по 2026-10-28 08:25:00", "около 30 мин", "dns: не совпало в 0 записях",
		"telegram: не совпало в 1 записях", "туннель: не совпало в 3 записях", "сервер не отвечал: в 3 записях", "Память: до 45 МБ, в последней записи 45 МБ",
		"Отчётов по сбоям за это время: 2 (mismatch-tunnel, daily)"} {
		if !strings.Contains(text, want) {
			t.Errorf("no %q in\n%s", want, text)
		}
	}
	empty := Summary(nil, nil)
	if !strings.Contains(empty, "Записей чёрного ящика: 0 из 288") || strings.Contains(empty, "Период") || strings.Contains(empty, "Память") || !strings.Contains(empty, "Отчётов по сбоям за это время: 0") {
		t.Errorf("an empty digest:\n%s", empty)
	}
}
