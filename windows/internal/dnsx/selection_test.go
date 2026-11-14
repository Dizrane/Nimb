package dnsx

import "testing"

func TestRestoreIncludesDisconnectedHardwareButNotVirtualAdapters(t *testing.T) {
	for _, tc := range []struct {
		name                   string
		up, hardware, ipv4     bool
		wantApply, wantRestore bool
	}{
		{"connected Wi-Fi", true, true, true, true, true},
		{"disconnected Wi-Fi", false, true, true, false, true},
		{"disabled IPv4 binding", false, true, false, false, true},
		{"virtual Ethernet", true, false, true, false, false},
		{"disconnected virtual Ethernet", false, false, false, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := includeAdapter(tc.up, tc.hardware, tc.ipv4, false); got != tc.wantApply {
				t.Errorf("apply includes adapter: %v, want %v", got, tc.wantApply)
			}
			if got := includeAdapter(tc.up, tc.hardware, tc.ipv4, true); got != tc.wantRestore {
				t.Errorf("restore includes adapter: %v, want %v", got, tc.wantRestore)
			}
		})
	}
}

func TestRestoreAfterMovingFromWiFiToEthernetKeepsBothOriginalSettings(t *testing.T) {
	wifi := Adapter{GUID: "{WIFI}", Name: "Wi-Fi", NameServer: "10.0.0.53", NameServer6: "2001:db8::53", V6: true}
	b := &Backup{}
	b.Apply(eu(), []Adapter{wifi})
	// The cable comes up after Wi-Fi goes down. Its original DNS must be remembered too.
	ethernet := Adapter{GUID: "{LAN}", Name: "Ethernet"}
	b.Fresh(eu(), []Adapter{ethernet})
	wifi.NameServer, wifi.NameServer6 = eu().Servers(), eu().Servers6()
	ethernet.NameServer = eu().Servers()
	var all []Adapter
	if includeAdapter(false, true, true, true) {
		all = append(all, wifi)
	}
	if includeAdapter(true, true, true, true) {
		all = append(all, ethernet)
	}
	write, skipped := b.Restore(all)
	if len(skipped) != 0 || len(write) != 2 {
		t.Fatalf("restore must give back settings of both physical adapters: write=%+v skipped=%v", write, skipped)
	}
	if write[0].NameServer != "10.0.0.53" || write[0].NameServer6 != "2001:db8::53" || !write[0].Set6 || write[1].NameServer != "" {
		t.Fatalf("the disconnected Wi-Fi must get both original DNS lists and Ethernet must get DHCP: %+v", write)
	}
	// A manual change on the disconnected adapter still belongs to the person.
	wifi.NameServer = "10.0.0.99"
	write, skipped = b.Restore([]Adapter{wifi, ethernet})
	if len(write) != 1 || write[0].GUID != ethernet.GUID || len(skipped) != 1 || skipped[0] != wifi.Name {
		t.Fatalf("a manual DNS change must survive restoring: write=%+v skipped=%v", write, skipped)
	}
}

func TestRestoreRetriesIPv6AfterIPv4WasAlreadyRestored(t *testing.T) {
	original := Adapter{GUID: "{WIFI}", Name: "Wi-Fi", NameServer: "10.0.0.53", NameServer6: "2001:db8::53", V6: true}
	b := &Backup{}
	b.Apply(eu(), []Adapter{original})
	current := original
	current.NameServer, current.NameServer6 = eu().Servers(), eu().Servers6()
	write, _ := b.Restore([]Adapter{current})
	if len(write) != 1 || !write[0].Set6 {
		t.Fatalf("both protocols must initially be restored: %+v", write)
	}
	// The first write restored IPv4, but Windows rejected the IPv6 write. The backup is retained for another try.
	current.NameServer = write[0].NameServer
	b = b.PendingRestore([]Adapter{current}, []string{current.GUID})
	if b == nil || !b.Restoring {
		t.Fatal("the failed IPv6 write must keep a pending backup")
	}
	write, skipped := b.Restore([]Adapter{current})
	if len(write) != 1 || !write[0].Set6 || write[0].NameServer6 != original.NameServer6 || len(skipped) != 0 {
		t.Fatalf("IPv6 must still be restored after IPv4 succeeded: write=%+v skipped=%v", write, skipped)
	}
	current.NameServer6 = write[0].NameServer6
	if write, skipped := b.Restore([]Adapter{current}); len(write) != 0 || len(skipped) != 0 {
		t.Fatalf("a completed restore must need no more writes: write=%+v skipped=%v", write, skipped)
	}
	// Do not mistake a person's later changes for an unfinished restore.
	current.NameServer, current.NameServer6 = "10.0.0.99", eu().Servers6()
	if write, skipped := b.Restore([]Adapter{current}); len(write) != 0 || len(skipped) != 1 {
		t.Fatalf("a different IPv4 choice belongs to the person: write=%+v skipped=%v", write, skipped)
	}
	current.NameServer, current.NameServer6 = original.NameServer, "2001:db8::99"
	if write, _ := b.Restore([]Adapter{current}); len(write) != 0 {
		t.Fatalf("a different IPv6 choice belongs to the person: %+v", write)
	}
}
