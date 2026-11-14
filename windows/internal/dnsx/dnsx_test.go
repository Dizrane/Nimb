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

func TestRetiredProviderIsRecognisedButNotOffered(t *testing.T) {
	p, found := Find("comss")
	if !found || !p.Retired || !p.Matches("94.250.253.55,212.109.195.93") {
		t.Fatalf("%+v", p)
	}
	for _, available := range ByName() {
		if available.ID == p.ID {
			t.Fatal("retired provider offered")
		}
	}
	b := &Backup{Provider: p.ID, Adapters: []Adapter{ad("{A}", "Wi-Fi", "9.9.9.9")}}
	write, skipped := b.Restore([]Adapter{ad("{A}", "Wi-Fi", p.Servers())})
	if len(skipped) != 0 || len(write) != 1 || write[0].NameServer != "9.9.9.9" {
		t.Fatalf("write %+v, skipped %v", write, skipped)
	}
}

func TestRetiredDNSAreStillRecognisedAndRestored(t *testing.T) {
	for id, servers := range map[string]string{
		"magicdns":   "109.120.132.43,94.249.177.102",
		"geohide-eu": "143.20.64.192,45.13.237.213",
		"geohide":    "159.194.200.33,193.233.112.67",
	} {
		p, found := Find(id)
		if !found || !p.Matches(servers) || Same(p.Servers(), servers) {
			t.Fatalf("%s: %+v", id, p)
		}
		saved := Adapter{GUID: "{A}", Name: "Wi-Fi", NameServer: "9.9.9.9", V6: true, NameServer6: "2001:db8::53"}
		now := Adapter{GUID: "{A}", Name: "Wi-Fi", NameServer: servers, V6: true, NameServer6: mappedServers(strings.Split(servers, ","))}
		b := &Backup{Provider: id, Adapters: []Adapter{saved}}
		write, skipped := b.Restore([]Adapter{now})
		if len(skipped) != 0 || len(write) != 1 || write[0].NameServer != "9.9.9.9" || !write[0].Set6 || write[0].NameServer6 != saved.NameServer6 {
			t.Errorf("%s: write %+v, skipped %v", id, write, skipped)
		}
	}
}

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

func TestRestoreDefersAdaptersThatAreGone(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{ad("{A}", "Wi-Fi", ""), ad("{B}", "USB", "9.9.9.9")})
	now := []Adapter{ad("{A}", "Wi-Fi", eu().Servers())}
	write, _ := b.Restore(now)
	if len(write) != 1 || write[0].GUID != "{A}" {
		t.Fatalf("write=%+v", write)
	}
	pending := b.PendingRestore(now, nil)
	if pending == nil || !pending.Restoring || len(pending.Adapters) != 1 || pending.Adapters[0].GUID != "{B}" {
		t.Fatalf("the USB adapter must keep its original settings until it returns: %+v", pending)
	}
	// A service restart must still know that DNS was switched off, and must not give the provider to new adapters.
	raw, err := json.Marshal(pending)
	if err != nil {
		t.Fatal(err)
	}
	var loaded Backup
	if err := json.Unmarshal(raw, &loaded); err != nil {
		t.Fatal(err)
	}
	if !loaded.Restoring {
		t.Fatalf("the pending restore state was lost: %s", raw)
	}
	now = []Adapter{ad("{A}", "Wi-Fi", ""), ad("{B}", "USB", eu().Servers()), ad("{C}", "New cable", "")}
	write, _ = loaded.Restore(now)
	if len(write) != 1 || write[0].GUID != "{B}" || write[0].NameServer != "9.9.9.9" {
		t.Fatalf("only the returning USB adapter must be restored: %+v", write)
	}
	if remaining := loaded.PendingRestore(now, nil); remaining != nil {
		t.Fatalf("the backup can be removed once the USB restore is confirmed: %+v", remaining)
	}
}

func TestUnverifiedRestoreKeepsOnlyTheAffectedAdapter(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{ad("{A}", "Wi-Fi", "9.9.9.9"), ad("{B}", "Ethernet", "10.0.0.53")})
	now := []Adapter{ad("{A}", "Wi-Fi", eu().Servers()), ad("{B}", "Ethernet", eu().Servers())}
	// A write can succeed immediately before its adapter disappears, so its readback is unavailable. That is not confirmation.
	pending := b.PendingRestore(now, []string{"{A}"})
	if pending == nil || len(pending.Adapters) != 1 || pending.Adapters[0].GUID != "{A}" || pending.Adapters[0].NameServer != "9.9.9.9" {
		t.Fatalf("only the unverified write must keep its backup: %+v", pending)
	}
	// A manual change while the USB adapter was gone belongs to the person when it comes back.
	now = []Adapter{ad("{A}", "Wi-Fi", "10.0.0.99")}
	write, skipped := pending.Restore(now)
	if len(write) != 0 || len(skipped) != 1 || pending.PendingRestore(now, nil) != nil {
		t.Fatalf("a later manual DNS choice must be kept and complete restoration: write=%+v skipped=%v", write, skipped)
	}
}

func TestPendingAdapterKeepsItsProviderWhenDNSIsEnabledAgain(t *testing.T) {
	// Migration matters too: an installed older version stored no per-adapter provider.
	var b Backup
	if err := json.Unmarshal([]byte(`{"provider":"geohide-eu","restoring":true,"adapters":[{"guid":"{USB}","name":"USB","nameServer":"9.9.9.9"}]}`), &b); err != nil {
		t.Fatal(err)
	}
	b.Apply(ru(), []Adapter{ad("{LAN}", "Ethernet", "")})
	if b.Restoring {
		t.Fatal("enabling DNS again must leave the pending off state")
	}
	now := []Adapter{ad("{USB}", "USB", eu().Servers()), ad("{LAN}", "Ethernet", ru().Servers())}
	write, skipped := b.Restore(now)
	if len(write) != 2 || len(skipped) != 0 || write[0].NameServer != "9.9.9.9" || write[1].NameServer != "" {
		t.Fatalf("the absent USB adapter still has the previous provider and must restore it: write=%+v skipped=%v", write, skipped)
	}
}

func TestRestoreRecognizesThePreviousProviderAfterFailedProviderChange(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{ad("{A}", "Wi-Fi", "9.9.9.9")})
	// Two attempts to change the provider both fail. The backup must still recognise the provider actually on the adapter.
	b.Apply(ru(), []Adapter{ad("{A}", "Wi-Fi", eu().Servers())})
	third, _ := Find("comss")
	b.Apply(third, []Adapter{ad("{A}", "Wi-Fi", eu().Servers())})
	write, skipped := b.Restore([]Adapter{ad("{A}", "Wi-Fi", eu().Servers())})
	if len(write) != 1 || write[0].NameServer != "9.9.9.9" || len(skipped) != 0 {
		t.Fatalf("a failed provider change must not strand its predecessor: write=%+v skipped=%v", write, skipped)
	}
	if write, skipped := b.Restore([]Adapter{ad("{A}", "Wi-Fi", "10.0.0.99")}); len(write) != 0 || len(skipped) != 1 {
		t.Fatalf("a manual DNS must still be kept: write=%+v skipped=%v", write, skipped)
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
	if want := "::ffff:143.20.64.192,::ffff:5.175.161.40"; eu().Servers6() != want {
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

// The network hands out its own IPv6 servers again after Smart DNS went on: they are taken over, but never over the hand of the person.
func TestIPv6ServersOfTheNetworkThatReturnAreTakenOver(t *testing.T) {
	b := &Backup{}
	b.Apply(eu(), []Adapter{{GUID: "{A}", Name: "Wi-Fi"}, {GUID: "{B}", Name: "Dock"}, {GUID: "{C}", Name: "Lan"}})
	now := []Adapter{
		{GUID: "{A}", Name: "Wi-Fi", NameServer: eu().Servers(), V6: true},                            // fe80::1 from the network
		{GUID: "{B}", Name: "Dock", NameServer: eu().Servers(), NameServer6: "2001:db8::1", V6: true}, // set by the person
		{GUID: "{C}", Name: "Lan", NameServer: "10.0.0.1", V6: true},                                  // IPv4 set by the person
		{GUID: "{D}", Name: "New", NameServer: eu().Servers(), V6: true},                              // not known to the backup
	}
	write := b.Refresh6(eu(), now)
	if len(write) != 1 || write[0].GUID != "{A}" || !write[0].Set6 || !b.Adapters[0].V6 {
		t.Fatalf("write=%+v backup=%+v", write, b.Adapters)
	}
}
