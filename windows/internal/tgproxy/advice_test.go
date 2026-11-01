package tgproxy

import "testing"

func TestTunnelAdviceOnlyWhenTheTunnelIsOffAndConnectionsKeepFailing(t *testing.T) {
	cases := []struct {
		name                        string
		failures, reached           int
		failuresRecently, tunnelOff bool
		want                        TunnelAdvice
	}{
		{"part of the servers", 61, 300, true, true, AdvicePartly},
		{"the tunnel is on or being switched", 61, 300, true, false, AdviceNone},
		{"the errors have stopped", 61, 300, false, true, AdviceNone},
		{"a couple of errors are nothing", 2, 300, true, true, AdviceNone},
		{"nothing gets through: said at once", 2, 0, true, true, AdviceBlocked},
		{"one failure is not yet a block", 1, 0, true, true, AdviceNone},
		{"nothing gets through but the tunnel is on", 9, 0, true, false, AdviceNone},
	}
	for _, c := range cases {
		if got := AdviceFor(c.failures, c.reached, c.failuresRecently, c.tunnelOff); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
	if AdviceBlocked.Words() == AdvicePartly.Words() || AdviceBlocked.Words() == "" || AdviceNone.Words() != "" {
		t.Error("each advice has words of its own, and no advice has none")
	}
}
