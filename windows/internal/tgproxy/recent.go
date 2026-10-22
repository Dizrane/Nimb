package tgproxy

import "time"

// RecentCount watches a counter that only grows (the connections that came with another key) and says whether it grew a moment ago. The
// time is given by the caller, so that the rule can be tried with any clock. It is the port of RecentCount.swift.
type RecentCount struct {
	// Quiet is how long without growth before the thing is called past.
	Quiet      time.Duration
	lastCount  int
	lastGrowth time.Time
}

// Observe takes the current value of the counter and returns whether it grew less than Quiet ago.
func (r *RecentCount) Observe(count int, now time.Time) bool {
	if count > r.lastCount {
		r.lastGrowth = now
	}
	r.lastCount = count
	return r.IsRecent(now)
}

// IsRecent: the counter grew less than Quiet ago.
func (r *RecentCount) IsRecent(now time.Time) bool {
	return !r.lastGrowth.IsZero() && now.Sub(r.lastGrowth) < r.Quiet
}

// Reset: the counter starts again (the proxy was stopped), nothing counts as recent.
func (r *RecentCount) Reset() { r.lastCount, r.lastGrowth = 0, time.Time{} }
