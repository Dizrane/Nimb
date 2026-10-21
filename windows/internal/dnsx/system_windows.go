//go:build windows

package dnsx

import (
	"fmt"
	"strings"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

// Adapters returns the adapters that Smart DNS is for: connected Wi-Fi and Ethernet adapters of the computer itself. The tunnel
// of Nimb, other VPNs, virtual switches of Hyper-V, WSL and virtual machines are not among them (their DNS is not the person's
// to change).
func Adapters() ([]Adapter, error) {
	all, err := winipcfg.GetAdaptersAddresses(windows.AF_UNSPEC, winipcfg.GAAFlagDefault)
	if err != nil {
		return nil, err
	}
	var out []Adapter
	for _, a := range all {
		if a.OperStatus != winipcfg.IfOperStatusUp || (a.IfType != winipcfg.IfTypeEthernetCSMACD && a.IfType != winipcfg.IfTypeIEEE80211) || a.Flags&winipcfg.IPAAFlagIpv4Enabled == 0 {
			continue
		}
		row, err := a.LUID.Interface()
		if err != nil || row.InterfaceAndOperStatusFlags&winipcfg.IAOSFHardwareInterface == 0 {
			continue
		}
		guid, err := a.LUID.GUID()
		if err != nil {
			continue
		}
		_, v6 := dnsServers(a)
		out = append(out, Adapter{GUID: guid.String(), Name: row.Alias(), NameServer: static(guid.String(), false), NameServer6: static(guid.String(), true), V6: len(v6) > 0})
	}
	return out, nil
}

// dnsServers are the DNS servers the adapter works with now, whether they are set by hand or handed out by the network. The
// site-local addresses fec0:0:0:ffff::1-3 are what Windows lists when an adapter has none in IPv6; they are not servers.
func dnsServers(a *winipcfg.IPAdapterAddresses) (v4, v6 []string) {
	for d := a.FirstDNSServerAddress; d != nil; d = d.Next {
		ip := d.Address.IP()
		switch len(ip) {
		case 4:
			v4 = append(v4, ip.String())
		case 16:
			if ip[0] == 0xfe && ip[1] == 0xc0 && ip[6] == 0xff && ip[7] == 0xff {
				continue
			}
			v6 = append(v6, ip.String())
		}
	}
	return v4, v6
}

// static is what is set by hand on the adapter, read the way the system keeps it. Empty: the adapter gets its DNS from the network.
func static(guid string, ipv6 bool) string {
	path := `SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\`
	if ipv6 {
		path = `SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\`
	}
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, path+guid, registry.QUERY_VALUE)
	if err != nil {
		return ""
	}
	defer key.Close()
	v, _, err := key.GetStringValue("NameServer")
	if err != nil {
		return ""
	}
	return v
}

// Write sets the servers of one adapter; an empty value gives it back to the network (DHCP). Only the servers change, not the
// search list or anything else of the adapter.
func Write(a Adapter) error { return write(a, a.NameServer, 0) }

// Write6 does the same for the IPv6 servers of the adapter (a.NameServer6). It is apart from Write because it is a lesser
// matter: when it fails, Smart DNS still works for the adapter on IPv4.
func Write6(a Adapter) error { return write(a, a.NameServer6, winipcfg.DnsInterfaceSettingsFlagIPv6) }

func write(a Adapter, servers string, flags uint64) error {
	guid, err := windows.GUIDFromString(a.GUID)
	if err != nil {
		return err
	}
	list, err := windows.UTF16PtrFromString(servers)
	if err != nil {
		return err
	}
	settings := &winipcfg.DnsInterfaceSettings{Version: winipcfg.DnsInterfaceSettingsVersion1, Flags: flags | winipcfg.DnsInterfaceSettingsFlagNameserver, NameServer: list}
	if err := winipcfg.SetInterfaceDnsSettings(guid, settings); err != nil {
		return fmt.Errorf("DNS не изменился на «%s»: %w", a.Name, err)
	}
	return nil
}

// Flush empties the DNS cache of the system, so that the old answers do not outlive the old servers.
func Flush() {
	windows.NewLazySystemDLL("dnsapi.dll").NewProc("DnsFlushResolverCache").Call()
}

// Current is the state of one adapter now, by GUID.
func Current(guid string) (Adapter, bool) {
	all, err := Adapters()
	if err != nil {
		return Adapter{}, false
	}
	for _, a := range all {
		if a.GUID == guid {
			return a, true
		}
	}
	return Adapter{}, false
}

// Facts are what the report tells about one network connection of the computer: its kind, whether it works, the DNS servers it uses
// now and the ones set by hand.
type Facts struct {
	Name     string
	Kind     string
	Up       bool
	Hardware bool
	DNS4     []string
	DNS6     []string
	Static4  string
	Static6  string
}

// Describe lists every connection of the computer, the ones Smart DNS does not touch too (VPNs, virtual switches, the tunnel): a
// name asked of a DNS of another connection is a way for a real address to get past Smart DNS.
func Describe() ([]Facts, error) {
	all, err := winipcfg.GetAdaptersAddresses(windows.AF_UNSPEC, winipcfg.GAAFlagDefault)
	if err != nil {
		return nil, err
	}
	var out []Facts
	for _, a := range all {
		f := Facts{Name: a.FriendlyName(), Up: a.OperStatus == winipcfg.IfOperStatusUp}
		switch a.IfType {
		case winipcfg.IfTypeEthernetCSMACD:
			f.Kind = "Ethernet"
		case winipcfg.IfTypeIEEE80211:
			f.Kind = "Wi-Fi"
		case winipcfg.IfTypeSoftwareLoopback:
			f.Kind = "петля"
		case winipcfg.IfTypeTunnel:
			f.Kind = "туннель"
		case winipcfg.IfTypePropVirtual:
			f.Kind = "виртуальное"
		default:
			f.Kind = fmt.Sprintf("тип %d", a.IfType)
		}
		if row, err := a.LUID.Interface(); err == nil {
			f.Hardware = row.InterfaceAndOperStatusFlags&winipcfg.IAOSFHardwareInterface != 0
		}
		f.DNS4, f.DNS6 = dnsServers(a)
		if guid, err := a.LUID.GUID(); err == nil {
			f.Static4, f.Static6 = static(guid.String(), false), static(guid.String(), true)
		}
		out = append(out, f)
	}
	return out, nil
}

// Line is the facts as one line of a report; the names of the servers are left to Clean to hide.
func (f Facts) Line() string {
	state := "не работает"
	if f.Up {
		state = "работает"
	}
	hw := "программное"
	if f.Hardware {
		hw = "устройство компьютера"
	}
	list := func(label string, servers []string, static string) string {
		if len(servers) == 0 {
			return label + ": нет"
		}
		how := "от сети"
		if static != "" {
			how = "заданы вручную"
		}
		return fmt.Sprintf("%s: %s (%s)", label, strings.Join(servers, ", "), how)
	}
	return fmt.Sprintf("«%s»: %s, %s, %s; %s; %s", f.Name, f.Kind, state, hw, list("DNS IPv4", f.DNS4, f.Static4), list("DNS IPv6", f.DNS6, f.Static6))
}
