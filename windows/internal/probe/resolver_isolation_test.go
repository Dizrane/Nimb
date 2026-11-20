package probe

import (
	"context"
	"slices"
	"testing"
)

func TestProviderLookupDoesNotUseTheSystemHostsFile(t *testing.T) {
	port, asked := fakeDNS(t, []string{"203.0.113.9"})
	p := &Prober{DNSPort: port}
	got := p.resolve(context.Background(), "localhost", []string{"127.0.0.1"})
	if !slices.Equal(got, []string{"203.0.113.9"}) || asked.Load() == 0 {
		t.Fatalf("a direct provider check used hosts instead of DNS: got %v; provider queried %d times", got, asked.Load())
	}
}
