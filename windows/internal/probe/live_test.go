package probe

import (
	"context"
	"fmt"
	"os"
	"testing"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

// NIMB_LIVE=1 go test -run Live -v ./internal/probe asks the real providers and prints what the window would show.
func TestLive(t *testing.T) {
	if os.Getenv("NIMB_LIVE") == "" {
		t.Skip("set NIMB_LIVE=1 to ask the real providers")
	}
	reports := (&Prober{}).Run(context.Background(), dnsx.Providers, func(done, total int) {})
	for _, r := range reports {
		m, _ := r.Median()
		fmt.Printf("== %s: works %d of %d, median %.2f s\n", r.Provider.Name, r.WorkingCount(), len(Services()), m)
		fmt.Println(r.Details())
		for _, s := range r.Services() {
			fmt.Printf("   %-11s %-8s %d/%d (refused %d)\n", s.Name, s.Status(), s.Answered, s.Total, s.Blocked)
		}
	}
	if b := Best(reports); b != nil {
		fmt.Println("BEST:", b.Provider.Name)
	}
}
