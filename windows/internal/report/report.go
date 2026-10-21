// Package report makes and sends the report about a problem. It is the port of Sources/Nimb/Report: the text of a report holds
// what the person wrote, the state of the three services, a few facts of the network and the end of the diary, and nothing that
// names the person (Clean takes it out).
package report

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

// Endpoint is the small relay that forwards reports to the developer (report-relay/ in the repository). NIMB_REPORT_URL exists
// for tests only.
func Endpoint() string {
	if u := os.Getenv("NIMB_REPORT_URL"); u != "" {
		return u
	}
	return "https://nimb-report.nimb-app.workers.dev/"
}

// DeveloperHandle is where a person can write by hand when the report cannot be sent: the developer in Telegram.
const DeveloperHandle = "i17th"

// MessageLimit is what one Telegram message takes.
const MessageLimit = 4000

// sendLimit: the relay takes at most 100 KB; a longer report loses the middle of the diary, not its head or its end.
const sendLimit = 60_000

// Environment says what names the person on this computer; Clean takes it out of a text.
type Environment struct {
	Home         string // the folder of the person, such as C:\Users\Ann
	UserName     string
	ComputerName string
	// Connections are the names of the network connections of this computer: a name that Windows did not give by itself was chosen
	// by someone (a router, a phone, a company) and does not go into a report (ReportRedactor.swift does the same on the Mac).
	Connections []string
	// Public are addresses that name nobody and stay as they are: the pool addresses of the providers that the check found.
	Public []string
}

// genericConnections are the names Windows gives to connections itself, in English and in Russian.
var genericConnections = regexp.MustCompile(`^(Wi-Fi|Ethernet|Local Area Connection|Wireless Network Connection|Bluetooth Network Connection|Беспроводная сеть|Подключение по локальной сети|Сетевое подключение Bluetooth)( \d+)?$|^vEthernet \((Default Switch|WSL.*)\)$|^(Loopback Pseudo-Interface \d+|Teredo Tunneling Pseudo-Interface|Nimb)$|^isatap\.`)

// IsGenericConnection tells a name that Windows gave from one that someone chose.
func IsGenericConnection(name string) bool { return genericConnections.MatchString(name) }

var (
	reEmail  = regexp.MustCompile(`[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}`)
	reIPv4   = regexp.MustCompile(`\b(?:\d{1,3}\.){3}\d{1,3}\b`)
	reIPv6   = regexp.MustCompile(`\b[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){3,7}\b`)
	reKey    = regexp.MustCompile(`[A-Za-z0-9+/=_\-]{32,}`)
	reUsers  = regexp.MustCompile(`(?i)([A-Za-z]:[\\/]Users[\\/])[^\\/\s"'<>|:*?]+`)
	reRepeat = regexp.MustCompile(`(‹[^›]+›)(?:, ?‹[^›]+›)+`)
)

// Clean takes out of a text what a person would not want to send: addresses, e-mails, the name of the user and of the computer
// and long keys. A known address of a Smart DNS provider of Nimb is replaced with its name, so that the report still says which
// one it was.
func Clean(text string, env Environment) string {
	// What stays is put aside under a mark that nothing below can touch, and comes back at the end.
	for i, a := range env.Public {
		text = strings.ReplaceAll(text, a, fmt.Sprintf("⟦%d⟧", i))
	}
	for _, p := range dnsx.Providers {
		for _, a := range p.Addresses {
			text = strings.ReplaceAll(text, a, "‹"+p.Name+"›")
		}
	}
	if env.Home != "" {
		text = replaceFold(text, env.Home, "~")
		text = replaceFold(text, strings.ReplaceAll(env.Home, `\`, "/"), "~")
	}
	text = reUsers.ReplaceAllString(text, "${1}‹user›")
	if utf8.RuneCountInString(env.UserName) >= 4 {
		text = replaceFold(text, env.UserName, "‹user›")
	}
	if utf8.RuneCountInString(env.ComputerName) >= 4 {
		text = replaceFold(text, env.ComputerName, "‹pc›")
	}
	number := 0
	for _, name := range env.Connections {
		if utf8.RuneCountInString(name) >= 3 && !IsGenericConnection(name) {
			number++
			text = replaceWord(text, name, fmt.Sprintf("‹подключение %d›", number))
		}
	}
	text = reEmail.ReplaceAllString(text, "‹e-mail›")
	text = reIPv4.ReplaceAllString(text, "‹ip›")
	text = reIPv6.ReplaceAllString(text, "‹ipv6›")
	text = reKey.ReplaceAllString(text, "‹ключ›")
	for i, a := range env.Public {
		text = strings.ReplaceAll(text, fmt.Sprintf("⟦%d⟧", i), a)
	}
	return collapse(text)
}

// replaceWord replaces name where it stands alone (not inside a longer word or number).
func replaceWord(text, name, with string) string {
	var out strings.Builder
	rest := text
	for {
		i := strings.Index(rest, name)
		if i < 0 {
			break
		}
		before, _ := utf8.DecodeLastRuneInString(rest[:i])
		after, _ := utf8.DecodeRuneInString(rest[i+len(name):])
		if i == 0 && out.Len() > 0 {
			before, _ = utf8.DecodeLastRuneInString(out.String())
		}
		inside := func(r rune) bool { return r != utf8.RuneError && (unicode.IsLetter(r) || unicode.IsDigit(r)) }
		out.WriteString(rest[:i])
		if inside(before) || inside(after) {
			out.WriteString(name)
		} else {
			out.WriteString(with)
		}
		rest = rest[i+len(name):]
	}
	out.WriteString(rest)
	return out.String()
}

// collapse reads two addresses of one service ("‹A›, ‹A›") as one name; different names stay as they are.
func collapse(text string) string {
	return reRepeat.ReplaceAllStringFunc(text, func(run string) string {
		parts := strings.Split(strings.ReplaceAll(run, ", ", ","), ",")
		var out []string
		for _, p := range parts {
			if len(out) == 0 || out[len(out)-1] != p {
				out = append(out, p)
			}
		}
		return strings.Join(out, ", ")
	})
}

// replaceFold replaces every occurrence of old without regard to the case (names of folders on Windows are case-insensitive).
func replaceFold(text, old, with string) string {
	if old == "" {
		return text
	}
	return regexp.MustCompile(`(?i)`+regexp.QuoteMeta(old)).ReplaceAllLiteralString(text, with)
}

// Head is the top of the report: the number, what the person wrote, how to answer.
func Head(id, description, contact string, env Environment) string {
	lines := []string{"Отчёт № " + id, "", "Что случилось:"}
	description = strings.TrimSpace(description)
	if description == "" {
		lines = append(lines, "(не описано)")
	} else {
		lines = append(lines, Clean(description, env))
	}
	if reply := strings.TrimSpace(contact); reply != "" {
		lines = append(lines, "", "Как ответить: "+reply)
	}
	return strings.Join(lines, "\n")
}

// Fitted cuts the report to what one Telegram message takes: the oldest lines of the diary go first, the head and the facts stay.
func Fitted(text string, limit int) string {
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	lines := strings.Split(text, "\n")
	log := -1
	for i, l := range lines {
		if strings.HasPrefix(l, "— Журнал") {
			log = i
			break
		}
	}
	if log < 0 {
		return string([]rune(text)[:limit])
	}
	for utf8.RuneCountInString(strings.Join(lines, "\n")) > limit && len(lines) > log+2 {
		lines = append(lines[:log+1], lines[log+2:]...)
	}
	return string([]rune(strings.Join(lines, "\n"))[:min(limit, utf8.RuneCountInString(strings.Join(lines, "\n")))])
}

// NewID is six letters and digits without look-alikes (no 0, O, 1, I).
func NewID() string {
	const letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 6)
	rand.Read(b)
	for i := range b {
		b[i] = letters[int(b[i])%len(letters)]
	}
	return string(b)
}

// Section is a titled block of lines.
func Section(title string, lines ...string) string {
	return "— " + title + " —\n" + strings.Join(lines, "\n")
}

// Send posts the report to the relay.
func Send(ctx context.Context, appVersion, id, text string) error {
	if utf8.RuneCountInString(text) > sendLimit {
		r := []rune(text)
		text = string(r[:sendLimit/2]) + "\n…\n" + string(r[len(r)-sendLimit/2:])
	}
	body, _ := json.Marshal(map[string]any{"v": 1, "id": id, "app": appVersion, "platform": "windows", "text": text})
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "POST", Endpoint(), bytes.NewReader(body))
	if err != nil {
		return errors.New("Отправка из приложения пока не настроена.")
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return errors.New("Сервер отчётов не ответил за 20 секунд.")
		}
		return errors.New("Не удалось соединиться с сервером отчётов.")
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode == 429:
		return errors.New("Отчётов слишком много, попробуйте через несколько минут.")
	default:
		return fmt.Errorf("Сервер отчётов отказал (код %d).", resp.StatusCode)
	}
}
