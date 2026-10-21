package dnsx

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
)

// ad is an adapter as the system reports it, with no IPv6 DNS servers.
func ad(guid, name, servers string) Adapter {
	return Adapter{GUID: guid, Name: name, NameServer: servers}
}

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
	now := []Adapter{ad("{A}", "Wi-Fi", ""), ad("{B}", "Ethernet", "9.9.9.9"), ad("{C}", "Other", eu().Servers())}
	write := b.Apply(eu(), now)
	if len(write) != 2 || write[0].GUID != "{A}" || write[1].GUID != "{B}" {
		t.Fatalf("write=%+v", write)
	}
	if len(b.Adapters) != 3 || b.Adapters[1].NameServer != "9.9.9.9" {
		t.Fatalf("backup=%+v", b)
	}
	// The provider changes: the backup still has the first state, not the EU servers that are on the adapters now.
	now2 := []Adapter{ad("{A}", "Wi-Fi", eu().Servers()), ad("{B}", "Ethernet", eu().Servers()), ad("{C}", "Other", eu().Servers())}
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
	b.Apply(eu(), []Adapter{ad("{A}", "Wi-Fi", ""), ad("{B}", "Ethernet", "9.9.9.9")})
	write, skipped := b.Restore([]Adapter{ad("{A}", "Wi-Fi", eu().Servers()), ad("{B}", "Ethernet", eu().Servers())})
	if len(skipped) != 0 || len(write) != 2 || write[0].NameServer != "" || write[1].NameServer != "9.9.9.9" {
		t.Fatalf("write=%+v skipped=%v", write, skipped)
	}
}

// What the person set by hand after Smart DNS went on is theirs.
func TestRestoreLeavesWhatThePersonChanged(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{ad("{A}", "Wi-Fi", ""), ad("{B}", "Ethernet", "")})
	write, skipped := b.Restore([]Adapter{ad("{A}", "Wi-Fi", "8.8.8.8"), ad("{B}", "Ethernet", eu().Servers())})
	if len(write) != 1 || write[0].GUID != "{B}" || len(skipped) != 1 || skipped[0] != "Wi-Fi" {
		t.Fatalf("write=%+v skipped=%v", write, skipped)
	}
}

func TestRestoreForgetsAdaptersThatAreGone(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{ad("{A}", "Wi-Fi", ""), ad("{B}", "USB", "9.9.9.9")})
	write, _ := b.Restore([]Adapter{ad("{A}", "Wi-Fi", eu().Servers())})
	if len(write) != 1 || write[0].GUID != "{A}" {
		t.Fatalf("write=%+v", write)
	}
}

// If the person already had the provider's own servers, giving back means the same servers.
func TestTheProviderThePersonAlreadyHadStays(t *testing.T) {
	b := &Backup{}
	b.Apply(ru(), []Adapter{ad("{A}", "Wi-Fi", ru().Servers())})
	write, _ := b.Restore([]Adapter{ad("{A}", "Wi-Fi", ru().Servers())})
	if len(write) != 1 || !Same(write[0].NameServer, ru().Servers()) {
		t.Fatalf("write=%+v", write)
	}
}

func TestFreshTouchesOnlyNewAdapters(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{ad("{A}", "Wi-Fi", "")})
	// The person turned Wi-Fi back to automatic by hand, and a new adapter appeared.
	write := b.Fresh(eu(), []Adapter{ad("{A}", "Wi-Fi", ""), ad("{N}", "Dock", "10.0.0.1")})
	if len(write) != 1 || write[0].GUID != "{N}" {
		t.Fatalf("write=%+v", write)
	}
	if len(b.Adapters) != 2 || b.Adapters[1].NameServer != "10.0.0.1" {
		t.Fatalf("backup=%+v", b.Adapters)
	}
}

// Windows asks the IPv6 servers of an adapter before the IPv4 ones: an adapter with IPv6 DNS servers gets the provider there too.
func TestAnAdapterWithIPv6ServersGetsTheProviderThereToo(t *testing.T) {
	b := &Backup{}
	a := Adapter{GUID: "{A}", Name: "Wi-Fi", NameServer: "", V6: true}
	write := b.Apply(eu(), []Adapter{a, ad("{B}", "Ethernet", "")})
	if len(write) != 2 || !write[0].Set6 || write[1].Set6 {
		t.Fatalf("only the adapter that has IPv6 servers is written in IPv6: %+v", write)
	}
	if want := "::ffff:143.20.64.192,::ffff:45.13.237.213"; eu().Servers6() != want {
		t.Fatalf("Servers6 = %q, want %q", eu().Servers6(), want)
	}
	// Done: nothing is left to write, whatever the IPv4 side says.
	done := Adapter{GUID: "{A}", Name: "Wi-Fi", NameServer: eu().Servers(), NameServer6: eu().Servers6(), V6: true}
	if write := b.Apply(eu(), []Adapter{done}); len(write) != 0 {
		t.Fatalf("write=%+v", write)
	}
	// Only the IPv6 side is wrong: only it is written.
	done.NameServer6 = "2001:db8::1"
	if write := b.Apply(eu(), []Adapter{done}); len(write) != 1 || !write[0].Set6 {
		t.Fatalf("write=%+v", write)
	}
}

func TestRestoreGivesBackTheIPv6ServersOfThePerson(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{
		{GUID: "{A}", Name: "Wi-Fi", V6: true},                                 // from the network
		{GUID: "{B}", Name: "Ethernet", NameServer6: "2001:db8::53", V6: true}, // by hand
		ad("{C}", "Dock", ""), // no IPv6 servers
	})
	now := []Adapter{
		{GUID: "{A}", Name: "Wi-Fi", NameServer: eu().Servers(), NameServer6: eu().Servers6(), V6: true},
		{GUID: "{B}", Name: "Ethernet", NameServer: eu().Servers(), NameServer6: eu().Servers6(), V6: true},
		{GUID: "{C}", Name: "Dock", NameServer: eu().Servers()},
	}
	write, _ := b.Restore(now)
	if len(write) != 3 || !write[0].Set6 || write[0].NameServer6 != "" || !write[1].Set6 || write[1].NameServer6 != "2001:db8::53" || write[2].Set6 {
		t.Fatalf("write=%+v", write)
	}
	// What the person put in IPv6 after Smart DNS went on is theirs.
	now[0].NameServer6 = "2001:db8::99"
	write, _ = b.Restore(now)
	if write[0].Set6 {
		t.Fatalf("the IPv6 servers of the person were written over: %+v", write[0])
	}
}

func TestIPv6ServersThatCameLaterAreRemembered(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{ad("{A}", "Wi-Fi", "")})
	b.Apply(eu(), []Adapter{{GUID: "{A}", Name: "Wi-Fi", NameServer: eu().Servers(), NameServer6: "2001:db8::1", V6: true}})
	if !b.Adapters[0].V6 || b.Adapters[0].NameServer6 != "2001:db8::1" {
		t.Fatalf("backup=%+v", b.Adapters)
	}
}

// A backup of the earlier versions has no IPv6 fields: it restores as before.
func TestAnOldBackupStillRestores(t *testing.T) {
	var b Backup
	if err := json.Unmarshal([]byte(`{"provider":"geohide-eu","adapters":[{"guid":"{A}","name":"Wi-Fi","nameServer":""}]}`), &b); err != nil {
		t.Fatal(err)
	}
	write, _ := b.Restore([]Adapter{{GUID: "{A}", Name: "Wi-Fi", NameServer: eu().Servers(), NameServer6: "x", V6: true}})
	if len(write) != 1 || write[0].Set6 {
		t.Fatalf("write=%+v", write)
	}
}

func TestSame6ReadsTheSameAddressInAnotherSpelling(t *testing.T) {
	if !Same6("::ffff:1.2.3.4,::ffff:5.6.7.8", "::ffff:102:304 ::ffff:506:708") || !Same6("2001:db8::1", "2001:0db8:0:0:0:0:0:1") || !Same6("", "") {
		t.Error("should be the same")
	}
	if Same6("2001:db8::1", "2001:db8::2") || Same6("::ffff:1.2.3.4", "") || Same6("x", "y") {
		t.Error("should differ")
	}
}
