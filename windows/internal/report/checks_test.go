package report

import (
	"strings"
	"testing"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

var eu = dnsx.Providers[0]

func onAdapter(guid string, servers string) dnsx.Adapter {
	return dnsx.Adapter{GUID: guid, Name: guid, NameServer: servers}
}

func TestDNSOnEverywhereAndAnsweredIsAgreed(t *testing.T) {
	pool := []string{"1.1.1.1", "2.2.2.2", "3.3.3.3"}
	c := DNS(DNSFacts{Active: &eu, Adapters: []dnsx.Adapter{onAdapter("a", eu.Servers()), onAdapter("b", eu.Servers())}, Host: "chatgpt.com",
		SystemAnswer: []string{"2.2.2.2"}, ProviderAnswer: pool})
	if !c.Agrees || c.Lines()[3] != "  итог: совпало" || !strings.Contains(c.Seen, "2 из 2") || !strings.Contains(c.Seen, "из адресов провайдера") {
		t.Fatalf("%+v", c)
	}
}

func TestDNSOnButOneConnectionIsAutomaticDisagrees(t *testing.T) {
	c := DNS(DNSFacts{Active: &eu, Adapters: []dnsx.Adapter{onAdapter("a", eu.Servers()), onAdapter("b", "")}, Host: "chatgpt.com",
		SystemAnswer: []string{"2.2.2.2"}, ProviderAnswer: []string{"2.2.2.2"}})
	if c.Agrees || !strings.Contains(c.Seen, "1 из 2") || c.Lines()[3] != "  итог: РАСХОДИТСЯ" {
		t.Fatalf("%+v", c)
	}
}

// set everywhere, but something else decides: the DNS of IPv6, a VPN, a browser of its own, a hosts file
func TestDNSSetEverywhereButTheSystemGetsOtherAddressesDisagrees(t *testing.T) {
	c := DNS(DNSFacts{Active: &eu, Adapters: []dnsx.Adapter{onAdapter("a", eu.Servers())}, Host: "chatgpt.com",
		SystemAnswer: []string{"104.18.1.1"}, ProviderAnswer: []string{"2.2.2.2"}})
	if c.Agrees || !strings.Contains(c.Seen, "НЕ из адресов провайдера") {
		t.Fatalf("%+v", c)
	}
	// one address outside the pool is enough
	c = DNS(DNSFacts{Active: &eu, Adapters: []dnsx.Adapter{onAdapter("a", eu.Servers())}, Host: "x", SystemAnswer: []string{"2.2.2.2", "9.9.9.9"}, ProviderAnswer: []string{"2.2.2.2"}})
	if c.Agrees {
		t.Error("a mix is no agreement")
	}
}

func TestDNSTellsAboutTheServersOfIPv6(t *testing.T) {
	taken := dnsx.Adapter{GUID: "a", NameServer: eu.Servers(), NameServer6: eu.Servers6(), V6: true}
	loose := dnsx.Adapter{GUID: "b", NameServer: eu.Servers(), NameServer6: "2001:db8::1", V6: true}
	c := DNS(DNSFacts{Active: &eu, Adapters: []dnsx.Adapter{taken, loose, onAdapter("c", eu.Servers())}, Host: "h", SystemAnswer: []string{"2.2.2.2"}, ProviderAnswer: []string{"2.2.2.2"}})
	if !strings.Contains(c.Seen, "у 2 есть серверы IPv6") || !strings.Contains(c.Seen, "заняты Nimb: 1") {
		t.Errorf("%s", c.Seen)
	}
}

func TestDNSWithNoAnswerOfTheSystemDisagrees(t *testing.T) {
	for _, f := range []DNSFacts{
		{SystemFailed: true},
		{},
		{SystemAnswer: []string{"2.2.2.2"}}, // the provider did not answer: nothing to compare with
	} {
		f.Active, f.Adapters, f.Host = &eu, []dnsx.Adapter{onAdapter("a", eu.Servers())}, "chatgpt.com"
		if c := DNS(f); c.Agrees {
			t.Errorf("%+v agrees", f)
		}
	}
}

func TestDNSOffIsAgreedWhenNothingOfNimbIsLeft(t *testing.T) {
	if !DNS(DNSFacts{Adapters: []dnsx.Adapter{onAdapter("a", ""), onAdapter("b", "192.168.0.1")}}).Agrees {
		t.Error("nothing of Nimb is left")
	}
	left := DNS(DNSFacts{Adapters: []dnsx.Adapter{onAdapter("a", dnsx.Providers[1].Servers()), onAdapter("b", "")}})
	if left.Agrees || !strings.Contains(left.Seen, "1 из 2") {
		t.Errorf("%+v", left)
	}
}

func TestTelegramAProxyThatWorksIsAgreed(t *testing.T) {
	c := Telegram(TelegramFacts{Running: true, Port: 1443, Listening: true, Total: 18, WebSocket: 18})
	if !c.Agrees || !strings.Contains(c.Seen, "через WebSocket 18") {
		t.Fatalf("%+v", c)
	}
}

func TestTelegramThatHasNotMetTelegramYetIsAgreedAndSaysSo(t *testing.T) {
	c := Telegram(TelegramFacts{Running: true, Port: 1443, Listening: true})
	if !c.Agrees || !strings.Contains(c.Seen, "ещё не подключался") {
		t.Fatalf("%+v", c)
	}
}

func TestTelegramProblems(t *testing.T) {
	for name, f := range map[string]TelegramFacts{
		"the port does not listen": {Running: true, Port: 1443, Total: 3},
		"another key":              {Running: true, Port: 1443, Listening: true, Total: 10, WrongSecret: 1},
		"too many failures":        {Running: true, Port: 1443, Listening: true, Total: 10, Failures: 3},
	} {
		if Telegram(f).Agrees {
			t.Errorf("%s: agrees", name)
		}
	}
	if !Telegram(TelegramFacts{Running: true, Port: 1443, Listening: true, Total: 10, Failures: 2}).Agrees {
		t.Error("a fifth is allowed")
	}
	if !Telegram(TelegramFacts{}).Agrees || Telegram(TelegramFacts{Listening: true}).Agrees {
		t.Error("off: the port must be free")
	}
}

func TestTunnelOnWithRoutesAndWarpIsAgreed(t *testing.T) {
	c := Tunnel(TunnelFacts{On: true, Routes: 2, Via: "Nimb", ViaTunnel: true, Warp: "on"})
	if !c.Agrees {
		t.Fatalf("%+v", c)
	}
	for name, f := range map[string]TunnelFacts{
		"no routes":              {On: true, Via: "Nimb", ViaTunnel: true, Warp: "on"},
		"traffic goes round":     {On: true, Routes: 2, Via: "Wi-Fi", Warp: "on"},
		"Cloudflare is not told": {On: true, Routes: 2, Via: "Nimb", ViaTunnel: true, Warp: "off"},
		"no answer":              {On: true, Routes: 2, Via: "Nimb", ViaTunnel: true},
	} {
		if Tunnel(f).Agrees {
			t.Errorf("%s: agrees", name)
		}
	}
}

func TestTunnelOffAndTheNoteOfTheService(t *testing.T) {
	if !Tunnel(TunnelFacts{Via: "Wi-Fi", Warp: "off"}).Agrees {
		t.Error("off and clean")
	}
	if Tunnel(TunnelFacts{Routes: 2, Via: "Nimb", ViaTunnel: true, Warp: "on"}).Agrees {
		t.Error("off, but the routes are there")
	}
	c := Tunnel(TunnelFacts{Via: "Wi-Fi", Warp: "off", Dropped: "daemon-exited в 10-21 23:40"})
	if !c.Agrees || !strings.Contains(c.Seen, "туннель остановился сам (daemon-exited в 10-21 23:40)") {
		t.Errorf("%+v", c)
	}
	if Tunnel(TunnelFacts{On: true, Routes: 2, Via: "Nimb", ViaTunnel: true, Warp: "on", Dropped: "x"}).Seen != "маршрутов туннеля 2; трафик в интернет идёт через Nimb; warp=on" {
		t.Error("a note is told only for a tunnel that is off")
	}
}

func TestProxyKinds(t *testing.T) {
	for _, c := range []struct {
		enabled     bool
		server, pac string
		want        string
	}{
		{false, "10.0.0.1:8080", "", ""},
		{true, "10.0.0.1:8080", "", "HTTP"},
		{true, "http=a:1;https=b:2;socks=c:3", "", "HTTP,HTTPS,SOCKS"},
		{true, "socks=c:3", "", "SOCKS"},
		{true, "", "", ""},
		{false, "", "http://wpad/x.pac", "PAC"},
		{true, "a:1", "http://wpad/x.pac", "HTTP,PAC"},
	} {
		if got := strings.Join(ProxyKinds(c.enabled, c.server, c.pac), ","); got != c.want {
			t.Errorf("%+v: %q", c, got)
		}
	}
	for _, kind := range ProxyKinds(true, "secret.example:8080", "http://corp.example/proxy.pac") {
		if strings.Contains(kind, ".") {
			t.Errorf("an address in %q", kind)
		}
	}
}

func TestHostsMentionsSkipCommentsAndOtherNames(t *testing.T) {
	hosts := "# 127.0.0.1 chatgpt.com\n\n127.0.0.1 localhost\n0.0.0.0 api.openai.com\n  1.2.3.4   t.me # mine\n"
	got := HostsMentions(hosts, []string{"chatgpt.com", "api.openai.com", "t.me", "claude.ai"})
	if strings.Join(got, ",") != "api.openai.com,t.me" {
		t.Errorf("%v", got)
	}
}

func TestInterferenceLines(t *testing.T) {
	lines := strings.Join(Interference(InterferenceFacts{WinINet: []string{"HTTP"}, VPNs: 2, Hosts: []string{"t.me"}, WindowVersion: "0.1.1", ServiceVersion: "0.1.0", UTCOffset: "+3"}), "\n")
	for _, want := range []string{"WinINet): HTTP", "WinHTTP): не включён", "VPN и виртуальных подключений: 2", "hosts: t.me", "окно 0.1.1, служба 0.1.0: РАЗНЫЕ", "UTC+3"} {
		if !strings.Contains(lines, want) {
			t.Errorf("no %q in\n%s", want, lines)
		}
	}
	if !strings.Contains(strings.Join(Interference(InterferenceFacts{WindowVersion: "0.1.1", ServiceVersion: "0.1.1"}), "\n"), "совпадают") {
		t.Error("same versions")
	}
	if !strings.Contains(strings.Join(Interference(InterferenceFacts{WindowVersion: "0.1.1"}), "\n"), "службе не удалось ответить") {
		t.Error("no answer of the service")
	}
}

// ---- the chronology -----------------------------------------------------------------------------------------------------------

var now = time.Date(2026, 10, 21, 23, 0, 0, 0, time.UTC)

func ago(minutes int, message string) string {
	return now.Add(-time.Duration(minutes)*time.Minute).Format("2006-01-02 15:04:05") + "  " + message
}

func window(lines ...string) []Line { return ParseLog("окно", lines, time.UTC) }

func TestChronologyKeepsTheStatesAndErrors(t *testing.T) {
	got := Events(window(ago(50, "SetAll(true)"), ago(40, "telegram: не удалось запустить прокси"), ago(30, "update: GitHub не ответил")), now, 24*time.Hour, 40)
	if len(got) != 3 || !strings.HasSuffix(got[0], "[окно] SetAll(true)") || !strings.HasSuffix(got[1], "не удалось запустить прокси") {
		t.Fatalf("%v", got)
	}
}

func TestChronologyLeavesOutTheClicksOfThePerson(t *testing.T) {
	got := Events(window(ago(60, "click nav ai"), ago(59, "click prov geohide-us"), ago(20, "SetAll(false)")), now, 24*time.Hour, 40)
	if len(got) != 1 || !strings.Contains(got[0], "SetAll(false)") {
		t.Fatalf("%v", got)
	}
}

func TestChronologyTellsARepeatedLineOnceWithACount(t *testing.T) {
	got := Events(window(ago(30, "probe: x"), ago(29, "ai: ошибка"), ago(28, "ai: ошибка"), ago(27, "ai: ошибка"), ago(26, "probe: x")), now, 24*time.Hour, 40)
	if len(got) != 3 || !strings.HasSuffix(got[1], "ai: ошибка (×3)") {
		t.Fatalf("%v", got)
	}
}

func TestChronologyMergesTheWindowAndTheServiceInTimeOrder(t *testing.T) {
	lines := append(window(ago(10, "SetAll(true)")), ParseLog("служба", []string{ago(30, "bringing the tunnel up"), ago(5, "tunnel is down")}, time.UTC)...)
	got := Events(lines, now, 24*time.Hour, 40)
	if len(got) != 3 || !strings.Contains(got[0], "[служба] bringing") || !strings.Contains(got[1], "[окно]") || !strings.Contains(got[2], "tunnel is down") {
		t.Fatalf("%v", got)
	}
}

func TestChronologyIsOfTheLastDayAndTheLastFortyEvents(t *testing.T) {
	var lines []string
	lines = append(lines, ago(25*60, "старое событие"))
	for i := 0; i < 60; i++ {
		lines = append(lines, ago(120-i, "событие "+string(rune('A'+i%26))+string(rune('a'+i/26))))
	}
	got := Events(window(lines...), now, 24*time.Hour, 40)
	if len(got) != 40 || strings.Contains(strings.Join(got, ""), "старое") || !strings.Contains(got[39], "событие") {
		t.Fatalf("%d lines, first %q", len(got), got[0])
	}
}

func TestChronologyWithNothingSaysSo(t *testing.T) {
	if got := Events(window(ago(60, "click nav ai"), "мусор без времени"), now, 24*time.Hour, 40); len(got) != 1 || got[0] != "за последние сутки событий нет" {
		t.Fatalf("%v", got)
	}
}
