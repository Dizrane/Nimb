//go:build windows

// Package netfacts reads what the system says about the routes and the proxy, for the report about a problem.
package netfacts

import (
	"encoding/binary"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

// HasUplink tells whether the computer has a connected network with a default route: the tunnel needs one to reach its server.
func HasUplink() bool {
	for _, family := range []winipcfg.AddressFamily{windows.AF_INET, windows.AF_INET6} {
		rows, err := winipcfg.GetIPForwardTable2(family)
		if err != nil {
			continue
		}
		for i := range rows {
			if rows[i].DestinationPrefix.PrefixLength != 0 {
				continue
			}
			if ipif, err := rows[i].InterfaceLUID.IPInterface(family); err == nil && ipif.Connected {
				if row, err := rows[i].InterfaceLUID.Interface(); err == nil && row.Alias() != "Nimb" {
					return true
				}
			}
		}
	}
	return false
}

// Routes tells how many routes of the tunnel (the adapter named tunnel) the table of the system has, and which connection the traffic to
// the internet leaves by (the route to 1.1.1.1 that is the most specific, then the cheapest).
func Routes(tunnel string) (routes int, via string, viaTunnel bool) {
	rows, err := winipcfg.GetIPForwardTable2(windows.AF_INET)
	if err != nil {
		return 0, "?", false
	}
	target := netip.MustParseAddr("1.1.1.1")
	bestBits, bestMetric := -1, uint32(0)
	for i := range rows {
		r := &rows[i]
		prefix := r.DestinationPrefix.Prefix()
		alias := ""
		if row, err := r.InterfaceLUID.Interface(); err == nil {
			alias = row.Alias()
		}
		if alias == tunnel && prefix.IsValid() && prefix.Bits() <= 1 {
			routes++
		}
		if !prefix.IsValid() || !prefix.Contains(target) {
			continue
		}
		metric := r.Metric
		if ipif, err := r.InterfaceLUID.IPInterface(windows.AF_INET); err == nil {
			metric += ipif.Metric
		}
		if prefix.Bits() > bestBits || (prefix.Bits() == bestBits && metric < bestMetric) {
			bestBits, bestMetric, via = prefix.Bits(), metric, alias
		}
	}
	if via == "" {
		via = "никуда (маршрута нет)"
	}
	return routes, via, via == tunnel
}

// RouteLines are the routes that decide where the traffic goes, as lines of a report: the routes of the default (0.0.0.0/0 and ::/0) and
// the halves of them that the tunnel puts in front (/1), with the connection and the metric of each, and how many routes the tunnel has
// in the IPv4 table and in the IPv6 one. The addresses of the person's network are not here: only prefixes of the default routes.
func RouteLines(tunnel string) []string {
	var lines []string
	for _, family := range []winipcfg.AddressFamily{windows.AF_INET, windows.AF_INET6} {
		name := "IPv4"
		if family == windows.AF_INET6 {
			name = "IPv6"
		}
		rows, err := winipcfg.GetIPForwardTable2(family)
		if err != nil {
			lines = append(lines, name+": таблица маршрутов не прочитана: "+err.Error())
			continue
		}
		inTunnel := 0
		for i := range rows {
			r := &rows[i]
			prefix := r.DestinationPrefix.Prefix()
			if !prefix.IsValid() || prefix.Bits() > 1 {
				continue
			}
			alias := "?"
			if row, err := r.InterfaceLUID.Interface(); err == nil {
				alias = row.Alias()
			}
			metric := r.Metric
			if ipif, err := r.InterfaceLUID.IPInterface(family); err == nil {
				metric += ipif.Metric
			}
			if alias == tunnel {
				inTunnel++
			}
			lines = append(lines, fmt.Sprintf("%s: маршрут %s через «%s», метрика %d", name, routeWords(prefix), alias, metric))
		}
		lines = append(lines, fmt.Sprintf("%s: маршрутов туннеля %d", name, inTunnel))
	}
	return lines
}

// routeWords names a route of the default or one of its halves in words: the addresses 0.0.0.0 and 128.0.0.0 would be taken for addresses of
// the person and cut out of a report, and there is nothing in them but which half it is.
func routeWords(p netip.Prefix) string {
	switch {
	case p.Bits() == 0:
		return "по умолчанию (/0, всё)"
	case p.Addr().IsUnspecified():
		return "нижняя половина (/1)"
	default:
		return "верхняя половина (/1)"
	}
}

const internetSettings = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`

// WinINet is the proxy that the programs of the person use (the settings of the browsers that take them from the system).
func WinINet() (enabled bool, server, pac string) {
	k, err := registry.OpenKey(registry.CURRENT_USER, internetSettings, registry.QUERY_VALUE)
	if err != nil {
		return false, "", ""
	}
	defer k.Close()
	on, _, _ := k.GetIntegerValue("ProxyEnable")
	server, _, _ = k.GetStringValue("ProxyServer")
	pac, _, _ = k.GetStringValue("AutoConfigURL")
	return on == 1, server, pac
}

// WinHTTP is the proxy of the services and of the programs that ask the system for it that way. It is a blob of bytes in the
// registry: a version, a counter, the flags (2 is a proxy, 8 is a script of settings), then the length and the text of the proxy.
func WinHTTP() (enabled bool, server, pac string) {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, internetSettings+`\Connections`, registry.QUERY_VALUE)
	if err != nil {
		return false, "", ""
	}
	defer k.Close()
	blob, _, err := k.GetBinaryValue("WinHttpSettings")
	if err != nil || len(blob) < 16 {
		return false, "", ""
	}
	flags := blob[8]
	n := int(binary.LittleEndian.Uint32(blob[12:16]))
	if flags&2 != 0 && n > 0 && 16+n <= len(blob) {
		enabled, server = true, string(blob[16:16+n])
	}
	if flags&8 != 0 {
		pac = "script"
	}
	return enabled, server, pac
}

// Hosts is the text of the hosts file.
func Hosts() string {
	root := os.Getenv("SystemRoot")
	if root == "" {
		root = `C:\Windows`
	}
	raw, _ := os.ReadFile(filepath.Join(root, "System32", "drivers", "etc", "hosts"))
	return string(raw)
}
