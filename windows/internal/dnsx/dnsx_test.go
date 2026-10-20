package dnsx

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

func eu() Provider { p, _ := Find("geohide-eu"); return p }
func ru() Provider { p, _ := Find("geohide"); return p }

// The addresses must be the ones of the Mac app: a different list in the two apps would be a quiet mistake.
func TestProvidersAreTheOnesOfTheMacApp(t *testing.T) {
	raw, err := os.ReadFile("../../../Sources/Nimb/Services.swift")
	if err != nil {
		t.Skip("the repository root is not here")
	}
	re := regexp.MustCompile(`DNSProvider\(id: "([^"]+)", name: "([^"]+)", addresses: \[([^\]]*)\]`)
	found := re.FindAllStringSubmatch(string(raw), -1)
	if len(found) != len(Providers) {
		t.Fatalf("the Mac app has %d providers, this list has %d", len(found), len(Providers))
	}
	for i, m := range found {
		addrs := strings.ReplaceAll(strings.ReplaceAll(m[3], `"`, ""), " ", "")
		p := Providers[i]
		if p.ID != m[1] || p.Name != m[2] || strings.Join(p.Addresses, ",") != addrs {
			t.Errorf("provider %d differs: mac %q %q %q, here %+v", i, m[1], m[2], addrs, p)
		}
	}
}

func TestSameIgnoresTheSeparator(t *testing.T) {
	if !Same("1.1.1.1,1.0.0.1", "1.1.1.1 1.0.0.1") || !Same("", "") {
		t.Error("should be the same")
	}
	if Same("1.1.1.1,1.0.0.1", "1.0.0.1,1.1.1.1") || Same("1.1.1.1", "") {
		t.Error("should differ")
	}
}

func TestApplyKeepsTheFirstStateAndWritesOnlyWhereNeeded(t *testing.T) {
	b := &Backup{}
	now := []Adapter{{"{A}", "Wi-Fi", ""}, {"{B}", "Ethernet", "9.9.9.9"}, {"{C}", "Other", eu().Servers()}}
	write := b.Apply(eu(), now)
	if len(write) != 2 || write[0].GUID != "{A}" || write[1].GUID != "{B}" {
		t.Fatalf("write=%+v", write)
	}
	if len(b.Adapters) != 3 || b.Adapters[1].NameServer != "9.9.9.9" {
		t.Fatalf("backup=%+v", b)
	}
	// The provider changes: the backup still has the first state, not the EU servers that are on the adapters now.
	now2 := []Adapter{{"{A}", "Wi-Fi", eu().Servers()}, {"{B}", "Ethernet", eu().Servers()}, {"{C}", "Other", eu().Servers()}}
	write = b.Apply(ru(), now2)
	if len(write) != 3 || b.Provider != "geohide" {
		t.Fatalf("write=%+v provider=%s", write, b.Provider)
	}
	if b.Adapters[0].NameServer != "" || b.Adapters[1].NameServer != "9.9.9.9" {
		t.Fatalf("the first state was lost: %+v", b.Adapters)
	}
}

func TestRestoreGivesBackWhatWasThere(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{{"{A}", "Wi-Fi", ""}, {"{B}", "Ethernet", "9.9.9.9"}})
	write, skipped := b.Restore([]Adapter{{"{A}", "Wi-Fi", eu().Servers()}, {"{B}", "Ethernet", eu().Servers()}})
	if len(skipped) != 0 || len(write) != 2 || write[0].NameServer != "" || write[1].NameServer != "9.9.9.9" {
		t.Fatalf("write=%+v skipped=%v", write, skipped)
	}
}

// What the person set by hand after Smart DNS went on is theirs.
func TestRestoreLeavesWhatThePersonChanged(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{{"{A}", "Wi-Fi", ""}, {"{B}", "Ethernet", ""}})
	write, skipped := b.Restore([]Adapter{{"{A}", "Wi-Fi", "8.8.8.8"}, {"{B}", "Ethernet", eu().Servers()}})
	if len(write) != 1 || write[0].GUID != "{B}" || len(skipped) != 1 || skipped[0] != "Wi-Fi" {
		t.Fatalf("write=%+v skipped=%v", write, skipped)
	}
}

func TestRestoreForgetsAdaptersThatAreGone(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{{"{A}", "Wi-Fi", ""}, {"{B}", "USB", "9.9.9.9"}})
	write, _ := b.Restore([]Adapter{{"{A}", "Wi-Fi", eu().Servers()}})
	if len(write) != 1 || write[0].GUID != "{A}" {
		t.Fatalf("write=%+v", write)
	}
}

// If the person already had the provider's own servers, giving back means the same servers.
func TestTheProviderThePersonAlreadyHadStays(t *testing.T) {
	b := &Backup{}
	b.Apply(ru(), []Adapter{{"{A}", "Wi-Fi", ru().Servers()}})
	write, _ := b.Restore([]Adapter{{"{A}", "Wi-Fi", ru().Servers()}})
	if len(write) != 1 || !Same(write[0].NameServer, ru().Servers()) {
		t.Fatalf("write=%+v", write)
	}
}

func TestFreshTouchesOnlyNewAdapters(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{{"{A}", "Wi-Fi", ""}})
	// The person turned Wi-Fi back to automatic by hand, and a new adapter appeared.
	write := b.Fresh(eu(), []Adapter{{"{A}", "Wi-Fi", ""}, {"{N}", "Dock", "10.0.0.1"}})
	if len(write) != 1 || write[0].GUID != "{N}" {
		t.Fatalf("write=%+v", write)
	}
	if len(b.Adapters) != 2 || b.Adapters[1].NameServer != "10.0.0.1" {
		t.Fatalf("backup=%+v", b.Adapters)
	}
}
