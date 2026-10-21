// Package probe checks how the AI services answer through each Smart DNS provider, without changing the DNS of the system: the
// DNS server of the provider is asked directly, then every address it returns is requested over HTTPS. It is the port of
// Sources/Nimb/ServiceProbe.swift: the targets, the words of a refusal and the thresholds are the same (a test compares the lists),
// and the rules that judge an answer are plain functions with no network (probe_test.go).
package probe

import (
	"net/url"
	"slices"
	"strings"
)

// Kind tells a site of a service from its API.
type Kind int

const (
	Site Kind = iota
	API
)

// Target is one address the check requests: a site or an API endpoint of an AI service.
type Target struct {
	Service string
	Host    string
	Kind    Kind
	Path    string
}

// All are the targets. The APIs are asked without a key: a service that lets the request in answers "no key" (401, or 400/404), a
// service that refuses the region or the address answers 403 or a block page. The sites sit behind a browser check, so for them
// the answer mostly shows that they can be reached. The list mirrors ProbeTarget.all of the Mac app.
var All = []Target{
	{"ChatGPT", "chatgpt.com", Site, "/"},
	{"ChatGPT", "api.openai.com", API, "/v1/models"},
	{"Claude", "claude.ai", Site, "/"},
	{"Claude", "api.anthropic.com", API, "/v1/models"},
	{"Gemini", "gemini.google.com", Site, "/app"},
	{"Gemini", "generativelanguage.googleapis.com", API, "/v1beta/models?key=nimb-probe"},
	{"Grok", "grok.com", Site, "/"},
	{"Grok", "api.x.ai", API, "/v1/models"},
	{"ElevenLabs", "elevenlabs.io", Site, "/"},
	{"ElevenLabs", "api.elevenlabs.io", API, "/v1/models"},
}

// Services are the names of the services in the order of All, without repeats.
func Services() []string {
	var names []string
	for _, t := range All {
		if !slices.Contains(names, t.Service) {
			names = append(names, t.Service)
		}
	}
	return names
}

// Status is how the request ended.
type Status int

const (
	// OK: the service answered as it does to a visitor it lets in.
	OK Status = iota
	// Blocked: the service answered, but with a refusal: another region, an address it does not trust, a limit.
	Blocked
	// Failed: no answer, or a server error.
	Failed
)

// Outcome is how one request ended.
type Outcome struct {
	Status  Status
	Seconds float64 // the time to the first byte of a normal answer
	Reason  string  // why it was refused
}

// Sample is the result of one HTTPS request to one pool address of a provider.
type Sample struct {
	Target  Target
	Address string // empty: the provider gave no usable address for the name
	Outcome Outcome
}

// refusalWords are the words in a redirect address that mark a page about restrictions rather than the service itself.
var refusalWords = []string{"sorry", "restrict", "region", "countr", "unavailable", "blocked", "denied", "forbidden", "not-available"}

// refusalPhrases are the phrases the services use when they turn a region or an address away. Lower case.
var refusalPhrases = []string{
	"unsupported_country", "country, region, or territory not supported", "not available in your country",
	"isn't available in your country", "not available in your region", "isn't available in your region",
	"not supported in your country", "not supported in your region", "unavailable in your", "not available in your location",
	"user location is not supported", "request not allowed", "access denied",
}

// bigBody is the size from which a page is one of the apps and not a refusal page.
const bigBody = 30_000

// Classify tells a normal answer from a refusal. A page that merely loads is not a success: a status below 500 used to be enough,
// which counted "not available in your region" as working. The names of the headers are lower case.
func Classify(target Target, code int, seconds float64, bodySize int, headers map[string]string, body string) Outcome {
	if code < 100 || code >= 500 {
		return Outcome{Status: Failed}
	}
	if location := headers["location"]; location != "" {
		if u, err := url.Parse(location); err == nil && u.Hostname() != "" && u.Hostname() != target.Host {
			host := u.Hostname()
			lower := strings.ToLower(location)
			if strings.HasPrefix(host, "help.") || strings.HasPrefix(host, "support.") || containsAny(lower, refusalWords) {
				sorry := ""
				if strings.HasPrefix(u.Path, "/sorry") {
					sorry = "/sorry"
				}
				return Outcome{Status: Blocked, Reason: "перенаправление на " + host + sorry}
			}
		}
	}
	switch code {
	case 451:
		return Outcome{Status: Blocked, Reason: "451: недоступно по юридическим причинам"}
	case 429:
		return Outcome{Status: Blocked, Reason: "429: слишком много запросов с этого адреса"}
	case 403:
		// Cloudflare asks a browser to prove itself; the address is let in, only a program that is not a browser is not.
		if _, ok := headers["cf-mitigated"]; ok {
			return Outcome{Status: OK, Seconds: seconds}
		}
		return Outcome{Status: Blocked, Reason: "403: доступ закрыт"}
	}
	// Refusal pages are short; the big pages of the apps carry such phrases only inside their translations.
	if bodySize < bigBody || strings.Contains(headers["content-type"], "json") {
		lower := strings.ToLower(body)
		for _, phrase := range refusalPhrases {
			if strings.Contains(lower, phrase) {
				return Outcome{Status: Blocked, Reason: "«" + phrase + "»"}
			}
		}
	}
	return Outcome{Status: OK, Seconds: seconds}
}

func containsAny(text string, words []string) bool {
	for _, w := range words {
		if strings.Contains(text, w) {
			return true
		}
	}
	return false
}
