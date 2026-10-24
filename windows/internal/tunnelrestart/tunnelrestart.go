// Package tunnelrestart is the logic of two things that keep the tunnel going without the person: the service starts the program of the
// tunnel again when it ended by itself, and the window switches the tunnel on again after the computer was restarted. It is the port of
// restart_daemon in Resources/nimb-tunnel.sh and of TunnelRestart and TunnelRestore in Sources/Nimb/Warp/WarpTunnelModel.swift.
package tunnelrestart

import (
	"fmt"
	"slices"
	"strings"
	"time"
)

const (
	// Window and MaxInWindow: a tunnel that dies for the fourth time in ten minutes is left alone (the note of the stop comes), a
	// loop of restarts would only hide what is wrong.
	Window      = 10 * time.Minute
	MaxInWindow = 3
	// MarkerLife: the mark of a restart in progress is believed for this long. A service that died in the middle must not keep the
	// switch on for ever.
	MarkerLife = 2 * time.Minute
	// Keep is how many restarts the file remembers.
	Keep = 50

	// Attempts and Pause: after the computer was restarted the tunnel is switched on up to three times, twenty seconds apart (the network
	// may not be up yet). NetworkWait is how long to wait for the network at most.
	Attempts    = 3
	Pause       = 20 * time.Second
	NetworkWait = 3 * time.Minute
)

// Waits are the pauses before each try to start the program again.
var Waits = []time.Duration{0, 3 * time.Second, 15 * time.Second}

// Allowed tells whether another restart may be made now, given the restarts that were made.
func Allowed(restarts []time.Time, now time.Time) bool {
	n := 0
	for _, r := range restarts {
		if now.Sub(r) < Window {
			n++
		}
	}
	return n < MaxInWindow
}

// IsActive tells whether the mark of a restart in progress, made at markedAt, is still to be believed.
func IsActive(markedAt, now time.Time) bool { return now.Sub(markedAt) < MarkerLife }

// Parse reads the file of restarts: a unix time on each line; anything else is skipped.
func Parse(text string) []time.Time {
	var out []time.Time
	for _, line := range strings.Split(text, "\n") {
		var sec int64
		line = strings.TrimSpace(line)
		if _, err := fmt.Sscan(line, &sec); err != nil || sec <= 0 || fmt.Sprint(sec) != line {
			continue
		}
		out = append(out, time.Unix(sec, 0))
	}
	return out
}

// Recent are the restarts of the last `within`, oldest first.
func Recent(text string, now time.Time, within time.Duration) []time.Time {
	var out []time.Time
	for _, r := range Parse(text) {
		if now.Sub(r) < within {
			out = append(out, r)
		}
	}
	slices.SortFunc(out, func(a, b time.Time) int { return a.Compare(b) })
	return out
}

// Unseen are the restarts of the last day that the diary does not have yet; seen is the time of the last one it has, in unix seconds.
func Unseen(restarts []time.Time, seen int64) []time.Time {
	var out []time.Time
	for _, r := range restarts {
		if r.Unix() > seen {
			out = append(out, r)
		}
	}
	return out
}

// Add puts a restart at the end of the file and keeps the last Keep.
func Add(text string, when time.Time) string {
	lines := strings.Fields(text)
	lines = append(lines, fmt.Sprint(when.Unix()))
	if len(lines) > Keep {
		lines = lines[len(lines)-Keep:]
	}
	return strings.Join(lines, "\n") + "\n"
}

// ShouldRestore: the tunnel is switched on after a restart of the computer when it was on (the last choice of the person), the account
// exists and the tunnel is off now.
func ShouldRestore(wanted, hasAccount, isOff bool) bool { return wanted && hasAccount && isOff }

// TriesAgain: a start that failed (no answer from Cloudflare, the network was not up yet) is tried again, up to Attempts times.
func TriesAgain(failed bool, attempt int) bool { return failed && attempt+1 < Attempts }

// Starting the tunnel right after it was stopped sometimes got no answer from the server (the same start fifteen seconds later worked): the
// old adapter and the socket of the old one may not be gone yet, and the server may not take a new handshake of the same keys at once. So a
// start waits until the old tunnel has been closed for SettleAfterClose, and a start that gets no answer is made once more.
const (
	SettleAfterClose = 2 * time.Second
	RetryPause       = 3 * time.Second
)

// AttemptTimeouts are how long each of the two attempts waits for the handshake.
var AttemptTimeouts = []time.Duration{10 * time.Second, 16 * time.Second}

// SettleWait is how much longer to wait before starting, when the old tunnel was closed sinceClosed ago (zero: it was never closed).
func SettleWait(sinceClosed time.Duration, closedBefore bool) time.Duration {
	if !closedBefore || sinceClosed >= SettleAfterClose {
		return 0
	}
	return SettleAfterClose - max(sinceClosed, 0)
}
