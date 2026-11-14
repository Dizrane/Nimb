// Package startup binds a start to its stop request, even when the stop arrives first on another connection.
package startup

import (
	"context"
	"sync"
	"time"
)

type job struct{ cancel context.CancelFunc }
type Controller struct {
	mu      sync.Mutex
	active  map[*job]struct{}
	stopped map[string]time.Time
	off     bool
}

func (c *Controller) Begin(parent context.Context, id string) (context.Context, func()) {
	return c.begin(parent, id, false)
}
func (c *Controller) BeginRecovery(parent context.Context) (context.Context, func()) {
	return c.begin(parent, "", true)
}
func (c *Controller) begin(parent context.Context, id string, recovery bool) (context.Context, func()) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.active == nil {
		c.active = map[*job]struct{}{}
	}
	if c.stopped == nil {
		c.stopped = map[string]time.Time{}
	}
	for key, at := range c.stopped {
		if time.Since(at) > 5*time.Minute {
			delete(c.stopped, key)
		}
	}
	ctx, cancel := context.WithTimeout(parent, 120*time.Second)
	_, stopped := c.stopped[id]
	if (stopped && id != "") || (recovery && c.off) {
		cancel()
	} else if !recovery {
		c.off = false
	}
	j := &job{cancel: cancel}
	c.active[j] = struct{}{}
	return ctx, func() { c.mu.Lock(); defer c.mu.Unlock(); cancel(); delete(c.active, j) }
}
func (c *Controller) Cancel(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.off = true
	if c.stopped == nil {
		c.stopped = map[string]time.Time{}
	}
	if id != "" {
		if len(c.stopped) >= 256 {
			for key := range c.stopped {
				delete(c.stopped, key)
				break
			}
		}
		c.stopped[id] = time.Now()
	}
	for j := range c.active {
		j.cancel()
	}
}
