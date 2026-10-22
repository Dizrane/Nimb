// Package winevents reads what Windows itself wrote about a program of Nimb: the crashes of the program (the Application log, Application
// Error and Windows Error Reporting) and what the service manager did with the service (the System log: it started, stopped, was killed,
// ended with an error). That is the reason and the code of an end that nobody asked for, which no log of Nimb has when the program died.
package winevents

import (
	"regexp"
	"strings"
)

var reBlock = regexp.MustCompile(`(?m)^Event\[\d+\]:\s*$`)

// Summaries cuts the text that `wevtutil qe ... /f:text` prints into events and keeps those that mention one of the words (ignoring case).
// Each event becomes one line: the time, the id, and the first lines of the description (without the empty ones), joined with « | ». The
// events are in the order of the text. At most max are returned.
func Summaries(text string, words []string, max int) []string {
	var out []string
	for _, block := range reBlock.Split(text, -1) {
		lower := strings.ToLower(block)
		found := false
		for _, w := range words {
			if strings.Contains(lower, strings.ToLower(w)) {
				found = true
				break
			}
		}
		if !found {
			continue
		}
		var date, id string
		var desc []string
		inDesc := false
		for _, line := range strings.Split(block, "\n") {
			line = strings.TrimRight(line, "\r")
			trimmed := strings.TrimSpace(line)
			switch {
			case strings.HasPrefix(trimmed, "Date:"):
				date = strings.TrimSpace(strings.TrimPrefix(trimmed, "Date:"))
			case strings.HasPrefix(trimmed, "Event ID:"):
				id = strings.TrimSpace(strings.TrimPrefix(trimmed, "Event ID:"))
			case strings.HasPrefix(trimmed, "Description:"):
				inDesc = true
				if rest := strings.TrimSpace(strings.TrimPrefix(trimmed, "Description:")); rest != "" {
					desc = append(desc, rest)
				}
			case inDesc && trimmed != "":
				if len(desc) < 8 {
					desc = append(desc, trimmed)
				}
			}
		}
		if date == "" && id == "" {
			continue
		}
		out = append(out, date+"  событие "+id+": "+strings.Join(desc, " | "))
		if len(out) >= max {
			break
		}
	}
	return out
}
