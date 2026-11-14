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
	// Legacy includes retired servers, recognised so disabling or uninstalling can still restore DNS.
	Legacy [][]string
	// Retired providers remain recognisable for restoring existing settings.
	Retired bool
}

// Providers are the providers the service accepts; the first is the default. A command names one by its ID, so no address
// ever comes from the window.
var Providers = []Provider{
	{ID: "geohide-eu", Name: "GeoHide (EU)", Addresses: []string{"143.20.64.192", "5.175.161.40"}, Legacy: [][]string{{"143.20.64.192", "45.13.237.213"}}},
	{ID: "comss", Name: "Comss.one", Addresses: []string{"94.250.253.55", "212.109.195.93"}, Legacy: [][]string{{"83.220.169.155", "212.109.195.93"}}, Retired: true},
	{ID: "magicdns", Name: "MagicDNS", Addresses: []string{"217.144.190.216", "109.120.187.249"}, Legacy: [][]string{{"109.120.132.43", "94.249.177.102"}}},
	{ID: "malwlink", Name: "malw.link", Addresses: []string{"179.254.166.171", "164.5.224.81"}},
	{ID: "geohide", Name: "GeoHide (RU)", Addresses: []string{"37.230.192.51", "193.233.112.67"}, Legacy: [][]string{{"159.194.200.33", "193.233.112.67"}}},
	{ID: "geohide-us", Name: "GeoHide (US)", Addresses: []string{"192.255.159.241", "192.255.159.240"}},
}

// Available excludes providers whose AI access has been discontinued.
func Available() []Provider {
	var out []Provider
	for _, p := range Providers {
		if !p.Retired {
			out = append(out, p)
		}
	}
	return out
}

// ByName is the order of the selectable providers on the page: by name.
func ByName() []Provider {
	out := Available()
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
	return mappedServers(p.Addresses)
}

// Matches6 recognises mapped addresses written by older versions as well as the current ones.
func (p Provider) Matches6(servers string) bool {
	if Same6(servers, p.Servers6()) {
		return true
	}
	for _, old := range p.Legacy {
		if Same6(servers, mappedServers(old)) {
			return true
		}
	}
	return false
}

func mappedServers(addresses []string) string {
	var out []string
	for _, a := range addresses {
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
	// AppliedProviders are the providers this adapter was given. A failed write may leave the previous provider in place.
	AppliedProviders []string `json:"appliedProviders,omitempty"`
	// Set6 (only in what Apply, Fresh and Restore return) says that the IPv6 servers are to be written too.
	Set6 bool `json:"-"`
}

// needs6 tells whether the IPv6 servers of the adapter are to be taken over by the provider.
func (a Adapter) needs6(p Provider) bool { return a.V6 && !Same6(a.NameServer6, p.Servers6()) }

// Backup is what the adapters had before Smart DNS, kept until every adapter can be restored.
type Backup struct {
	Provider  string    `json:"provider"`
	Adapters  []Adapter `json:"adapters"`
	Restoring bool      `json:"restoring,omitempty"`
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
	// Older backups used one provider for every adapter. Remember it before changing the active provider, including on adapters
	// that are absent now and cannot receive the new one.
	for i := range b.Adapters {
		if len(b.Adapters[i].AppliedProviders) == 0 && b.Provider != "" {
			b.Adapters[i].AppliedProviders = []string{b.Provider}
		}
	}
	b.Provider = provider.ID
	b.Restoring = false
	for _, a := range now {
		if !b.has(a.GUID) {
			a.AppliedProviders = []string{provider.ID}
			b.Adapters = append(b.Adapters, a)
		} else if a.needs6(provider) {
			// IPv6 servers that came after Smart DNS was turned on: what they were is what goes back.
			for i := range b.Adapters {
				if b.Adapters[i].GUID == a.GUID && !b.Adapters[i].V6 {
					b.Adapters[i].V6, b.Adapters[i].NameServer6 = true, a.NameServer6
				}
			}
		}
		for i := range b.Adapters {
			if b.Adapters[i].GUID == a.GUID {
				b.Adapters[i].rememberProvider(provider.ID)
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
		a.AppliedProviders = []string{provider.ID}
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
// Absent adapters cannot be written yet; PendingRestore keeps them for their return.
func (b *Backup) Restore(now []Adapter) (write []Adapter, skipped []string) {
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
		ids := saved.AppliedProviders
		if len(ids) == 0 {
			ids = []string{b.Provider} // backups from earlier versions
		}
		owned4, owned6, known := false, false, false
		for _, id := range ids {
			if provider, ok := Find(id); ok {
				known = true
				owned4 = owned4 || provider.Matches(current.NameServer)
				owned6 = owned6 || (saved.V6 && provider.Matches6(current.NameServer6))
			}
		}
		owned4 = owned4 || !known
		if !owned4 {
			if !Same(current.NameServer, saved.NameServer) {
				skipped = append(skipped, saved.Name)
				continue
			}
			// IPv4 may already be restored by an earlier attempt whose IPv6 write failed. Finish our remaining IPv6 change;
			// an unrelated IPv4 change above, or IPv6 that is no longer ours, is left alone.
			if !owned6 {
				continue
			}
		}
		back := Adapter{GUID: saved.GUID, Name: saved.Name, NameServer: saved.NameServer}
		// The IPv6 servers go back only if they are still the ones Smart DNS put there; the person's own change stays.
		if owned6 {
			back.NameServer6, back.Set6 = saved.NameServer6, true
		}
		write = append(write, back)
	}
	return write, skipped
}

func (a *Adapter) rememberProvider(id string) {
	for _, old := range a.AppliedProviders {
		if old == id {
			return
		}
	}
	// A cloned backup must not change the slices belonging to the previous, persisted backup before saveBackup succeeds.
	a.AppliedProviders = append(append([]string(nil), a.AppliedProviders...), id)
}

// PendingRestore keeps absent adapters and failed/unverified writes, while completed adapters and manual changes are done.
// The remaining backup is an off state: a returning USB adapter must get its original DNS, rather than enable Smart DNS again.
func (b *Backup) PendingRestore(now []Adapter, failedGUIDs []string) *Backup {
	present, failed := make(map[string]bool), make(map[string]bool)
	for _, a := range now {
		present[a.GUID] = true
	}
	for _, guid := range failedGUIDs {
		failed[guid] = true
	}
	pending := &Backup{Provider: b.Provider, Restoring: true}
	for _, a := range b.Adapters {
		if !present[a.GUID] || failed[a.GUID] {
			pending.Adapters = append(pending.Adapters, a)
		}
	}
	if len(pending.Adapters) == 0 {
		return nil
	}
	return pending
}
