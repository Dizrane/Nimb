// Package dnsx decides what Smart DNS does to the DNS settings of the network adapters, and how it gives them back. The
// decisions are plain functions with no system calls (dns_windows.go has those), so the rules that protect the person from
// being left with somebody else's DNS can be tested everywhere.
package dnsx

import (
	"strings"
)

// Provider is a public Smart DNS provider. The list mirrors Sources/Nimb/Services.swift (a test compares the two).
type Provider struct {
	ID        string
	Name      string
	Addresses []string
}

// Providers are the providers the service accepts; the first is the default. A command names one by its ID, so no address
// ever comes from the window.
var Providers = []Provider{
	{"geohide-eu", "GeoHide (EU)", []string{"143.20.64.192", "45.13.237.213"}},
	{"comss", "Comss.one", []string{"83.220.169.155", "212.109.195.93"}},
	{"geohide", "GeoHide (RU)", []string{"159.194.200.33", "193.233.112.67"}},
	{"geohide-us", "GeoHide (US)", []string{"192.255.159.241", "192.255.159.240"}},
}

// Find returns the provider with this ID.
func Find(id string) (Provider, bool) {
	for _, p := range Providers {
		if p.ID == id {
			return p, true
		}
	}
	return Provider{}, false
}

// Servers is the value written to an adapter: the addresses, comma separated.
func (p Provider) Servers() string { return strings.Join(p.Addresses, ",") }

// Adapter is a network adapter as it is now. NameServer is what is set by hand on it; empty means that the adapter takes its
// DNS from the network (DHCP).
type Adapter struct {
	GUID       string `json:"guid"`
	Name       string `json:"name"`
	NameServer string `json:"nameServer"`
}

// Backup is what the adapters had before Smart DNS, kept on disk while Smart DNS is on.
type Backup struct {
	Provider string    `json:"provider"`
	Adapters []Adapter `json:"adapters"`
}

// Same tells whether two lists of servers are the same list ("a,b" and "a b" are).
func Same(a, b string) bool {
	x, y := fields(a), fields(b)
	if len(x) != len(y) {
		return false
	}
	for i := range x {
		if x[i] != y[i] {
			return false
		}
	}
	return true
}

func fields(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' || r == ';' })
}

func (b *Backup) has(guid string) bool {
	for _, a := range b.Adapters {
		if a.GUID == guid {
			return true
		}
	}
	return false
}

// Apply turns Smart DNS on, or moves it to another provider. Every adapter that is not in the backup yet is added to it with
// what it has now, then the adapters that do not have the provider yet are returned: those are the ones to write to. The
// backup keeps the first state of an adapter, however many times the provider changes.
func (b *Backup) Apply(provider Provider, now []Adapter) (write []Adapter) {
	b.Provider = provider.ID
	for _, a := range now {
		if !b.has(a.GUID) {
			b.Adapters = append(b.Adapters, a)
		}
		if !Same(a.NameServer, provider.Servers()) {
			write = append(write, a)
		}
	}
	return write
}

// Fresh returns the adapters that appeared after Smart DNS was turned on (those that are not in the backup) and puts them
// into it. The adapters that were there before are left alone, even if the person changed them by hand since.
func (b *Backup) Fresh(provider Provider, now []Adapter) (write []Adapter) {
	for _, a := range now {
		if b.has(a.GUID) {
			continue
		}
		b.Adapters = append(b.Adapters, a)
		if !Same(a.NameServer, provider.Servers()) {
			write = append(write, a)
		}
	}
	return write
}

// Restore turns Smart DNS off: it returns what to write back, per adapter. An adapter whose DNS is no longer the provider's
// was changed by the person after Smart DNS was turned on, and what they set is theirs, so it is left alone (skipped).
// Adapters that are gone are forgotten.
func (b *Backup) Restore(now []Adapter) (write []Adapter, skipped []string) {
	provider, known := Find(b.Provider)
	for _, saved := range b.Adapters {
		var current *Adapter
		for i := range now {
			if now[i].GUID == saved.GUID {
				current = &now[i]
			}
		}
		if current == nil {
			continue
		}
		if known && !Same(current.NameServer, provider.Servers()) {
			if !Same(current.NameServer, saved.NameServer) {
				skipped = append(skipped, saved.Name)
			}
			continue
		}
		write = append(write, Adapter{GUID: saved.GUID, Name: saved.Name, NameServer: saved.NameServer})
	}
	return write, skipped
}
