package tgproxy

import (
	"context"
	"fmt"
	"math"

	"sync"
	"time"
)

type poolKey struct {
	dc      int
	isMedia bool
}

// wsPool keeps ready WebSocket connections to the gateway, so that a client does not wait for a TLS handshake.
type wsPool struct {
	e *Engine

	mu             sync.Mutex
	idle           map[poolKey][]*wsConn
	refilling      map[poolKey]bool
	failures       map[poolKey]int
	retryAfter     map[poolKey]time.Time
	tryFrontingFst bool
}

const (
	poolSize   = 4
	poolMaxAge = 120 * time.Second
)

func newPool(e *Engine) *wsPool {
	return &wsPool{e: e, idle: map[poolKey][]*wsConn{}, refilling: map[poolKey]bool{}, failures: map[poolKey]int{}, retryAfter: map[poolKey]time.Time{}}
}

func webSocketDomains(dc int, isMedia bool) []string {
	number := dc
	if dc == 203 {
		number = 2
	}
	if isMedia {
		return []string{fmt.Sprintf("kws%d-1.web.telegram.org", number), fmt.Sprintf("kws%d.web.telegram.org", number)}
	}
	return []string{fmt.Sprintf("kws%d.web.telegram.org", number)}
}

func (p *wsPool) warmUp() {
	for dc := range p.e.cfg.WebSocketAddress {
		for _, media := range []bool{false, true} {
			p.refill(poolKey{dc, media})
		}
	}
}

// take returns a ready connection, or makes one right now; nil if the gateway cannot be reached.
func (p *wsPool) take(ctx context.Context, dc int, isMedia bool) *wsConn {
	address, ok := p.e.cfg.WebSocketAddress[dc]
	if !ok {
		return nil
	}
	key := poolKey{dc, isMedia}
	p.mu.Lock()
	for len(p.idle[key]) > 0 {
		candidate := p.idle[key][0]
		p.idle[key] = p.idle[key][1:]
		if candidate.usable() && time.Since(candidate.createdAt) < poolMaxAge {
			p.mu.Unlock()
			p.refill(key)
			return candidate
		}
		go candidate.close()
	}
	p.mu.Unlock()
	p.refill(key)
	return p.connectOne(ctx, address, webSocketDomains(dc, isMedia))
}

func (p *wsPool) refill(key poolKey) {
	address, ok := p.e.cfg.WebSocketAddress[key.dc]
	p.mu.Lock()
	defer p.mu.Unlock()
	if !ok || p.refilling[key] || time.Now().Before(p.retryAfter[key]) || !p.e.isRunning() {
		return
	}
	p.refilling[key] = true
	go p.fill(key, address)
}

func (p *wsPool) fill(key poolKey, address string) {
	defer func() {
		p.mu.Lock()
		delete(p.refilling, key)
		p.mu.Unlock()
	}()
	p.mu.Lock()
	var kept []*wsConn
	for _, c := range p.idle[key] {
		if c.usable() && time.Since(c.createdAt) < poolMaxAge {
			kept = append(kept, c)
		} else {
			go c.close()
		}
	}
	p.idle[key] = kept
	needed := poolSize - len(kept)
	p.mu.Unlock()
	if needed <= 0 {
		return
	}
	domains := webSocketDomains(key.dc, key.isMedia)
	made := 0
	for i := 0; i < needed; i++ {
		if !p.e.isRunning() {
			break
		}
		c := p.connectOne(context.Background(), address, domains)
		if c == nil {
			break
		}
		p.mu.Lock()
		p.idle[key] = append(p.idle[key], c)
		p.mu.Unlock()
		made++
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if made > 0 {
		delete(p.failures, key)
		delete(p.retryAfter, key)
		return
	}
	p.failures[key]++
	delay := math.Min(math.Pow(2, float64(min(p.failures[key]-1, 12))), 3600)
	p.retryAfter[key] = time.Now().Add(time.Duration(delay) * time.Second)
}

// connectOne tries the domains, each with the real name and with a borrowed one ("fronting"), whichever worked last first.
func (p *wsPool) connectOne(ctx context.Context, address string, domains []string) *wsConn {
	for _, domain := range domains {
		p.mu.Lock()
		order := []bool{false, true}
		if p.tryFrontingFst {
			order = []bool{true, false}
		}
		p.mu.Unlock()
		for _, fronted := range order {
			sni, timeout := "", 8*time.Second
			if fronted {
				sni, timeout = "sprinthost.ru", 7*time.Second
			}
			c, err := dialWS(ctx, address, domain, "/apiws", sni, timeout, p.e.cfg.Dial)
			if err == nil {
				p.mu.Lock()
				p.tryFrontingFst = fronted
				p.mu.Unlock()
				return c
			}
		}
	}
	return nil
}

func (p *wsPool) closeAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, list := range p.idle {
		for _, c := range list {
			go c.close()
		}
	}
	p.idle = map[poolKey][]*wsConn{}
	p.retryAfter = map[poolKey]time.Time{}
	p.failures = map[poolKey]int{}
}
