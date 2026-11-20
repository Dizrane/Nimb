// dns-audit is a read-only diagnostic based on Nimb. It changes no DNS, routes or VPN settings and sends no reports.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
	"github.com/Dizrane/Nimb/windows/internal/probe"
)

type scan struct {
	At      time.Time
	Seconds float64
	Reports []probe.ProviderReport
}

func main() {
	output := flag.String("out", "", "save public-server results locally as JSON (new file only)")
	network := flag.String("network", "unknown", "network stated by the user: direct, vpn or unknown")
	rounds := flag.Int("rounds", 3, "number of complete checks, 1..10")
	interval := flag.Duration("interval", 10*time.Second, "pause between checks, 0..1m")
	flag.Parse()
	if *rounds < 1 || *rounds > 10 || *interval < 0 || *interval > time.Minute || (*network != "direct" && *network != "vpn" && *network != "unknown") {
		fmt.Fprintln(os.Stderr, "Invalid network, rounds or interval")
		os.Exit(2)
	}
	fmt.Println("DNS Audit — изменённая диагностика на основе Nimb; системные настройки не меняются")
	tunnel := observedTunnel()
	if runtime.GOOS == "darwin" && *network == "direct" && tunnel == nil {
		fmt.Fprintln(os.Stderr, "Не удалось проверить маршрут. Прогон без VPN не начат: состояние подключения неизвестно.")
		os.Exit(2)
	}
	if tunnel != nil && *tunnel && *network == "direct" {
		fmt.Fprintln(os.Stderr, "Обнаружен маршрут через туннель. Прогон без VPN не начат: отключите VPN и повторите команду.")
		os.Exit(2)
	}
	result := struct {
		OS, Architecture, UserStatedNetwork string
		ObservedTunnel                      *bool
		Scans                               []scan
	}{OS: runtime.GOOS, Architecture: runtime.GOARCH, UserStatedNetwork: *network, ObservedTunnel: tunnel}
	for i := 0; i < *rounds; i++ {
		if i > 0 {
			time.Sleep(*interval)
		}
		fmt.Printf("\nПроверка %d/%d; режим указан пользователем: %s\n", i+1, *rounds, *network)
		start := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		reports := (&probe.Prober{}).Run(ctx, dnsx.Available(), func(int, int) {})
		cancel()
		result.Scans = append(result.Scans, scan{At: start.UTC(), Seconds: time.Since(start).Seconds(), Reports: reports})
		for _, report := range reports {
			fmt.Printf("\n%s: доступно %d/%d\n%s\n", report.Provider.Name, report.WorkingCount(), len(probe.Services()), report.Details())
		}
		fmt.Printf("Время: %.1f с\n", time.Since(start).Seconds())
	}
	if *output != "" {
		f, err := os.OpenFile(*output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err == nil {
			enc := json.NewEncoder(f)
			enc.SetIndent("", "  ")
			err = enc.Encode(result)
			if closeErr := f.Close(); err == nil {
				err = closeErr
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "Не удалось сохранить результат:", err)
			os.Exit(1)
		}
		fmt.Println("\nРезультат сохранён:", *output)
	}
}

// A negative result is not a certificate of the absence of every split VPN or proxy. Unknown platforms keep a nil observation.
func observedTunnel() *bool {
	if runtime.GOOS != "darwin" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	raw, err := exec.CommandContext(ctx, "/sbin/route", "-n", "get", "1.1.1.1").Output()
	if err != nil {
		return nil
	}
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "interface:" {
			name := fields[1]
			found := strings.HasPrefix(name, "utun") || strings.HasPrefix(name, "ppp") || strings.HasPrefix(name, "ipsec")
			return &found
		}
	}
	return nil
}
