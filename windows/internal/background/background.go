// Package background is the setting «Работа в фоне»: with it on, closing the window hides it and Nimb stays at the clock; with it off,
// closing the window quits Nimb as «Выйти» in the menu of the icon does (the proxy, the DNS and the tunnel stay in the service either way).
// It is on until the person turns it off, which is how Nimb for Windows has always behaved.
package background

// Mode is what is stored in the settings of the window. Its zero value is «on», so that settings written before this one existed (and a
// settings file that is missing) mean what the program did then. The field is named for what is stored, the off state, and is
// embedded in the settings, so the file has "backgroundOff": true only when the person turned it off.
type Mode struct {
	Off bool `json:"backgroundOff,omitempty"`
}

// Enabled says whether Nimb stays at the clock when the window is closed.
func (m Mode) Enabled() bool { return !m.Off }

// Enable turns the working in the background on or off.
func (m *Mode) Enable(on bool) { m.Off = !on }

// ClosingQuits says whether closing the window (the cross, Alt+F4) quits Nimb instead of hiding the window.
func (m Mode) ClosingQuits() bool { return m.Off }

// StartsHidden says whether Nimb starts as an icon at the clock, without a window: it was started with Windows (--hidden) and the
// working in the background is on. With it off the window opens, as there would be nothing else to show that Nimb started.
func (m Mode) StartsHidden(args []string) bool {
	if !m.Enabled() {
		return false
	}
	for _, a := range args {
		if a == "--hidden" {
			return true
		}
	}
	return false
}
