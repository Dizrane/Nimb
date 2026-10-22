package winevents

import (
	"strings"
	"testing"
)

const sample = `Event[0]:
  Log Name: Application
  Source: Application Error
  Date: 2026-10-23T04:36:33.123
  Event ID: 1000
  Level: Error
  Description:
Faulting application name: Nimb.exe, version: 0.2.0.0, time stamp: 0x6710
Exception code: 0xc0000005
Fault offset: 0x00001234

Event[1]:
  Log Name: Application
  Source: Chrome
  Date: 2026-10-23T04:40:00.000
  Event ID: 1000
  Description:
Faulting application name: chrome.exe

Event[2]:
  Log Name: System
  Source: Service Control Manager
  Date: 2026-10-23T04:41:00.000
  Event ID: 7034
  Description: The NimbHelper service terminated unexpectedly.  It has done this 1 time(s).
`

func TestOnlyTheEventsOfNimbAreKeptWithTheirCodes(t *testing.T) {
	got := Summaries(sample, []string{"Nimb.exe", "NimbHelper"}, 10)
	if len(got) != 2 {
		t.Fatalf("%q", got)
	}
	if !strings.Contains(got[0], "2026-10-23T04:36:33.123") || !strings.Contains(got[0], "событие 1000") || !strings.Contains(got[0], "Exception code: 0xc0000005") {
		t.Errorf("the code of the crash is missing: %q", got[0])
	}
	if strings.Contains(got[0]+got[1], "chrome") {
		t.Error("an event of another program")
	}
	if !strings.Contains(got[1], "событие 7034: The NimbHelper service terminated unexpectedly") {
		t.Errorf("%q", got[1])
	}
}

func TestAtMostMaxAndNothingForAnEmptyText(t *testing.T) {
	if got := Summaries(sample, []string{"Nimb"}, 1); len(got) != 1 {
		t.Errorf("max: %q", got)
	}
	if got := Summaries("", []string{"Nimb"}, 5); len(got) != 0 {
		t.Errorf("empty: %q", got)
	}
}
