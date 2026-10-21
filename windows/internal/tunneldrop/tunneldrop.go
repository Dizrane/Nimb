// Package tunneldrop is the note that the service leaves when the tunnel stopped by itself: its program (the daemon inside the
// service) ended without being asked to. The service then gives the routes and the DNS back, as for an ordinary switching off, so that
// the internet goes on working, and the window tells the person once. It is the port of the end of watch_network in
// Resources/nimb-tunnel.sh and of TunnelDrop in Sources/Nimb/Warp/WarpTunnelModel.swift.
//
// The tunnel does NOT take itself down for any other reason: not when the server is silent, not after any time. (A guard of that kind
// was tried and taken away: on the Mac it turned off a working tunnel.)
package tunneldrop

import (
	"fmt"
	"strings"
	"time"
)

// The reasons a note can carry.
const (
	// DaemonExited: the program of the tunnel ended without being asked to.
	DaemonExited = "daemon-exited"
	// NoHandshake: a note of the old kind (the server was silent); it is only told about, nothing writes it any more.
	NoHandshake = "no-handshake"
)

// NewsFor: a note older than this is history, not news.
const NewsFor = 24 * time.Hour

// MessageFor is what the person is told for a reason.
func MessageFor(reason string) string {
	if reason == NoHandshake {
		return "Туннель выключился сам: Cloudflare не отвечал несколько минут. Интернет снова работает как обычно. Когда связь вернётся, включите туннель ещё раз."
	}
	return "Туннель остановился сам: его программа неожиданно завершилась. Интернет работает как обычно. Включите туннель ещё раз."
}

// Note is the record of a stop: when and why.
type Note struct {
	When   time.Time
	Reason string
}

// Format is the text of the note, "<unix time> <reason>", as on the Mac.
func (n Note) Format() string { return fmt.Sprintf("%d %s\n", n.When.Unix(), n.Reason) }

// ParseNote reads a note; ok is false for anything that is not one.
func ParseNote(text string) (Note, bool) {
	first, rest, _ := strings.Cut(strings.TrimSpace(text), " ")
	var sec int64
	if _, err := fmt.Sscan(first, &sec); err != nil || sec <= 0 || fmt.Sprint(sec) != first {
		return Note{}, false
	}
	return Note{When: time.Unix(sec, 0), Reason: rest}, true
}

// IsNews tells whether a note has not been told yet and is recent. seen is the time of the last note that was told, in unix seconds.
func IsNews(when time.Time, seen int64, now time.Time) bool {
	return when.Unix() > seen && now.Sub(when) < NewsFor
}

// Unexpected waits until the tunnel is taken down by hand (stop is closed) or its program ends (exited is closed). It returns true
// only for the end of the program that nobody asked for: a switching off by the person closes stop first and leaves no note.
func Unexpected(stop, exited <-chan struct{}) bool {
	select {
	case <-stop:
		return false
	case <-exited:
	}
	// Both may be ready at once (switching off closes the program too): the person's switching off wins.
	select {
	case <-stop:
		return false
	default:
		return true
	}
}
