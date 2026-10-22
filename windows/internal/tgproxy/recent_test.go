package tgproxy

import (
	"testing"
	"time"
)

func TestARecentGrowthIsNewsForTenSecondsOnly(t *testing.T) {
	now := time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)
	r := RecentCount{Quiet: 10 * time.Second}
	if r.Observe(0, now) {
		t.Error("nothing yet")
	}
	if !r.Observe(3, now.Add(time.Second)) {
		t.Error("three wrong keys just now")
	}
	if !r.Observe(3, now.Add(10*time.Second)) { // 9 s after the growth
		t.Error("still recent after nine seconds")
	}
	if r.Observe(3, now.Add(11*time.Second)) {
		t.Error("ten quiet seconds: the warning goes away")
	}
	if !r.Observe(4, now.Add(30*time.Second)) {
		t.Error("it comes back when they start again")
	}
}

func TestACounterThatWasAlreadyThereWhenWatchingStartedIsNotNews(t *testing.T) {
	now := time.Now()
	r := RecentCount{Quiet: 10 * time.Second}
	// The first look finds 3: that is growth from 0, as on the Mac; a reset after a stop forgets it.
	r.Observe(3, now)
	r.Reset()
	if r.IsRecent(now.Add(time.Second)) {
		t.Error("after a reset nothing is recent")
	}
	if r.Observe(0, now.Add(2*time.Second)) {
		t.Error("an empty counter is not news")
	}
}
