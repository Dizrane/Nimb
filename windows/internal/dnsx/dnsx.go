// Package dnsx decides what Smart DNS does to the DNS settings of the network adapters, and how it gives them back. The
// decisions are plain functions with no system calls (dns_windows.go has those), so the rules that protect the person from
// being left with somebody else's DNS can be tested everywhere.
package dnsx

import (
	"net/netip"
	"sort"
	"strings"
)

// Provider is a public Smart DNS provider. The list mirrors Sources/Nimb/Services.swift (a test compares the two).
type Provider struct {
	ID        string
	Name      string
	Addresses []string
	// Legacy are the addresses an earlier Nimb set for this provider and that it still answers on: they are still recognised as the provider's.
	Legacy [][]string
}

// Providers are the providers the service accepts; the first is the default. A command names one by its ID, so no address
// ever comes from the window.
var Providers = []Provider{
	{ID: "geohide-eu", Name: "GeoHide (EU)", Addresses: []string{"143.20.64.192", "45.13.237.213"}},
	{ID: "comss", Name: "Comss.one", Addresses: []string{"94.250.253.55", "212.109.195.93"}, Legacy: [][]string{{"83.220.169.155", "212.109.195.93"}}},
	{ID: "magicdns", Name: "MagicDNS", Addresses: []string{"109.120.132.43", "94.249.177.102"}},
	{ID: "malwlink", Name: "malw.link", Addresses: []string{"179.254.166.171", "164.5.224.81"}},
	{ID: "geohide", Name: "GeoHide (RU)", Addresses: []string{"159.194.200.33", "193.233.112.67"}},
	{ID: "geohide-us", Name: "GeoHide (US)", Addresses: []string{"192.255.159.241", "192.255.159.240"}},
}

// ByName is the order of the list on the page: by name.
func ByName() []Provider {
	out := append([]Provider(nil), Providers...)
	sort.SliceStable(out, func(i, j int) bool { return naturalLess(out[i].Name, out[j].Name) })
	return out
}

// naturalLess compares names the way the Mac list is ordered (case-insensitive, «Comss.one» before «GeoHide (EU)»).
func naturalLess(a, b string) bool { return strings.ToLower(a) < strings.ToLower(b) }

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

// Matches says whether these servers are the provider's: the current addresses or an earlier set.
func (p Provider) Matches(servers string) bool {
	if Same(servers, p.Servers()) {
		return true
	}
	for _, old := range p.Legacy {
		if Same(servers, strings.Join(old, ",")) {
			return true
		}
	}
	return false
}

// AllAddresses is every address Nimb has ever set for this provider.
func (p Provider) AllAddresses() []string {
	out := append([]string(nil), p.Addresses...)
	for _, old := range p.Legacy {
		out = append(out, old...)
	}
	return out
}

// Servers6 is what an adapter that has DNS servers of IPv6 gets in their place: the same addresses as IPv4-mapped IPv6 ones. Windows
// asks the IPv6 servers of an adapter before the IPv4 ones, so the ones the router hands out (they answer with the real addresses)
// would be asked first and Smart DNS would do nothing. The mapped addresses are not used for queries on the Windows that was tried
// (checked in a virtual machine: they are skipped and answer comes from the IPv4 servers at once); a Windows that does use them
// sends the questions over IPv4 to the same provider. Either way the router's servers are not asked.
func (p Provider) Servers6() string {
	var out []string
	for _, a := range p.Addresses {
		out = append(out, "::ffff:"+a)
	}
	return strings.Join(out, ",")
}

// Adapter is a network adapter as it is now. NameServer is what is set by hand on it; empty means that the adapter takes its
// DNS from the network (DHCP).
type Adapter struct {
	GUID       string `json:"guid"`
	Name       string `json:"name"`
	NameServer string `json:"nameServer"`
	// NameServer6 is what is set by hand for IPv6; V6 says that the adapter has IPv6 DNS servers now (set by hand or handed out
	// by the network). An adapter with none is left alone in IPv6.
	NameServer6 string `json:"nameServer6,omitempty"`
	V6          bool   `json:"v6,omitempty"`
	// Set6 (only in what Apply, Fresh and Restore return) says that the IPv6 servers are to be written too.
	Set6 bool `json:"-"`
}

// needs6 tells whether the IPv6 servers of the adapter are to be taken over by the provider.
func (a Adapter) needs6(p Provider) bool { return a.V6 && !Same6(a.NameServer6, p.Servers6()) }

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

// Same6 is Same for IPv6 servers: Windows may keep an address in another spelling (::ffff:1.2.3.4 and ::ffff:102:304 are one).
func Same6(a, b string) bool {
	x, y := fields(a), fields(b)
	if len(x) != len(y) {
		return false
	}
	for i := range x {
		p, errP := netip.ParseAddr(x[i])
		q, errQ := netip.ParseAddr(y[i])
		if errP != nil || errQ != nil {
			if x[i] != y[i] {
				return false
			}
			continue
		}
		if p.Unmap() != q.Unmap() {
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
		} else if a.needs6(provider) {
			// IPv6 servers that came after Smart DNS was turned on: what they were is what goes back.
			for i := range b.Adapters {
				if b.Adapters[i].GUID == a.GUID && !b.Adapters[i].V6 {
					b.Adapters[i].V6, b.Adapters[i].NameServer6 = true, a.NameServer6
				}
			}
		}
		if !Same(a.NameServer, provider.Servers()) || a.needs6(provider) {
			a.Set6 = a.needs6(provider)
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
		if !Same(a.NameServer, provider.Servers()) || a.needs6(provider) {
			a.Set6 = a.needs6(provider)
			write = append(write, a)
		}
	}
	return write
}

// Refresh6 returns the adapters that Smart DNS owns in IPv4 whose IPv6 servers are the network's again (a router that hands out its own,
// «fe80::1 от сети», after Smart DNS went on or the connection came up again): Windows asks those first, so they are taken over too. An
// adapter whose IPv4 servers or whose IPv6 servers the person set by hand is left alone.
func (b *Backup) Refresh6(provider Provider, now []Adapter) (write []Adapter) {
	for _, a := range now {
		if !b.has(a.GUID) || !a.V6 || a.NameServer6 != "" || !Same(a.NameServer, provider.Servers()) {
			continue
		}
		for i := range b.Adapters {
			if b.Adapters[i].GUID == a.GUID && !b.Adapters[i].V6 {
				b.Adapters[i].V6 = true
			}
		}
		a.Set6 = true
		write = append(write, a)
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
		if known && !provider.Matches(current.NameServer) {
			if !Same(current.NameServer, saved.NameServer) {
				skipped = append(skipped, saved.Name)
			}
			continue
		}
		back := Adapter{GUID: saved.GUID, Name: saved.Name, NameServer: saved.NameServer}
		// The IPv6 servers go back only if they are still the ones Smart DNS put there; the person's own change stays.
		if saved.V6 && known && Same6(current.NameServer6, provider.Servers6()) {
			back.NameServer6, back.Set6 = saved.NameServer6, true
		}
		write = append(write, back)
	}
	return write, skipped
}
