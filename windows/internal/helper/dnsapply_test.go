package helper

import (
	"errors"
	"testing"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

func TestDNSWriteDoesNotHideIPv6OrVerificationFailures(t *testing.T) {
	p := dnsx.Available()[0]
	for _, fault := range []string{"none", "write4", "write6", "unreadable", "wrong4", "wrong6"} {
		t.Run(fault, func(t *testing.T) {
			a := dnsx.Adapter{GUID: "wifi", Name: "Wi-Fi", Set6: true}
			state := a
			write4 := func(w dnsx.Adapter) error {
				if fault == "write4" {
					return errors.New("IPv4 rejected")
				}
				state.NameServer = w.NameServer
				return nil
			}
			write6 := func(w dnsx.Adapter) error {
				if fault == "write6" {
					return errors.New("IPv6 rejected")
				}
				state.NameServer6 = w.NameServer6
				return nil
			}
			read := func(string) (dnsx.Adapter, bool) {
				if fault == "wrong4" {
					state.NameServer = "10.0.0.53"
				}
				if fault == "wrong6" {
					state.NameServer6 = "2001:db8::53"
				}
				return state, fault != "unreadable"
			}
			failed := writeDNSAdapters([]dnsx.Adapter{a}, p, write4, write6, read, func(string, ...any) {})
			if (len(failed) == 0) != (fault == "none") {
				t.Fatalf("fault %s reported success: %v", fault, failed)
			}
		})
	}
}

func TestDNSWriteLeavesIPv6AloneWhenNotRequestedAndContinuesOtherAdapters(t *testing.T) {
	p := dnsx.Available()[0]
	state := map[string]dnsx.Adapter{}
	failed := writeDNSAdapters([]dnsx.Adapter{{GUID: "bad", Name: "Failed"}, {GUID: "ok", Name: "Working"}}, p,
		func(a dnsx.Adapter) error {
			if a.GUID == "bad" {
				return errors.New("disconnected")
			}
			state[a.GUID] = a
			return nil
		}, func(dnsx.Adapter) error { t.Fatal("IPv6 not requested"); return nil },
		func(id string) (dnsx.Adapter, bool) { a, ok := state[id]; return a, ok }, func(string, ...any) {})
	if len(failed) != 1 || failed[0] != "Failed" || state["ok"].NameServer != p.Servers() {
		t.Fatalf("%v %+v", failed, state)
	}
}
