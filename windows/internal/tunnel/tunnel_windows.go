//go:build windows

// Package tunnel brings the Nimb tunnel up and down on Windows: a wintun adapter, the AmneziaWG daemon as a library, the
// address, the routes and the DNS of the adapter. It is the Windows counterpart of Resources/nimb-tunnel.sh.
package tunnel

import (
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"

	"github.com/Dizrane/Nimb/windows/internal/awgconf"
)

// Options of a tunnel.
type Options struct {
	// Name of the adapter, as the system shows it.
	Name string
	// DNS of the adapter. Without it the system keeps asking the router of the home network, which the tunnel does not reach,
	// and no site opens by its name (checked on Windows 11, 2026-10-21).
	DNS []netip.Addr
	// HandshakeTimeout is how long to wait for the first handshake; zero means 16 seconds.
	HandshakeTimeout time.Duration
	// Logf receives one line per step. It never receives keys.
	Logf func(format string, args ...any)
	// Verbose turns on the detailed log of the daemon (to the standard error); for debugging only.
	Verbose bool
}

// ErrNoHandshake means the server did not answer in time. The tunnel is already taken down when it is returned.
var ErrNoHandshake = errors.New("сервер не ответил: рукопожатия нет")

// Tunnel is a tunnel that is up.
type Tunnel struct {
	dev      *device.Device
	bind     conn.Bind
	luid     winipcfg.LUID
	logf     func(string, ...any)
	routeCB  *winipcfg.RouteChangeCallback
	mu       sync.Mutex
	closed   bool
	rebindCh chan struct{}
	done     chan struct{}
}

// Up creates the adapter and brings the tunnel up. On any failure everything it made is taken away again.
func Up(cfg *awgconf.Config, opt Options) (t *Tunnel, err error) {
	logf := opt.Logf
	if logf == nil {
		logf = func(string, ...any) {}
	}
	if opt.Name == "" {
		opt.Name = "Nimb"
	}
	timeout := opt.HandshakeTimeout
	if timeout == 0 {
		timeout = 16 * time.Second
	}
	if _, perr := netip.ParseAddrPort(cfg.Endpoint); perr != nil {
		return nil, fmt.Errorf("адрес сервера должен быть числом, а не именем: %w", perr)
	}
	uapi, err := cfg.UAPI()
	if err != nil {
		return nil, err
	}

	logf("creating adapter %q", opt.Name)
	nativeTun, err := tun.CreateTUN(opt.Name, cfg.MTU)
	if err != nil {
		return nil, fmt.Errorf("не удалось создать сетевой адаптер: %w", err)
	}
	native, ok := nativeTun.(*tun.NativeTun)
	if !ok {
		nativeTun.Close()
		return nil, errors.New("неожиданный тип адаптера")
	}
	bind := conn.NewDefaultBind()
	level := device.LogLevelError
	if opt.Verbose {
		level = device.LogLevelVerbose
	}
	dev := device.NewDevice(nativeTun, bind, device.NewLogger(level, "(nimb) "))
	t = &Tunnel{dev: dev, bind: bind, luid: winipcfg.LUID(native.LUID()), logf: logf,
		rebindCh: make(chan struct{}, 1), done: make(chan struct{})}
	defer func() {
		if err != nil {
			t.Close()
			t = nil
		}
	}()

	if err = dev.IpcSet(uapi); err != nil {
		return t, fmt.Errorf("демон отклонил настройки: %w", err)
	}
	if err = dev.Up(); err != nil {
		return t, fmt.Errorf("не удалось запустить туннель: %w", err)
	}
	logf("device is up")

	// The packets of the tunnel itself must leave through the real network, not into the tunnel: the socket is bound to the
	// interface of the real default route before any route of the tunnel exists, and follows it when the network changes.
	t.rebind()
	t.routeCB, err = winipcfg.RegisterRouteChangeCallback(func(winipcfg.MibNotificationType, *winipcfg.MibIPforwardRow2) {
		select {
		case t.rebindCh <- struct{}{}:
		default:
		}
	})
	if err != nil {
		return t, fmt.Errorf("не удалось следить за сетью: %w", err)
	}
	go t.rebindLoop()

	if err = t.configureInterface(cfg, opt.DNS); err != nil {
		return t, err
	}
	logf("address, routes and DNS are set")

	if err = t.waitHandshake(timeout); err != nil {
		return t, err
	}
	logf("handshake done")
	return t, nil
}

// Close takes the tunnel down: routes, addresses and DNS first, then the adapter. It is safe to call twice.
func (t *Tunnel) Close() {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return
	}
	t.closed = true
	close(t.done)
	t.mu.Unlock()

	if t.routeCB != nil {
		t.routeCB.Unregister()
	}
	// Windows does not like it when an adapter with live routes is destroyed, so everything is removed first.
	for _, family := range []winipcfg.AddressFamily{windows.AF_INET, windows.AF_INET6} {
		t.luid.FlushRoutes(family)
		t.luid.FlushIPAddresses(family)
		t.luid.FlushDNS(family)
	}
	t.dev.Close() // closes the adapter, which removes it
	t.logf("tunnel is down")
}

// Handshake returns when the last handshake with the server was, or the zero time.
func (t *Tunnel) Handshake() time.Time {
	text, err := t.dev.IpcGet()
	if err != nil {
		return time.Time{}
	}
	var sec, nsec int64
	for _, line := range strings.Split(text, "\n") {
		if v, ok := strings.CutPrefix(line, "last_handshake_time_sec="); ok {
			fmt.Sscan(v, &sec)
		}
		if v, ok := strings.CutPrefix(line, "last_handshake_time_nsec="); ok {
			fmt.Sscan(v, &nsec)
		}
	}
	if sec == 0 && nsec == 0 {
		return time.Time{}
	}
	return time.Unix(sec, nsec)
}

// Counters returns the bytes received from and sent to the server.
func (t *Tunnel) Counters() (rx, tx int64) {
	text, err := t.dev.IpcGet()
	if err != nil {
		return 0, 0
	}
	for _, line := range strings.Split(text, "\n") {
		if v, ok := strings.CutPrefix(line, "rx_bytes="); ok {
			fmt.Sscan(v, &rx)
		}
		if v, ok := strings.CutPrefix(line, "tx_bytes="); ok {
			fmt.Sscan(v, &tx)
		}
	}
	return rx, tx
}

func (t *Tunnel) waitHandshake(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !t.Handshake().IsZero() {
			return nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return ErrNoHandshake
}

func (t *Tunnel) configureInterface(cfg *awgconf.Config, dns []netip.Addr) error {
	var v4, v6 []netip.Prefix
	for _, a := range cfg.Addresses {
		if a.Addr().Is4() {
			v4 = append(v4, a)
		} else {
			v6 = append(v6, a)
		}
	}
	routes4, routes6 := routesFor(cfg.AllowedIPs)

	for _, family := range []winipcfg.AddressFamily{windows.AF_INET, windows.AF_INET6} {
		addrs, routes := v4, routes4
		if family == windows.AF_INET6 {
			addrs, routes = v6, routes6
		}
		if len(addrs) == 0 && len(routes) == 0 {
			continue
		}
		// The routes first, the address after. Setting the routes replaces every route of the adapter, and that includes the
		// local route that the system makes for the address: without it the system drops every answer as "not locally
		// destined" and nothing is received (found in the Windows 11 VM, 2026-10-21).
		if err := t.luid.SetRoutesForFamily(family, routes); err != nil {
			return fmt.Errorf("не удалось добавить маршруты: %w", err)
		}
		if err := t.luid.SetIPAddressesForFamily(family, addrs); err != nil {
			return fmt.Errorf("не удалось назначить адрес: %w", err)
		}
		ipif, err := t.luid.IPInterface(family)
		if err != nil {
			return fmt.Errorf("не удалось настроить интерфейс: %w", err)
		}
		ipif.RouterDiscoveryBehavior = winipcfg.RouterDiscoveryDisabled
		ipif.DadTransmits = 0
		ipif.ManagedAddressConfigurationSupported = false
		ipif.OtherStatefulConfigurationSupported = false
		ipif.NLMTU = uint32(cfg.MTU)
		// The routes of the tunnel must win over the real network.
		ipif.UseAutomaticMetric = false
		ipif.Metric = 0
		if err := ipif.Set(); err != nil {
			return fmt.Errorf("не удалось настроить интерфейс: %w", err)
		}
		var servers []netip.Addr
		for _, d := range dns {
			if d.Is4() == (family == windows.AF_INET) {
				servers = append(servers, d)
			}
		}
		if err := t.luid.SetDNS(family, servers, nil); err != nil {
			return fmt.Errorf("не удалось задать DNS: %w", err)
		}
	}
	return nil
}

// routesFor turns the allowed addresses into routes of the system. A route of the whole internet (/0) is written as its two
// halves (/1), as on the Mac. The more specific routes win over the default route of the real network without replacing it,
// and the system does not take a /0 route of a VPN as a reason to cut everything else off.
func routesFor(allowed []netip.Prefix) (v4, v6 []*winipcfg.RouteData) {
	add := func(p netip.Prefix) {
		r := &winipcfg.RouteData{Destination: p.Masked()}
		if p.Addr().Is4() {
			r.NextHop = netip.IPv4Unspecified()
			v4 = append(v4, r)
		} else {
			r.NextHop = netip.IPv6Unspecified()
			v6 = append(v6, r)
		}
	}
	for _, p := range allowed {
		if p.Bits() != 0 {
			add(p)
			continue
		}
		if p.Addr().Is4() {
			add(netip.MustParsePrefix("0.0.0.0/1"))
			add(netip.MustParsePrefix("128.0.0.0/1"))
		} else {
			add(netip.MustParsePrefix("::/1"))
			add(netip.MustParsePrefix("8000::/1"))
		}
	}
	return v4, v6
}

func (t *Tunnel) rebindLoop() {
	for {
		select {
		case <-t.done:
			return
		case <-t.rebindCh:
			// Route changes come in bursts; one look after they settle is enough.
			time.Sleep(300 * time.Millisecond)
			select {
			case <-t.rebindCh:
			default:
			}
			t.rebind()
		}
	}
}

// rebind ties the socket of the tunnel to the interface of the best default route that is not the tunnel itself. With no such
// route the socket sends nothing (it would otherwise send into the tunnel, which loops).
func (t *Tunnel) rebind() {
	binder, ok := t.bind.(conn.BindSocketToInterface)
	if !ok {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return
	}
	if idx, found := uplink(windows.AF_INET, t.luid); found {
		if err := binder.BindSocketToInterface4(idx, false); err != nil {
			t.logf("bind v4 to interface %d: %v", idx, err)
		}
	} else {
		binder.BindSocketToInterface4(0, true)
	}
	if idx, found := uplink(windows.AF_INET6, t.luid); found {
		if err := binder.BindSocketToInterface6(idx, false); err != nil {
			t.logf("bind v6 to interface %d: %v", idx, err)
		}
	} else {
		binder.BindSocketToInterface6(0, true)
	}
}

// uplink is the index of the interface that the best default route (not through `except`) leaves by.
func uplink(family winipcfg.AddressFamily, except winipcfg.LUID) (index uint32, found bool) {
	rows, err := winipcfg.GetIPForwardTable2(family)
	if err != nil {
		return 0, false
	}
	var best uint32
	for i := range rows {
		r := &rows[i]
		if r.DestinationPrefix.PrefixLength != 0 || r.InterfaceLUID == except {
			continue
		}
		ipif, err := r.InterfaceLUID.IPInterface(family)
		if err != nil || !ipif.Connected {
			continue
		}
		metric := r.Metric + ipif.Metric
		if !found || metric < best {
			best, index, found = metric, r.InterfaceIndex, true
		}
	}
	return index, found
}
