//go:build windows

// tunnel-poc is a test program: it brings the Nimb tunnel up from a settings file, shows what is going on and takes it down
// again. Run it from an administrator prompt, with wintun.dll next to it.
//
//	tunnel-poc -conf nimb-warp.conf [-hold 30s] [-dns 1.1.1.1,1.0.0.1]
package main

import (
	"flag"
	"fmt"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/awgconf"
	"github.com/Dizrane/Nimb/windows/internal/tunnel"
)

func main() {
	file := flag.String("conf", "", "settings file")
	hold := flag.Duration("hold", 30*time.Second, "how long to keep the tunnel up")
	dnsFlag := flag.String("dns", "1.1.1.1,1.0.0.1", "DNS of the adapter")
	verbose := flag.Bool("v", false, "detailed log of the daemon")
	flag.Parse()

	raw, err := os.ReadFile(*file)
	if err != nil {
		fatal(err)
	}
	cfg, err := awgconf.Parse(string(raw))
	if err != nil {
		fatal(err)
	}
	var dns []netip.Addr
	for _, s := range strings.Split(*dnsFlag, ",") {
		a, err := netip.ParseAddr(strings.TrimSpace(s))
		if err != nil {
			fatal(err)
		}
		dns = append(dns, a)
	}
	start := time.Now()
	opt := tunnel.Options{DNS: dns, Logf: func(f string, a ...any) {
		fmt.Printf("%6.2fs  %s\n", time.Since(start).Seconds(), fmt.Sprintf(f, a...))
	}}
	if *verbose {
		opt.DeviceLogf = func(f string, a ...any) { fmt.Printf(f+"\n", a...) }
	}
	t, err := tunnel.Up(cfg, opt)
	if err != nil {
		fatal(err)
	}
	defer t.Close()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	end := time.After(*hold)
	tick := time.NewTicker(3 * time.Second)
	defer tick.Stop()
wait:
	for {
		select {
		case <-stop:
			break wait
		case <-end:
			break wait
		case <-tick.C:
			rx, tx := t.Counters()
			fmt.Printf("%6.2fs  received %d, sent %d bytes\n", time.Since(start).Seconds(), rx, tx)
		}
	}
	rx, tx := t.Counters()
	fmt.Printf("received %d bytes, sent %d bytes\n", rx, tx)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
