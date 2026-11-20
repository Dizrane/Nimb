package helper

import (
	"fmt"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

// A successful command is not enough: both DNS families must be read back. The callbacks keep this check testable without changing a network.
func writeDNSAdapters(adapters []dnsx.Adapter, provider dnsx.Provider,
	write4, write6 func(dnsx.Adapter) error, current func(string) (dnsx.Adapter, bool), logf func(string, ...any),
) (failed []string) {
	for _, a := range adapters {
		a.NameServer, a.NameServer6 = provider.Servers(), provider.Servers6()
		err := write4(a)
		if err == nil && a.Set6 {
			err = write6(a)
		}
		if err == nil {
			after, ok := current(a.GUID)
			switch {
			case !ok:
				err = fmt.Errorf("не удалось проверить DNS на «%s»", a.Name)
			case !dnsx.Same(after.NameServer, a.NameServer):
				err = fmt.Errorf("серверы DNS на «%s» не приняты системой", a.Name)
			case a.Set6 && !dnsx.Same6(after.NameServer6, a.NameServer6):
				err = fmt.Errorf("серверы DNS IPv6 на «%s» не приняты системой", a.Name)
			}
		}
		if err != nil {
			failed = append(failed, a.Name)
			logf("DNS: %v", err)
		}
	}
	return failed
}
