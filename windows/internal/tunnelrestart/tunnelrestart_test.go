package tunnelrestart

import (
	"testing"
	"time"
)

var now = time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)

func ago(d time.Duration) time.Time { return now.Add(-d) }

func TestAllowedThreeInTenMinutes(t *testing.T) {
	if !Allowed(nil, now) {
		t.Error("the first restart is allowed")
	}
	two := []time.Time{ago(9 * time.Minute), ago(3 * time.Minute)}
	if !Allowed(two, now) {
		t.Error("two restarts: the third is allowed")
	}
	three := []time.Time{ago(9 * time.Minute), ago(5 * time.Minute), ago(time.Minute)}
	if Allowed(three, now) {
		t.Error("three restarts in ten minutes: the fourth is not")
	}
	// The oldest has left the window: allowed again.
	old := []time.Time{ago(11 * time.Minute), ago(5 * time.Minute), ago(time.Minute)}
	if !Allowed(old, now) {
		t.Error("a restart older than ten minutes does not count")
	}
	if Allowed([]time.Time{ago(9*time.Minute + 59*time.Second), ago(2 * time.Minute), ago(time.Second)}, now) {
		t.Error("just inside the window still counts")
	}
}

func TestMarkerIsBelievedForTwoMinutes(t *testing.T) {
	if !IsActive(ago(30*time.Second), now) || !IsActive(ago(119*time.Second), now) {
		t.Error("a fresh mark is active")
	}
	if IsActive(ago(120*time.Second), now) || IsActive(ago(time.Hour), now) {
		t.Error("an old mark is no mark")
	}
}

func TestParseKeepsOnlyTimes(t *testing.T) {
	got := Parse("1790000000\n\n  1790000100 \nnot a time\n-5\n0\n12abc\n1790000200")
	if len(got) != 3 || got[0].Unix() != 1790000000 || got[2].Unix() != 1790000200 {
		t.Errorf("parsed %v", got)
	}
}

func TestRecentIsTheLastDayOldestFirst(t *testing.T) {
	text := "" + itoa(ago(30*time.Hour)) + "\n" + itoa(ago(time.Hour)) + "\n" + itoa(ago(5*time.Hour)) + "\n"
	got := Recent(text, now, 24*time.Hour)
	if len(got) != 2 || !got[0].Equal(ago(5*time.Hour)) || !got[1].Equal(ago(time.Hour)) {
		t.Errorf("recent %v", got)
	}
}

func TestUnseenSkipsWhatTheDiaryHas(t *testing.T) {
	rs := []time.Time{ago(3 * time.Hour), ago(2 * time.Hour), ago(time.Hour)}
	got := Unseen(rs, ago(2*time.Hour).Unix())
	if len(got) != 1 || !got[0].Equal(ago(time.Hour)) {
		t.Errorf("unseen %v", got)
	}
	if len(Unseen(rs, 0)) != 3 {
		t.Error("nothing seen yet: all are news")
	}
}

func TestAddKeepsTheLastFifty(t *testing.T) {
	text := ""
	for i := 0; i < 60; i++ {
		text = Add(text, now.Add(time.Duration(i)*time.Second))
	}
	got := Parse(text)
	if len(got) != Keep || got[0].Unix() != now.Add(10*time.Second).Unix() || got[Keep-1].Unix() != now.Add(59*time.Second).Unix() {
		t.Errorf("kept %d, first %v", len(got), got[0])
	}
}

func TestRestoreRules(t *testing.T) {
	if !ShouldRestore(true, true, true) {
		t.Error("was on, has an account, is off: restore")
	}
	for _, c := range [][3]bool{{false, true, true}, {true, false, true}, {true, true, false}} {
		if ShouldRestore(c[0], c[1], c[2]) {
			t.Errorf("%v: no restore", c)
		}
	}
	if !TriesAgain(true, 0) || !TriesAgain(true, 1) {
		t.Error("a failed start is tried again")
	}
	if TriesAgain(true, 2) {
		t.Error("the third failure is the end")
	}
	if TriesAgain(false, 0) {
		t.Error("a start that worked is not repeated")
	}
	if len(Waits) != 3 || Waits[0] != 0 || Waits[1] != 3*time.Second || Waits[2] != 15*time.Second {
		t.Errorf("waits %v", Waits)
	}
}

func itoa(t time.Time) string { return string(Add("", t)[:len(Add("", t))-1]) }

func TestAStartRightAfterAStopWaitsForTheOldTunnelToSettle(t *testing.T) {
	if SettleWait(time.Hour, false) != 0 || SettleWait(0, false) != 0 {
		t.Error("a tunnel that was never closed: no waiting")
	}
	if got := SettleWait(time.Second, true); got != time.Second {
		t.Errorf("one second after: %v", got)
	}
	if got := SettleWait(0, true); got != SettleAfterClose {
		t.Errorf("at once: %v", got)
	}
	if SettleWait(SettleAfterClose, true) != 0 || SettleWait(time.Minute, true) != 0 {
		t.Error("long enough after: no waiting")
	}
	if got := SettleWait(-time.Second, true); got != SettleAfterClose {
		t.Errorf("a clock that went back: %v", got)
	}
	if len(AttemptTimeouts) != 2 || AttemptTimeouts[0] >= AttemptTimeouts[1] {
		t.Errorf("%v", AttemptTimeouts)
	}
}
