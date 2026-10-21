package browserdns

import "testing"

func TestSwitchedOff(t *testing.T) {
	cases := []struct {
		prefs string
		off   bool
	}{
		{``, false},
		{`user_pref("browser.startup.page", 3);`, false},
		{`user_pref("network.trr.mode", 5);`, true},
		{`user_pref("network.trr.mode", 0);`, true},
		{`user_pref("network.trr.mode",2);`, false},
		{`user_pref( "network.trr.mode" , 3 );`, false},
		{`user_pref("network.trr.mode", 2);` + "\n" + `user_pref("network.trr.mode", 5);`, true},  // the last line wins
		{`user_pref("network.trr.mode", 5);` + "\n" + `user_pref("network.trr.mode", 3);`, false}, // and again
		{`user_pref("network.trr.modeX", 5);`, false},
	}
	for _, c := range cases {
		if got := SwitchedOff(c.prefs); got != c.off {
			t.Errorf("%q: %v, want %v", c.prefs, got, c.off)
		}
	}
}

func TestFirefoxWarning(t *testing.T) {
	off, on := `user_pref("network.trr.mode", 5);`, `user_pref("a", 1);`
	if FirefoxWarning(false, []string{on}) != "" {
		t.Error("no Firefox, nothing to say")
	}
	if FirefoxWarning(true, nil) != "" {
		t.Error("a Firefox that never started has no profile")
	}
	if FirefoxWarning(true, []string{off, off}) != "" {
		t.Error("switched off everywhere")
	}
	if FirefoxWarning(true, []string{off, on}) != FirefoxText {
		t.Error("one profile that has it on is enough")
	}
	if FirefoxWarning(true, []string{""}) != FirefoxText {
		t.Error("a profile with nothing set has the default (on)")
	}
}
