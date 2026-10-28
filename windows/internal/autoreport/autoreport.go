// Package autoreport is the rules of «Помогать тестированию» that need no program around them: what counts as a fault, how often a report
// may go, what the black box writes and what the digest of the day says. It is the port of the pure parts of Sources/Nimb/Report/AutoReporter.swift
// and BlackBox.swift; the window (cmd/nimb) brings the facts and does the sending.
package autoreport

import (
	"fmt"
	"strings"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

// ---- what is a fault --------------------------------------------------------------------------------------------------------------

// TelegramAgrees: the proxy of Telegram does what it should, it listens while it is on and does not listen while it is off. How many of its
// connections fail is not counted: it is the network's (a provider that has closed the addresses of Telegram makes nine of ten fail, and
// nothing in Nimb can mend that; the manual report still shows the numbers).
func TelegramAgrees(running, listening bool) bool {
	if running {
		return listening
	}
	return !listening
}

// TunnelErrorIsOurs: an error of the tunnel that Nimb can do something about. «Нет рукопожатия» (the server does not answer) is not one: the
// network of a university, an office or a hotel lets no tunnel through, and Nimb cannot mend that. The words that are the tunnel's own
// news (it stopped by itself) have their own trigger.
func TunnelErrorIsOurs(message string) bool {
	return !(strings.HasPrefix(message, "Туннель остановился") || strings.HasPrefix(message, "Туннель выключился") ||
		strings.Contains(message, "рукопожатия") || strings.Contains(message, "сервер не ответил"))
}

// DNSAgrees: the settings are as Nimb set them, its DNS stands on every connection when it is on, and nowhere when it is off. Whom the system
// really asks is left out here (another VPN or a browser with its own DNS may take it over, and that is not ours to mend); the manual
// report shows it. active is nil when Smart DNS is off.
func DNSAgrees(active *dnsx.Provider, adapters []dnsx.Adapter) bool {
	if active == nil {
		for _, a := range adapters {
			for _, p := range dnsx.Providers {
				if dnsx.Same(a.NameServer, p.Servers()) {
					return false
				}
			}
		}
		return true
	}
	if len(adapters) == 0 {
		return false
	}
	for _, a := range adapters {
		if !dnsx.Same(a.NameServer, active.Servers()) {
			return false
		}
	}
	return true
}

// DNSTakenByOthers: Smart DNS is on, and every connection that does not have it has the DNS of someone else (another program, a VPN, the
// person). That is not a fault of Nimb. A connection with no DNS of its own (the network hands it out) is not «someone else»: a new network
// that Nimb did not take over is a gap that is ours.
func DNSTakenByOthers(active *dnsx.Provider, adapters []dnsx.Adapter) bool {
	if active == nil {
		return false
	}
	others := 0
	for _, a := range adapters {
		if dnsx.Same(a.NameServer, active.Servers()) {
			continue
		}
		if strings.TrimSpace(a.NameServer) == "" {
			return false
		}
		others++
	}
	return others > 0
}

// DNSCounts is what the count of a disagreement is fed with: a disagreement of the settings while the internet is gone says nothing about
// Nimb (the Wi-Fi was lost, another program set the DNS again), and one that another program made is not ours, so both count as an
// agreement.
func DNSCounts(agrees, online, takenByOthers bool) bool { return agrees || !online || takenByOthers }

// TunnelAgrees: the tunnel is as the program thinks, when it is on it has its routes and the traffic goes through it; when it is off it has no
// routes. While it is being switched on or off (working) the routes come and go, so nothing is compared.
func TunnelAgrees(on bool, routes int, viaTunnel, working bool) bool {
	if working {
		return true
	}
	if on {
		return routes > 0 && viaTunnel
	}
	return routes == 0
}

// StaleAfter: a tunnel whose server has not answered for this long (a healthy one answers every two minutes) carries the traffic into nothing.
const StaleAfter = 300 // seconds

// TunnelSilent: the tunnel is on, its server has been silent longer than StaleAfter and the internet is not there through it (Cloudflare does
// not see WARP). A silent server with the traffic still going is not a fault. ago is nil when it is not known (the tunnel has just begun).
func TunnelSilent(ago *int, internetThroughTunnel bool) bool {
	return ago != nil && *ago > StaleAfter && !internetThroughTunnel
}

// ---- the causes -------------------------------------------------------------------------------------------------------------------

// Service is one of the three services, with a name for the key (plain letters: the relay and the tags of Telegram take nothing else)
// and a name for people.
type Service string

const (
	DNS      Service = "dns"
	Telegram Service = "telegram"
	Tunnel   Service = "tunnel"
)

func (s Service) Name() string {
	switch s {
	case DNS:
		return "нейросети"
	case Telegram:
		return "Telegram"
	}
	return "YouTube и Discord"
}

// Trigger is why a report went by itself. The same cause has the same Key: the key is what is not repeated.
type Trigger struct {
	Key   string
	Title string
	// IgnoresHourLimit: a cause that is told even when another report went within the hour, the one that matters most.
	IgnoresHourLimit bool
}

var (
	PreviousEndedBadly = Trigger{Key: "crash", Title: "прошлый запуск закончился неожиданно"}
	TunnelRestarted    = Trigger{Key: "tunnel-restarted", Title: "программа туннеля остановилась сама и была запущена снова"}
	TunnelDropped      = Trigger{Key: "tunnel-dropped", Title: "туннель остановился сам и не запустился снова"}
	UpdateCheck        = Trigger{Key: "update-check", Title: "проверка обновлений не удаётся несколько раз подряд"}
	TunnelSilentCause  = Trigger{Key: "tunnel-silent", Title: "туннель включён, но сервер не отвечает больше 10 минут"}
	NewKeysFailed      = Trigger{Key: "keys-failed", Title: "новые ключи туннеля не помогли: туннель по-прежнему не включается", IgnoresHourLimit: true}
	DailyDigestCause   = Trigger{Key: "daily", Title: "ежедневная сводка"}
)

func Mismatch(s Service) Trigger {
	return Trigger{Key: "mismatch-" + string(s), Title: "«" + s.Name() + "» работает не так, как должен, больше 10 минут"}
}

func Error(s Service) Trigger {
	return Trigger{Key: "error-" + string(s), Title: "ошибка при работе с «" + s.Name() + "»"}
}

// ---- how often --------------------------------------------------------------------------------------------------------------------

// Sent is a report that was sent, written down with its key and its time.
type Sent struct {
	Key string    `json:"key"`
	At  time.Time `json:"at"`
}

const (
	// SamePause: the same cause is told once in this time.
	SamePause = 6 * time.Hour
	PerHour   = 1
	PerDay    = 5
)

// Allows says whether a report with this key may go now, given the ones that went.
func Allows(key string, now time.Time, history []Sent, ignoresHourLimit bool) bool {
	hour, day := 0, 0
	for _, s := range history {
		age := now.Sub(s.At)
		if s.Key == key && age < SamePause {
			return false
		}
		if age < time.Hour {
			hour++
		}
		if age < 24*time.Hour {
			day++
		}
	}
	if !ignoresHourLimit && hour >= PerHour {
		return false
	}
	return day < PerDay
}

// Pruned keeps only the last day.
func Pruned(history []Sent, now time.Time) []Sent {
	var out []Sent
	for _, s := range history {
		if now.Sub(s.At) < 24*time.Hour {
			out = append(out, s)
		}
	}
	return out
}

// MismatchLooks: «не так» must last, one look that disagrees is a moment of switching, two in a row (ten minutes) is a fault.
const MismatchLooks = 2

// MismatchTracker counts the looks in a row that disagree.
type MismatchTracker struct{ streaks map[string]int }

// Observe returns true once, when the disagreement of service has lasted long enough.
func (m *MismatchTracker) Observe(service string, agrees bool) bool {
	if m.streaks == nil {
		m.streaks = map[string]int{}
	}
	if agrees {
		m.streaks[service] = 0
		return false
	}
	m.streaks[service]++
	return m.streaks[service] == MismatchLooks
}

// ---- reports that could not go ----------------------------------------------------------------------------------------------------

// PendingItem is a report that could not go (the net was down, which is just when it is wanted).
type PendingItem struct {
	ID      string    `json:"id"`
	Trigger string    `json:"trigger"`
	Install string    `json:"install"`
	Text    string    `json:"text"`
	At      time.Time `json:"at"`
}

const (
	PendingKeepFor   = 24 * time.Hour
	PendingKeepCount = 3
)

// FreshPending are the ones still worth sending: not older than a day, the latest few.
func FreshPending(items []PendingItem, now time.Time) []PendingItem {
	var out []PendingItem
	for _, it := range items {
		if now.Sub(it.At) < PendingKeepFor {
			out = append(out, it)
		}
	}
	if len(out) > PendingKeepCount {
		out = out[len(out)-PendingKeepCount:]
	}
	return out
}

// ---- the number of the installation -----------------------------------------------------------------------------------------------

// NewInstallID is eight letters and digits that cannot be mistaken for each other; `random` gives the bytes (crypto/rand in the program).
func NewInstallID(random func([]byte)) string {
	const letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 8)
	random(b)
	for i := range b {
		b[i] = letters[int(b[i])%len(letters)]
	}
	return string(b)
}

// ---- the black box ----------------------------------------------------------------------------------------------------------------

// KeepLines: a day of lines every five minutes.
const KeepLines = 288

// ReportLines go into a report: five hours.
const ReportLines = 60

// BoxInterval is the clock of the black box.
const BoxInterval = 5 * time.Minute

// Facts is what a line of the black box says about each service: it is on, and the facts agree with that.
type Facts struct {
	DNS             string
	DNSAgrees       bool
	Telegram        string
	TelegramAgrees  bool
	Tunnel          string
	TunnelAgrees    bool
	Routes          int
	Interface       string
	HandshakeAgo    *int // seconds since the server of the tunnel last answered (only while it is on and when known)
	MemoryMegabytes int
}

const stampLayout = "2006-01-02 15:04:05"

// Line is one line of key=value pairs: made to be read by a program (and by a person who knows what the keys are).
func Line(now time.Time, uptime time.Duration, f Facts) string {
	ok := func(v bool) string {
		if v {
			return "да"
		}
		return "НЕТ"
	}
	hours, minutes := int(uptime.Hours()), int(uptime.Minutes())%60
	tunnel := fmt.Sprintf("туннель=%s совпало=%s маршрутов=%d", f.Tunnel, ok(f.TunnelAgrees), f.Routes)
	if f.HandshakeAgo != nil {
		tunnel += fmt.Sprintf(" рукопожатие=%dс", *f.HandshakeAgo)
	}
	return strings.Join([]string{
		now.Format(stampLayout),
		fmt.Sprintf("работает=%dч%02dм", hours, minutes),
		fmt.Sprintf("dns=%s совпало=%s", f.DNS, ok(f.DNSAgrees)),
		fmt.Sprintf("telegram=%s совпало=%s", f.Telegram, ok(f.TelegramAgrees)),
		tunnel,
		"трафик_через=" + f.Interface,
		fmt.Sprintf("память=%dМБ", f.MemoryMegabytes),
	}, " | ")
}

// Trimmed is a day of lines and no more.
func Trimmed(lines []string) []string {
	if len(lines) > KeepLines {
		return lines[len(lines)-KeepLines:]
	}
	return lines
}

// ---- the digest of the day --------------------------------------------------------------------------------------------------------

// DigestEvery: once in 24 hours, with the small things that are not worth a report of their own. It does not count in the limits above (it is
// one a day by its own clock).
const DigestEvery = 24 * time.Hour

func DigestDue(now, last time.Time) bool { return now.Sub(last) >= DigestEvery }

// LinesSince are the lines of the black box written after `since` (the time of the last digest, or of the switch being turned on): the
// digests follow each other with nothing counted twice and nothing missed, even when the program was closed for days. A line starts with
// its time.
func LinesSince(all []string, since time.Time) []string {
	var out []string
	for _, line := range all {
		if len(line) < len(stampLayout) {
			continue
		}
		if at, err := time.ParseInLocation(stampLayout, line[:len(stampLayout)], time.Local); err == nil && at.After(since) {
			out = append(out, line)
		}
	}
	return out
}

// Summary is the time since the last digest in numbers, from the lines of the black box (see Line) and the keys of the reports sent that day.
func Summary(lines, sentKeys []string) string {
	disagreements := map[string]int{"dns": 0, "telegram": 0, "туннель": 0}
	var memory []int
	silent := 0
	for _, line := range lines {
		for _, part := range strings.Split(line, " | ") {
			if strings.Contains(part, "совпало=НЕТ") {
				for name := range disagreements {
					if strings.HasPrefix(part, name+"=") {
						disagreements[name]++
					}
				}
			}
			if v, ok := strings.CutPrefix(part, "память="); ok {
				var n int
				if _, err := fmt.Sscanf(strings.TrimSuffix(v, "МБ"), "%d", &n); err == nil {
					memory = append(memory, n)
				}
			}
			if i := strings.Index(part, "рукопожатие="); i >= 0 {
				var n int
				if _, err := fmt.Sscanf(part[i+len("рукопожатие="):], "%d", &n); err == nil && n > StaleAfter {
					silent++
				}
			}
		}
	}
	out := []string{"— Со времени прошлой сводки в цифрах —", fmt.Sprintf("Записей чёрного ящика: %d из %d", len(lines), KeepLines)}
	// The box keeps the last lines, not the last day: the period says what the numbers are about, and the lines say how long it worked.
	if len(lines) > 0 && len(lines[0]) >= len(stampLayout) && len(lines[len(lines)-1]) >= len(stampLayout) {
		out = append(out, fmt.Sprintf("Период записей: с %s по %s; работы по записям около %d мин", lines[0][:len(stampLayout)], lines[len(lines)-1][:len(stampLayout)], len(lines)*5))
	}
	for _, name := range []string{"dns", "telegram", "туннель"} {
		out = append(out, fmt.Sprintf("%s: не совпало в %d записях", name, disagreements[name]))
	}
	if silent > 0 {
		out = append(out, fmt.Sprintf("туннель включён, но сервер не отвечал: в %d записях", silent))
	}
	if len(memory) > 0 {
		top := memory[0]
		for _, m := range memory {
			top = max(top, m)
		}
		out = append(out, fmt.Sprintf("Память: до %d МБ, в последней записи %d МБ", top, memory[len(memory)-1]))
	}
	reports := fmt.Sprintf("Отчётов по сбоям за это время: %d", len(sentKeys))
	if len(sentKeys) > 0 {
		reports += " (" + strings.Join(sentKeys, ", ") + ")"
	}
	return strings.Join(append(out, reports), "\n")
}
