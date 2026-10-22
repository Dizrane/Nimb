package report

import (
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

// ServiceCheck is "ждали / увидели": for one of the three services, what must be true when it works, what is there, and whether the
// two agree. A line that disagrees is the first thing a reader of a report looks for. It is the port of ReportChecks.swift.
type ServiceCheck struct {
	Name     string
	Expected string
	Seen     string
	Agrees   bool
}

// Lines is the check as lines of a report.
func (c ServiceCheck) Lines() []string {
	verdict := "РАСХОДИТСЯ"
	if c.Agrees {
		verdict = "совпало"
	}
	return []string{c.Name, "  ждали: " + c.Expected, "  увидели: " + c.Seen, "  итог: " + verdict}
}

// DNSFacts is what the DNS check needs to know.
type DNSFacts struct {
	// Active is the provider of Smart DNS, or nil when it is off.
	Active *dnsx.Provider
	// Adapters are the connections Smart DNS is for, as the system has them now.
	Adapters []dnsx.Adapter
	// The system is asked for Host the way a program asks (the system resolver, which knows the DNS of every connection, IPv6 first,
	// the hosts file and the rest): SystemAnswer is what came back, SystemFailed that nothing came, ProviderAnswer is what the provider
	// itself says for the same name (empty when it did not answer).
	Host           string
	SystemAnswer   []string
	SystemFailed   bool
	ProviderAnswer []string
}

// DNS: Smart DNS must be set on every connection and the system must really get its answers.
func DNS(f DNSFacts) ServiceCheck {
	name := "Нейросети (DNS)"
	total := len(f.Adapters)
	if f.Active == nil {
		ours := 0
		for _, a := range f.Adapters {
			for _, p := range dnsx.Providers {
				if dnsx.Same(a.NameServer, p.Servers()) {
					ours++
					break
				}
			}
		}
		seen := "DNS сервисов Nimb нигде не задан"
		if ours > 0 {
			seen = fmt.Sprintf("DNS сервиса Nimb ещё стоит на %d из %d подключений", ours, total)
		}
		return ServiceCheck{Name: name, Expected: "выключено: DNS сервисов Nimb нигде не задан", Seen: seen, Agrees: ours == 0}
	}
	set, v6, v6taken := 0, 0, 0
	for _, a := range f.Adapters {
		if dnsx.Same(a.NameServer, f.Active.Servers()) {
			set++
		}
		if a.V6 {
			v6++
			if dnsx.Same6(a.NameServer6, f.Active.Servers6()) {
				v6taken++
			}
		}
	}
	seen := fmt.Sprintf("%s задан на %d из %d подключений", f.Active.Name, set, total)
	if v6 > 0 {
		seen += fmt.Sprintf("; у %d есть серверы IPv6 (Windows спрашивает их раньше), из них заняты Nimb: %d", v6, v6taken)
	}
	asks, known := false, false
	switch {
	case f.SystemFailed:
		seen += "; система на " + f.Host + " не ответила"
	case len(f.SystemAnswer) == 0:
		seen += "; ответ системы не удалось узнать"
	default:
		known = true
		asks = inPool(f.SystemAnswer, f.ProviderAnswer)
		if len(f.ProviderAnswer) == 0 {
			known = false
			seen += "; ответ системы на " + f.Host + " получен, но сравнить не с чем (провайдер не ответил)"
		} else if asks {
			seen += "; ответ системы на " + f.Host + " из адресов провайдера"
		} else {
			seen += "; ответ системы на " + f.Host + " НЕ из адресов провайдера (получено адресов: " + fmt.Sprint(len(f.SystemAnswer)) + ")"
		}
	}
	return ServiceCheck{Name: name, Expected: f.Active.Name + " на всех подключениях, и система получает ответы именно от него", Seen: seen,
		Agrees: total > 0 && set == total && known && asks}
}

// inPool: every address of the system's answer is one the provider gives.
func inPool(answer, pool []string) bool {
	for _, a := range answer {
		if !slices.Contains(pool, a) {
			return false
		}
	}
	return len(answer) > 0
}

// TelegramFacts is the proxy of Telegram as the window knows it.
type TelegramFacts struct {
	Running                                         bool
	Port                                            int
	Listening                                       bool
	Total, Failures, WrongSecret, WebSocket, Direct int
}

// Telegram: the port listens, Telegram connects, and no more than a fifth of the connections fail.
func Telegram(f TelegramFacts) ServiceCheck {
	name := "Telegram (прокси)"
	if !f.Running {
		seen := "выключен, порт свободен"
		if f.Listening {
			seen = "выключен, но порт слушается"
		}
		return ServiceCheck{Name: name, Expected: "выключен: порт никто не слушает", Seen: seen, Agrees: !f.Listening}
	}
	listens := "не слушает"
	if f.Listening {
		listens = "слушает"
	}
	seen := fmt.Sprintf("порт %d %s; соединений %d, ошибок %d, чужой ключ %d, через WebSocket %d, напрямую %d", f.Port, listens, f.Total, f.Failures, f.WrongSecret, f.WebSocket, f.Direct)
	if f.Total == 0 {
		seen += " (Telegram ещё не подключался)"
	}
	return ServiceCheck{Name: name, Expected: fmt.Sprintf("порт %d слушает, Telegram подключается, ошибок не больше пятой части", f.Port), Seen: seen,
		Agrees: f.Listening && f.WrongSecret == 0 && f.Failures*5 <= f.Total}
}

// TunnelFacts is the tunnel as the system shows it.
type TunnelFacts struct {
	On bool
	// Routes is the number of routes of the tunnel in the table of the system; Via is the connection the traffic to the internet
	// leaves by; ViaTunnel says that it is the tunnel.
	Routes    int
	Via       string
	ViaTunnel bool
	// Warp is warp= of the answer of Cloudflare ("on", "off", "plus"); empty when it did not answer.
	Warp string
	// Dropped is what the service wrote when the tunnel stopped by itself, lately; empty otherwise.
	Dropped string
	// Restarts are the times in the last day when the program of the tunnel ended by itself and the service started it again.
	Restarts []time.Time
}

// Tunnel: with the tunnel on there are routes, the traffic goes through it and Cloudflare sees WARP; with it off none of that.
func Tunnel(f TunnelFacts) ServiceCheck {
	name := "YouTube и Discord (туннель)"
	cloudflare := "Cloudflare не ответил"
	if f.Warp != "" {
		cloudflare = "warp=" + f.Warp
	}
	seen := fmt.Sprintf("маршрутов туннеля %d; трафик в интернет идёт через %s; %s", f.Routes, f.Via, cloudflare)
	// A tunnel that was started again several times a day works, but something is wrong behind it; it does not change the verdict.
	if n := len(f.Restarts); n > 0 {
		seen += fmt.Sprintf("; программа туннеля сама останавливалась и запускалась снова за сутки: %d (последний раз в %s)", n, f.Restarts[n-1].Format("01-02 15:04"))
	}
	if f.On {
		return ServiceCheck{Name: name, Expected: "маршруты туннеля стоят, трафик идёт через него, Cloudflare видит WARP (warp=on)", Seen: seen,
			Agrees: f.Routes > 0 && f.ViaTunnel && f.Warp == "on"}
	}
	if f.Dropped != "" {
		seen += "; туннель остановился сам (" + f.Dropped + ")"
	}
	return ServiceCheck{Name: name, Expected: "выключен: маршрутов туннеля нет, трафик идёт напрямую (warp=off)", Seen: seen,
		Agrees: f.Routes == 0 && !f.ViaTunnel && f.Warp != "on"}
}

// ---- what may be in the way ---------------------------------------------------------------------------------------------------

// ProxyKinds names the kinds of proxy in a setting of the system: HTTP, HTTPS, SOCKS, PAC. Only the kinds: the addresses are not the
// business of a report. server is the string "host:port" or "http=host:port;https=host:port;socks=host:port".
func ProxyKinds(enabled bool, server, pac string) []string {
	var kinds []string
	add := func(k string) {
		if !slices.Contains(kinds, k) {
			kinds = append(kinds, k)
		}
	}
	if enabled && strings.TrimSpace(server) != "" {
		if !strings.Contains(server, "=") {
			add("HTTP")
		}
		for _, part := range strings.Split(server, ";") {
			scheme, _, found := strings.Cut(strings.TrimSpace(part), "=")
			if !found {
				continue
			}
			switch strings.ToLower(scheme) {
			case "http":
				add("HTTP")
			case "https":
				add("HTTPS")
			case "socks", "socks4", "socks5":
				add("SOCKS")
			}
		}
	}
	if strings.TrimSpace(pac) != "" {
		add("PAC")
	}
	return kinds
}

// HostsMentions are those of domains that have a line of their own in the hosts file (not a comment).
func HostsMentions(hosts string, domains []string) []string {
	var lines []string
	for _, l := range strings.Split(hosts, "\n") {
		l = strings.TrimSpace(l)
		if l != "" && !strings.HasPrefix(l, "#") {
			lines = append(lines, l)
		}
	}
	var out []string
	for _, d := range domains {
		for _, l := range lines {
			if strings.Contains(l, d) {
				out = append(out, d)
				break
			}
		}
	}
	return out
}

// InterferenceFacts is what may be in the way of the three services.
type InterferenceFacts struct {
	WinINet, WinHTTP []string // the kinds of proxy in the settings of the system
	VPNs             int      // connections of a VPN or virtual ones that are up
	Hosts            []string // domains of the services that the hosts file mentions
	WindowVersion    string
	ServiceVersion   string // empty: the service did not say
	UTCOffset        string // "+3"
}

// Interference is the section "Что могло помешать".
func Interference(f InterferenceFacts) []string {
	list := func(kinds []string, empty string) string {
		if len(kinds) == 0 {
			return empty
		}
		return strings.Join(kinds, ", ")
	}
	versions := fmt.Sprintf("окно %s, служба %s", f.WindowVersion, orQ(f.ServiceVersion))
	switch {
	case f.ServiceVersion == "":
		versions += ": службе не удалось ответить"
	case f.ServiceVersion == f.WindowVersion:
		versions += ": совпадают"
	default:
		versions += ": РАЗНЫЕ"
	}
	return []string{
		"Системный прокси (WinINet): " + list(f.WinINet, "не включён"),
		"Системный прокси (WinHTTP): " + list(f.WinHTTP, "не включён"),
		fmt.Sprintf("Включённых VPN и виртуальных подключений: %d", f.VPNs),
		"Записи про нейросети и Telegram в файле hosts: " + list(f.Hosts, "нет"),
		"Версии: " + versions,
		"Часовой пояс: UTC" + f.UTCOffset,
	}
}

func orQ(s string) string {
	if s == "" {
		return "?"
	}
	return s
}

// ---- the chronology -----------------------------------------------------------------------------------------------------------

// Line is a line of a log: when, where it came from ("окно", "служба"), what it says.
type Line struct {
	At      time.Time
	Source  string
	Message string
}

// ParseLog reads the lines of a log of this program ("2026-10-21 22:29:22  message", the time of the computer). Lines that are not of
// that form are left out.
func ParseLog(source string, lines []string, loc *time.Location) []Line {
	var out []Line
	for _, l := range lines {
		if len(l) < 22 {
			continue
		}
		at, err := time.ParseInLocation("2006-01-02 15:04:05", l[:19], loc)
		if err != nil {
			continue
		}
		out = append(out, Line{At: at, Source: source, Message: strings.TrimSpace(l[19:])})
	}
	return out
}

// isNews: the clicks of the person on the pages say what they did, not what happened; the rest (states, errors, versions, starts) is
// the story.
func isNews(l Line) bool {
	return l.Message != "" && !strings.HasPrefix(l.Message, "click ") && !strings.HasPrefix(l.Message, "страница «")
}

// isError tells a line of a log that says something went wrong.
func isError(message string) bool {
	m := strings.ToLower(message)
	for _, word := range []string{"ошибка", "ошибки", "не удалось", "не вышло", "не отправлен", "неожиданно", "error"} {
		if strings.Contains(m, word) {
			return true
		}
	}
	return false
}

// Events are the events of the last day made out of the logs: the states of the services, the errors, the new versions. Clicks are
// left out, a line that comes again and again is told once with a count, and only the last `limit` stay.
func Events(lines []Line, now time.Time, within time.Duration, limit int) []string {
	all := slices.Clone(lines)
	slices.SortStableFunc(all, func(a, b Line) int { return a.At.Compare(b.At) })
	type item struct {
		line  Line
		count int
	}
	var items []item
	for _, l := range all {
		if now.Sub(l.At) > within || !isNews(l) {
			continue
		}
		if n := len(items); n > 0 && items[n-1].line.Source == l.Source && items[n-1].line.Message == l.Message {
			items[n-1].count++
			continue
		}
		items = append(items, item{l, 1})
	}
	if len(items) > limit {
		items = items[len(items)-limit:]
	}
	var out []string
	for _, it := range items {
		// With the seconds, so that the order of what the window did and what the service answered can be read; an error has a mark.
		mark := ""
		if isError(it.line.Message) {
			mark = "⚠ "
		}
		s := fmt.Sprintf("%s [%s] %s%s", it.line.At.Format("01-02 15:04:05"), it.line.Source, mark, it.line.Message)
		if it.count > 1 {
			s += fmt.Sprintf(" (×%d)", it.count)
		}
		out = append(out, s)
	}
	if len(out) == 0 {
		return []string{"за последние сутки событий нет"}
	}
	return out
}

// LogTail is the last `limit` lines of the log of the program of the tunnel; where it wrote nothing there is a word about it.
func LogTail(lines []string, limit int) []string {
	var out []string
	for _, l := range lines {
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, l)
		}
	}
	if len(out) == 0 {
		return []string{"пусто"}
	}
	if len(out) > limit {
		out = out[len(out)-limit:]
	}
	return out
}

// Bytes is an amount of data for a person: "31,8 МБ", "512 КБ", "40 байт".
func Bytes(n int64) string {
	switch {
	case n >= 1<<30:
		return strings.Replace(fmt.Sprintf("%.1f ГБ", float64(n)/(1<<30)), ".", ",", 1)
	case n >= 1<<20:
		return strings.Replace(fmt.Sprintf("%.1f МБ", float64(n)/(1<<20)), ".", ",", 1)
	case n >= 1<<10:
		return fmt.Sprintf("%d КБ", n>>10)
	}
	return fmt.Sprintf("%d байт", n)
}
