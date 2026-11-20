package probe

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

func TestRunOverlapsDNSAndHTTPSWithoutLosingPoolSamples(t *testing.T) {
	started := make(chan struct{})
	var once sync.Once
	var overlapped bool
	var updates [][2]int
	p := &Prober{
		lookup: func(_ context.Context, host string, _ []string) []string {
			if host == All[0].Host {
				select {
				case <-started:
					overlapped = true
				case <-time.After(2 * time.Second):
				}
				return nil
			}
			return []string{"203.0.113.1", "203.0.113.2"}
		},
		fetch: func(context.Context, Target, string) Outcome {
			once.Do(func() { close(started) })
			return Outcome{Status: OK, Seconds: 0.2}
		},
	}
	reports := p.Run(context.Background(), dnsx.Available()[:1], func(done, total int) {
		updates = append(updates, [2]int{done, total})
	})
	if !overlapped {
		t.Error("HTTPS waited for an unrelated DNS lookup")
	}
	want := 2*len(All) - 1
	if len(reports) != 1 || len(reports[0].Samples) != want || reports[0].Samples[0].Address != "" {
		t.Fatalf("missing or reordered pool samples: %+v", reports)
	}
	if last := updates[len(updates)-1]; last != [2]int{want, want} {
		t.Errorf("final progress %v, want %d/%d", last, want, want)
	}
	for i := 1; i < len(updates); i++ {
		previous, next := updates[i-1], updates[i]
		if next[0] < previous[0] || previous[1] != 0 && next[1] != previous[1] {
			t.Errorf("progress went backwards: %v -> %v", previous, next)
		}
	}
}

func TestRunRetriesOnlyTheFailedHostAndAddress(t *testing.T) {
	var mu sync.Mutex
	calls := map[string]int{}
	failed := All[0].Host + ":203.0.113.1"
	p := &Prober{
		lookup: func(context.Context, string, []string) []string { return []string{"203.0.113.1", "203.0.113.2"} },
		fetch: func(_ context.Context, target Target, address string) Outcome {
			key := target.Host + ":" + address
			mu.Lock()
			calls[key]++
			mu.Unlock()
			if key == failed {
				return Outcome{Status: Failed}
			}
			return Outcome{Status: OK, Seconds: 0.2}
		},
	}
	reports := p.Run(context.Background(), dnsx.Available()[:1], func(int, int) {})
	if len(reports[0].Samples) != 2*len(All) || calls[failed] != 2 {
		t.Fatal("failed request was not preserved and retried")
	}
	for key, count := range calls {
		if key != failed && count != 1 {
			t.Errorf("unrelated request %s was retried %d times", key, count)
		}
	}
	if len(calls) != 2*len(All) {
		t.Fatal("a failure skipped other hosts sharing the IP")
	}
}

func TestSlowLaneDoesNotOccupyOtherProvidersSlots(t *testing.T) {
	blocked, healthy, finished := make(chan struct{}), make(chan struct{}, 1), make(chan struct{})
	var mu sync.Mutex
	active, peak := [2]int{}, [2]int{}
	go func() {
		eachInLanes(4*perProvider, 2, func(i int) int { return i / (2 * perProvider) }, func(i int) {
			lane := i / (2 * perProvider)
			mu.Lock()
			active[lane]++
			peak[lane] = max(peak[lane], active[lane])
			mu.Unlock()
			if lane == 0 {
				<-blocked
			} else {
				select {
				case healthy <- struct{}{}:
				default:
				}
			}
			mu.Lock()
			active[lane]--
			mu.Unlock()
		})
		close(finished)
	}()
	select {
	case <-healthy:
	case <-time.After(2 * time.Second):
		t.Error("slow provider held the healthy provider's slots")
	}
	close(blocked)
	<-finished
	if peak[0] > perProvider || peak[1] > perProvider {
		t.Errorf("unbounded concurrency: %v", peak)
	}
}
