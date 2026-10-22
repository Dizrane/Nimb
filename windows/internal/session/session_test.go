package session

import "testing"

func TestAnInstallerThatReplacedTheProgramIsNotACrash(t *testing.T) {
	if bad, from := Interpret("0.1.1", "0.2.0"); bad || from != "0.1.1" {
		t.Errorf("an update from 0.1.1: bad=%v from=%q", bad, from)
	}
	// A newer version replaced by an older one (a downgrade by hand) is the same thing.
	if bad, from := Interpret("0.3.0\n", "0.2.0"); bad || from != "0.3.0" {
		t.Errorf("a downgrade: bad=%v from=%q", bad, from)
	}
}

func TestACutOffRunOfTheSameVersionIsUnexpected(t *testing.T) {
	for _, mark := range []string{"0.2.0", "0.2.0\n", "running", "", "  "} {
		if bad, from := Interpret(mark, "0.2.0"); !bad || from != "" {
			t.Errorf("mark %q: bad=%v from=%q", mark, bad, from)
		}
	}
}
