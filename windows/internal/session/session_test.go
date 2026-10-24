package session

import "testing"

func TestAnInstallerThatReplacedTheProgramIsNotACrash(t *testing.T) {
	if bad, from := Interpret("0.1.1", "0.2.0", ""); bad || from != "0.1.1" {
		t.Errorf("an update from 0.1.1: bad=%v from=%q", bad, from)
	}
	// A newer version replaced by an older one (a downgrade by hand) is the same thing.
	if bad, from := Interpret("0.3.0\n", "0.2.0", ""); bad || from != "0.3.0" {
		t.Errorf("a downgrade: bad=%v from=%q", bad, from)
	}
}

func TestACutOffRunOfTheSameVersionIsUnexpected(t *testing.T) {
	for _, mark := range []string{"0.2.0", "0.2.0\n", "running", "", "  "} {
		if bad, from := Interpret(mark, "0.2.0", ""); !bad || from != "" {
			t.Errorf("mark %q: bad=%v from=%q", mark, bad, from)
		}
	}
}

func TestAnUpdateFromTheOldMarkIsToldByTheLastLineOfTheLog(t *testing.T) {
	// The mark of 0.2.0 has no version; its window wrote that it started the installer, and then the installer closed it.
	for _, line := range []string{"2026-10-24 08:34:50  update: starting the installer of 0.2.1", "2026-10-24 08:34:50  обновления: запускаю установщик версии 0.2.1"} {
		if bad, from := Interpret("running", "0.2.1", line); bad || from == "" {
			t.Errorf("%q: bad=%v from=%q", line, bad, from)
		}
	}
	// Without that line the old mark is a run that ended unexpectedly.
	if bad, _ := Interpret("running", "0.2.1", "2026-10-24 08:34:06  click nav media"); !bad {
		t.Error("the old mark and an ordinary last line: unexpected")
	}
	// The line says nothing against a mark of a version: the version decides.
	if bad, _ := Interpret("0.2.1", "0.2.1", "update: starting the installer of 0.2.1"); !bad {
		t.Error("the same version, an installer that did not take: unexpected")
	}
}
