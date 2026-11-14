package sitecheck

import (
	"context"
	"fmt"
	"os"
	"testing"
)

// NIMB_LIVE=1 go test -run TestLive -v ./internal/sitecheck checks public addresses without changing the network.
func TestLive(t *testing.T) {
	if os.Getenv("NIMB_LIVE") == "" {
		t.Skip("set NIMB_LIVE=1 to check public addresses")
	}
	for _, check := range Run(context.Background(), Targets, Ask) {
		fmt.Printf("%s: %s\n", check.Name, check.Result())
		for _, probe := range check.Probes {
			fmt.Printf("  %s: %s\n", probe.Name, probe.Summary())
		}
	}
}
