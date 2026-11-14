package autoreport

import (
	"context"
	"sync"
)

// Consent ties background reports to one uninterrupted opt-in. Replacing it cancels in-flight requests and invalidates old work.
type Consent struct {
	mu      sync.Mutex
	current *ConsentSession
}

// ConsentSession carries the installation number and the cancellation of the opt-in that started the work.
type ConsentSession struct {
	ctx     context.Context
	cancel  context.CancelFunc
	Install string
}

func (s *ConsentSession) Context() context.Context { return s.ctx }

func (c *Consent) Current() *ConsentSession {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.current
}

// Replace must also be called for a later opt-in with the same installation number: old work stays cancelled.
func (c *Consent) Replace(install string) *ConsentSession {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != nil {
		c.current.cancel()
	}
	c.current = nil
	if install != "" {
		ctx, cancel := context.WithCancel(context.Background())
		c.current = &ConsentSession{ctx: ctx, cancel: cancel, Install: install}
	}
	return c.current
}

func (c *Consent) Valid(s *ConsentSession) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return s != nil && c.current == s && s.ctx.Err() == nil
}

// With serializes a short persistence operation with opt-out, so cancelled work cannot recreate a wiped queue or snapshot.
// The operation must not block on a network request or call another method of Consent.
func (c *Consent) With(s *ConsentSession, operation func()) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if s == nil || c.current != s || s.ctx.Err() != nil {
		return false
	}
	operation()
	return true
}
