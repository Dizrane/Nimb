package dnsx

import "testing"

func TestStripLegacyHostsPreservesOutsideBytes(t *testing.T) {
	for _, newline := range []string{"\r\n", "\n"} {
		header := "\xef\xbb\xbf# local" + newline
		tail := "192.0.2.5 custom.test"
		old := header + recoveryStart + newline + "192.0.2.6 old.test" + newline + recoveryEnd + newline + tail
		data, err := stripLegacyHosts([]byte(old))
		if err != nil || string(data) != header+tail {
			t.Fatalf("strip legacy hosts = %q, %v", data, err)
		}
		data, err = stripLegacyHosts(data)
		if err != nil || string(data) != header+tail {
			t.Fatalf("second cleanup = %q, %v", data, err)
		}
	}
}

func TestStripLegacyHostsRejectsIncompleteBlock(t *testing.T) {
	if _, err := stripLegacyHosts([]byte(recoveryStart + "\n192.0.2.6 old.test\n")); err == nil {
		t.Fatal("accepted an incomplete legacy block")
	}
}
