package background

import (
	"encoding/json"
	"strings"
	"testing"
)

type settings struct {
	Provider string `json:"provider"`
	Mode
}

func TestItIsOnUntilTheOneTurnsItOff(t *testing.T) {
	var s settings
	if !s.Enabled() || s.ClosingQuits() {
		t.Fatal("a new setting must keep Nimb at the clock")
	}
	if err := json.Unmarshal([]byte(`{"provider":"comss"}`), &s); err != nil || !s.Enabled() {
		t.Fatalf("settings written before this one existed must mean «on»: %v %v", s, err)
	}
	raw, _ := json.Marshal(s)
	if strings.Contains(string(raw), "backgroundOff") {
		t.Fatalf("the default is not written: %s", raw)
	}
}

func TestItIsSavedAndRead(t *testing.T) {
	var s settings
	s.Provider = "comss"
	s.Enable(false)
	raw, _ := json.Marshal(s)
	if !strings.Contains(string(raw), `"backgroundOff":true`) || !strings.Contains(string(raw), `"provider":"comss"`) {
		t.Fatalf("saved as %s", raw)
	}
	var back settings
	if err := json.Unmarshal(raw, &back); err != nil || back.Enabled() || !back.ClosingQuits() || back.Provider != "comss" {
		t.Fatalf("read back %+v %v", back, err)
	}
	back.Enable(true)
	raw, _ = json.Marshal(back)
	if strings.Contains(string(raw), "backgroundOff") || !back.Enabled() {
		t.Fatalf("turned on again: %s", raw)
	}
}

func TestTheWindowOpensWhenNothingElseShowsNimb(t *testing.T) {
	on, off := Mode{}, Mode{Off: true}
	hidden := []string{"--hidden"}
	for _, c := range []struct {
		m    Mode
		args []string
		want bool
	}{{on, hidden, true}, {on, nil, false}, {off, hidden, false}, {off, nil, false}, {on, []string{"--page=ai", "--hidden"}, true}} {
		if got := c.m.StartsHidden(c.args); got != c.want {
			t.Errorf("%+v %v: %v, want %v", c.m, c.args, got, c.want)
		}
	}
}
