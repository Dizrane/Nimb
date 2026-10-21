package probe

import (
	"fmt"
	"slices"
	"strings"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

// ServiceStatus is how one AI service (its site and API together) answered through a provider.
type ServiceStatus string

const (
	Works    ServiceStatus = "works"
	Unstable ServiceStatus = "unstable"
	Down     ServiceStatus = "down"
	Refused  ServiceStatus = "blocked"
)

// WorkingShare: one dead address in a pool of five still leaves the service working, so 75% is enough.
const WorkingShare = 0.75

// NoticeableDifference: differences in the median time below this (seconds) are noise and do not decide the ranking.
const NoticeableDifference = 0.1

// ServiceResult counts the requests of one service.
type ServiceResult struct {
	Name     string
	Answered int
	Blocked  int // requests that were answered with a refusal (region, address, limit)
	Total    int
}

// Status judges the service by its counts.
func (r ServiceResult) Status() ServiceStatus {
	if r.Answered == 0 {
		if r.Blocked > 0 {
			return Refused
		}
		return Down
	}
	// A dead address is skipped by the browser, but a refusal page is not: it hits every visit that lands on that address.
	if r.Blocked > 0 {
		return Unstable
	}
	if float64(r.Answered)/float64(r.Total) >= WorkingShare {
		return Works
	}
	return Unstable
}

// ProviderReport is what the check found out about one provider.
type ProviderReport struct {
	Provider dnsx.Provider
	Samples  []Sample
}

func (s Sample) ok() bool { return s.Outcome.Status == OK }

// Services are the results per service, in the order of the targets.
func (r ProviderReport) Services() []ServiceResult {
	var out []ServiceResult
	for _, name := range Services() {
		res := ServiceResult{Name: name}
		for _, s := range r.Samples {
			if s.Target.Service != name {
				continue
			}
			res.Total++
			switch s.Outcome.Status {
			case OK:
				res.Answered++
			case Blocked:
				res.Blocked++
			}
		}
		out = append(out, res)
	}
	return out
}

// WorkingCount is the number of services that work.
func (r ProviderReport) WorkingCount() int {
	n := 0
	for _, s := range r.Services() {
		if s.Status() == Works {
			n++
		}
	}
	return n
}

// Median is the median time to the first byte of the normal answers; ok is false when there was none.
func (r ProviderReport) Median() (seconds float64, ok bool) {
	var times []float64
	for _, s := range r.Samples {
		if s.ok() {
			times = append(times, s.Outcome.Seconds)
		}
	}
	if len(times) == 0 {
		return 0, false
	}
	slices.Sort(times)
	return times[len(times)/2], true
}

// Refusals are the refusals with the address and the reason, such as "Gemini · 143.20.64.192: перенаправление на google.com/sorry".
func (r ProviderReport) Refusals() []string {
	var lines []string
	for _, s := range r.Samples {
		if s.Outcome.Status != Blocked {
			continue
		}
		addr := s.Address
		if addr == "" {
			addr = "?"
		}
		line := fmt.Sprintf("%s · %s: %s", s.Target.Service, addr, s.Outcome.Reason)
		if !slices.Contains(lines, line) {
			lines = append(lines, line)
		}
	}
	return lines
}

// DeadAddresses are the pool addresses that did not give a normal answer to a single request.
func (r ProviderReport) DeadAddresses() []string {
	answered := map[string]bool{}
	all := map[string]bool{}
	for _, s := range r.Samples {
		if s.Address == "" {
			continue
		}
		all[s.Address] = true
		if s.ok() {
			answered[s.Address] = true
		}
	}
	var dead []string
	for a := range all {
		if !answered[a] {
			dead = append(dead, a)
		}
	}
	slices.Sort(dead)
	return dead
}

// Count is "answered/asked" for the sites or the APIs of a service, such as "2/3".
func (r ProviderReport) Count(service string, kind Kind) string {
	asked, answered := 0, 0
	for _, s := range r.Samples {
		if s.Target.Service == service && s.Target.Kind == kind {
			asked++
			if s.ok() {
				answered++
			}
		}
	}
	return fmt.Sprintf("%d/%d", answered, asked)
}

// Details is the text of the check for a report, such as "Claude: сайт 2/3, API 1/3", then the refusals and the dead addresses.
func (r ProviderReport) Details() string {
	var lines []string
	for _, name := range Services() {
		lines = append(lines, fmt.Sprintf("%s: сайт %s, API %s", name, r.Count(name, Site), r.Count(name, API)))
	}
	for _, line := range r.Refusals() {
		lines = append(lines, "Отказ: "+line)
	}
	if dead := r.DeadAddresses(); len(dead) > 0 {
		lines = append(lines, "Без нормального ответа адреса: "+strings.Join(dead, ", "))
	}
	return strings.Join(lines, "\n")
}

// IsBetter: more working services wins; at the same number a clearly faster median wins.
func (r ProviderReport) IsBetter(than ProviderReport) bool {
	if a, b := r.WorkingCount(), than.WorkingCount(); a != b {
		return a > b
	}
	return medianOrInf(r) < medianOrInf(than)-NoticeableDifference
}

func medianOrInf(r ProviderReport) float64 {
	if m, ok := r.Median(); ok {
		return m
	}
	return 1e18
}

// Best is the report of the best provider, or nil when there are no reports. The first of equals wins, as on the Mac.
func Best(reports []ProviderReport) *ProviderReport {
	var best *ProviderReport
	for i := range reports {
		if best == nil || reports[i].IsBetter(*best) {
			best = &reports[i]
		}
	}
	return best
}

// ServiceView, ProviderView are what the page draws.
type ServiceView struct {
	Name   string        `json:"name"`
	Status ServiceStatus `json:"status"`
	Site   string        `json:"site"`
	API    string        `json:"api"`
}

type ProviderView struct {
	ID       string        `json:"id"`
	Working  int           `json:"working"`
	Total    int           `json:"total"`
	Median   *float64      `json:"median,omitempty"` // seconds
	Services []ServiceView `json:"services"`
	Refusals []string      `json:"refusals"`
	Dead     []string      `json:"dead"`
}

// View is the report as the page draws it.
func (r ProviderReport) View() ProviderView {
	v := ProviderView{ID: r.Provider.ID, Working: r.WorkingCount(), Total: len(Services()), Refusals: r.Refusals(), Dead: r.DeadAddresses()}
	if v.Refusals == nil {
		v.Refusals = []string{}
	}
	if v.Dead == nil {
		v.Dead = []string{}
	}
	if m, ok := r.Median(); ok {
		v.Median = &m
	}
	for _, s := range r.Services() {
		v.Services = append(v.Services, ServiceView{Name: s.Name, Status: s.Status(), Site: r.Count(s.Name, Site), API: r.Count(s.Name, API)})
	}
	return v
}

// Lines is the check as lines of a report (the section "Проверка DNS" of the report of the Mac, with the refusals and the addresses
// that did not answer added: those are what tells a half-dead pool from a refusal).
func Lines(reports []ProviderReport) []string {
	var lines []string
	for _, r := range reports {
		var counts []string
		for _, s := range r.Services() {
			counts = append(counts, fmt.Sprintf("%s %d/%d", s.Name, s.Answered, s.Total))
		}
		line := fmt.Sprintf("%s: работает %d из %d (%s)", r.Provider.Name, r.WorkingCount(), len(Services()), strings.Join(counts, ", "))
		if m, ok := r.Median(); ok {
			line += fmt.Sprintf(", медиана %.1f с", m)
		}
		lines = append(lines, line)
		for _, l := range r.Refusals() {
			lines = append(lines, "  отказ: "+l)
		}
		if dead := r.DeadAddresses(); len(dead) > 0 {
			lines = append(lines, "  без нормального ответа: "+strings.Join(dead, ", "))
		}
	}
	return lines
}

// Addresses are the addresses the providers gave, without repeats. They are public, so they may stay in a report.
func Addresses(reports []ProviderReport) []string {
	var out []string
	for _, r := range reports {
		for _, s := range r.Samples {
			if s.Address != "" && !slices.Contains(out, s.Address) {
				out = append(out, s.Address)
			}
		}
	}
	return out
}
