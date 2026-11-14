package startup

import (
	"context"
	"testing"
	"time"
)

func TestStopBeforeStartAndOldCompletionCannotReviveIt(t *testing.T) {
	var c Controller
	c.Cancel("old")
	old, doneOld := c.Begin(context.Background(), "old")
	if old.Err() == nil {
		t.Fatal("a late cancelled start was allowed")
	}
	next, doneNext := c.Begin(context.Background(), "new")
	defer doneNext()
	doneOld()
	if next.Err() != nil {
		t.Fatal("old completion cancelled the new start")
	}
	c.Cancel("new")
	if next.Err() != context.Canceled {
		t.Fatal("running start was not cancelled")
	}
}
func TestOffStopsRecoveryUntilAnExplicitNewStart(t *testing.T) {
	var c Controller
	running, finish := c.Begin(context.Background(), "one")
	defer finish()
	c.Cancel("one")
	recovery, done := c.BeginRecovery(context.Background())
	defer done()
	if running.Err() == nil || recovery.Err() == nil {
		t.Fatal("stop allowed automatic restart")
	}
	next, end := c.Begin(context.Background(), "two")
	defer end()
	if next.Err() != nil {
		t.Fatal("fresh explicit attempt was blocked")
	}
	deadline, ok := next.Deadline()
	if !ok || time.Until(deadline) > 120*time.Second {
		t.Fatal("start has no overall deadline")
	}
}
