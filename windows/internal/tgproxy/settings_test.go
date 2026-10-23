package tgproxy

import (
	"strings"
	"testing"
)

func TestTheKeyAndThePortOfAnEarlierVersionAreTakenOnce(t *testing.T) {
	var s Settings
	if err := s.Adopt("0123456789ABCDEF0123456789abcdef", 1445); err != nil {
		t.Fatal(err)
	}
	if s.Secret != "0123456789abcdef0123456789abcdef" || s.Port != 1445 {
		t.Errorf("%+v", s)
	}
	// After that the service keeps its own: a different offer changes nothing.
	s.Adopt("ffffffffffffffffffffffffffffffff", 2000)
	if s.Secret != "0123456789abcdef0123456789abcdef" || s.Port != 1445 {
		t.Errorf("an offer changed the settings: %+v", s)
	}
}

func TestABadOfferIsNotTakenAndAKeyIsMade(t *testing.T) {
	for _, secret := range []string{"", "xyz", "0123456789abcdef", strings.Repeat("g", 32), strings.Repeat("a", 34)} {
		var s Settings
		s.Adopt(secret, 80) // a port below 1024 is not taken either
		if !ValidSecret(s.Secret) || s.Secret == secret {
			t.Errorf("offer %q: key %q", secret, s.Secret)
		}
		if s.Port != 0 || s.PreferredPort() != DefaultPort {
			t.Errorf("offer %q: port %d", secret, s.Port)
		}
	}
	var a, b Settings
	a.Adopt("", 0)
	b.Adopt("", 0)
	if a.Secret == b.Secret {
		t.Error("two made keys are the same")
	}
}

func TestThePreferredPort(t *testing.T) {
	for port, want := range map[int]int{0: 1443, 80: 1443, 1023: 1443, 1024: 1024, 1500: 1500, 65535: 65535, 65536: 1443} {
		if got := (Settings{Port: port}).PreferredPort(); got != want {
			t.Errorf("port %d: %d, want %d", port, got, want)
		}
	}
}
