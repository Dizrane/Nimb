package report

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The same numbers are in the test of the relay (report-relay/test.mjs): the two sides must make one key and one signature.
func TestTheKeyOfAVersionAndTheSignatureAreTheOnesTheRelayMakes(t *testing.T) {
	key := VersionKey("test-master", "0.3.1")
	if key != "12ad25ee11e2ced7a9b902fad614968a53b9f74257a7b1f4c2e4c970120599e8" {
		t.Fatalf("key %s", key)
	}
	if VersionKey("test-master", "0.3.2") == key {
		t.Error("each version has a key of its own")
	}
	msg := Message("AB12CD", "0.3.1", "windows", "K7M2XQ9P", "текст")
	if !strings.HasPrefix(msg, "nimb1|AB12CD|0.3.1|windows|K7M2XQ9P|") || len(msg) != len("nimb1|AB12CD|0.3.1|windows|K7M2XQ9P|")+64 {
		t.Fatalf("message %q", msg)
	}
	if got := Signature(msg, []byte(key)); got != "842ff94108897eb459084b6ac33669b876978bc8aae6b033fd146665e89b92aa" {
		t.Errorf("signature %s", got)
	}
}

func TestTheKeyIsMixedWithTheVersionAndComesBack(t *testing.T) {
	key := []byte(VersionKey("test-master", "0.3.1"))
	mixed := Mix(key, "0.3.1")
	if strings.Contains(mixed, string(key[:8])) || mixed == "" {
		t.Error("the key must not stand in the program as it is")
	}
	if got := Unmix(mixed, "0.3.1"); string(got) != string(key) {
		t.Errorf("unmixed %q", got)
	}
	if string(Unmix(mixed, "0.3.2")) == string(key) {
		t.Error("another version does not unmix it")
	}
	if Unmix("", "0.3.1") != nil || Unmix("not hex", "0.3.1") != nil || Unmix(mixed, "") != nil {
		t.Error("nothing to unmix is nothing")
	}
}

func TestEveryReportIsSignedAndABuildWithoutAKeySendsNothing(t *testing.T) {
	var got map[string]any
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &got)
	}))
	defer srv.Close()
	t.Setenv("NIMB_REPORT_URL", srv.URL)

	SetKey(nil)
	if err := Send(context.Background(), "0.3.1", "AB12CD", "текст"); err != ErrNoKey || hits != 0 {
		t.Fatalf("no key: %v, %d hits", err, hits)
	}
	if !IsRefused(ErrNoKey) {
		t.Error("a build without a key is refused for good, not retried")
	}

	useKey(t)
	if err := SendAuto(context.Background(), "0.3.1", "AB12CD", "текст", "daily", "K7M2XQ9P"); err != nil {
		t.Fatal(err)
	}
	want := Signature(Message("AB12CD", "0.3.1", "windows", "K7M2XQ9P", "текст"), []byte("test-key"))
	if got["sig"] != want {
		t.Errorf("sig %v, want %s", got["sig"], want)
	}
	// A report by hand has no installation: the line has an empty field there, as on the Mac.
	if err := Send(context.Background(), "0.3.1", "AB12CD", "текст"); err != nil {
		t.Fatal(err)
	}
	if got["sig"] != Signature(Message("AB12CD", "0.3.1", "windows", "", "текст"), []byte("test-key")) {
		t.Errorf("the signature of a report by hand: %v", got["sig"])
	}
}

func TestTheRelayAnswerOfAnOutdatedVersionNamesTheLatest(t *testing.T) {
	useKey(t)
	for _, c := range []struct {
		body     string
		outdated bool
	}{{`{"ok":false,"error":"outdated","latest":"0.3.2"}`, true}, {`{"ok":false,"error":"unsigned"}`, false}} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(403); io.WriteString(w, c.body) }))
		t.Setenv("NIMB_REPORT_URL", srv.URL)
		err := Send(context.Background(), "0.3.1", "X", "y")
		srv.Close()
		var o *Outdated
		if c.outdated {
			if !errors.As(err, &o) || o.Latest != "0.3.2" || !strings.Contains(err.Error(), "Вышла новая версия 0.3.2") || !IsRefused(err) {
				t.Errorf("outdated: %v", err)
			}
		} else if err != ErrNoKey {
			t.Errorf("unsigned: %v", err)
		}
	}
}
