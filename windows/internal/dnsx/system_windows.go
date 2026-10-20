//go:build windows

package dnsx

import (
	"fmt"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

// Adapters returns the adapters that Smart DNS is for: connected Wi-Fi and Ethernet adapters of the computer itself. The tunnel
// of Nimb, other VPNs, virtual switches of Hyper-V, WSL and virtual machines are not among them (their DNS is not the person's
// to change).
func Adapters() ([]Adapter, error) {
	all, err := winipcfg.GetAdaptersAddresses(windows.AF_INET, winipcfg.GAAFlagDefault)
	if err != nil {
		return nil, err
	}
	var out []Adapter
	for _, a := range all {
		if a.OperStatus != winipcfg.IfOperStatusUp || (a.IfType != winipcfg.IfTypeEthernetCSMACD && a.IfType != winipcfg.IfTypeIEEE80211) {
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
		out = append(out, Adapter{GUID: guid.String(), Name: row.Alias(), NameServer: static(guid.String())})
	}
	return out, nil
}

// static is what is set by hand on the adapter, read the way the system keeps it. Empty: the adapter gets its DNS from the network.
func static(guid string) string {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\`+guid, registry.QUERY_VALUE)
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
func Write(a Adapter) error {
	guid, err := windows.GUIDFromString(a.GUID)
	if err != nil {
		return err
	}
	servers, err := windows.UTF16PtrFromString(a.NameServer)
	if err != nil {
		return err
	}
	settings := &winipcfg.DnsInterfaceSettings{
		Version:    winipcfg.DnsInterfaceSettingsVersion1,
		Flags:      winipcfg.DnsInterfaceSettingsFlagNameserver,
		NameServer: servers,
	}
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
