//go:build windows

package winevents

import (
	"context"
	"os/exec"
	"syscall"
	"time"
)

// Query asks the event log (name: "Application" or "System") for the events of the last `within` that mention one of the words, newest first.
// An xpath keeps the question short: only the sources and ids that matter, only the last day.
func Query(name, xpathFilter string, within time.Duration, words []string, max int) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	q := "*[System[" + xpathFilter + " and TimeCreated[timediff(@SystemTime) <= " + itoa(int64(within/time.Millisecond)) + "]]]"
	cmd := exec.CommandContext(ctx, "wevtutil", "qe", name, "/q:"+q, "/c:60", "/rd:true", "/f:text")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	return Summaries(string(out), words, max)
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
