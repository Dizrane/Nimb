package tgproxy

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// Stats are the numbers shown in the window and the menu.
type Stats struct {
	Total     int
	Active    int
	WebSocket int
	DirectTCP int
	Failures  int
	// WrongSecret counts connections that did not know this proxy's secret: a client set up for another proxy on the same port.
	WrongSecret int
	BytesUp     int64
	BytesDown   int64
}

// Config says where Telegram is. The defaults are those of TG WS Proxy; tests put their own.
type Config struct {
	// WebSocketAddress: data centers that are reached through the WebSocket gateway at this address.
	WebSocketAddress      map[int]string
	DataCenterAddress     map[int]string
	TestDataCenterAddress map[int]string
	// Dial opens a connection; nil means the system's. It exists for tests.
	Dial func(ctx context.Context, network, address string) (net.Conn, error)
	// Logf receives one line per connection event (no keys, no message contents).
	Logf func(string)
}

// DefaultConfig is where Telegram really is.
func DefaultConfig() Config {
	return Config{
		WebSocketAddress:      map[int]string{2: "149.154.167.220", 4: "149.154.167.220"},
		DataCenterAddress:     map[int]string{1: "149.154.175.50", 2: "149.154.167.51", 3: "149.154.175.100", 4: "149.154.167.91", 5: "149.154.171.5", 203: "91.105.192.100"},
		TestDataCenterAddress: map[int]string{1: "149.154.175.10", 2: "149.154.167.40", 3: "149.154.175.117"},
	}
}

// Engine is the proxy.
type Engine struct {
	secret []byte
	cfg    Config
	pool   *wsPool

	mu       sync.Mutex
	listener net.Listener
	sessions map[net.Conn]struct{}
	stats    Stats
	stopped  bool
	dead     bool // the listener broke by itself
	port     uint16
}

// New makes a proxy for a secret of 32 hex digits.
func New(secretHex string, cfg Config) (*Engine, error) {
	secret, err := hex.DecodeString(secretHex)
	if err != nil || len(secret) != 16 {
		return nil, errors.New("secret должен быть 32 шестнадцатеричными цифрами")
	}
	e := &Engine{secret: secret, cfg: cfg, sessions: map[net.Conn]struct{}{}, stopped: true}
	e.pool = newPool(e)
	return e, nil
}

func (e *Engine) logf(format string, args ...any) {
	if e.cfg.Logf != nil {
		e.cfg.Logf(fmt.Sprintf(format, args...))
	}
}

func (e *Engine) count(change func(*Stats)) {
	e.mu.Lock()
	change(&e.stats)
	e.mu.Unlock()
}

// Stats returns the numbers so far.
func (e *Engine) Stats() Stats {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.stats
}

func (e *Engine) isRunning() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return !e.stopped
}

// IsListening says whether the port is really open: after a sleep or a change of the network the listener may be gone while the
// engine still believes it is on.
func (e *Engine) IsListening() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return !e.stopped && !e.dead
}

// Port is the port the proxy listens on (0 when it is off).
func (e *Engine) Port() uint16 {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.port
}

// Start listens on 127.0.0.1, on preferred or the next free port after it (twenty tries), and returns the port. A preferred
// port of 0 means any free port (for tests).
func (e *Engine) Start(preferred uint16) (uint16, error) {
	e.mu.Lock()
	e.stopped, e.dead, e.stats = false, false, Stats{}
	e.mu.Unlock()

	var last error = errors.New("нет свободного порта")
	tries := 20
	if preferred == 0 {
		tries = 1 // 0 asks the system for any free port
	}
	for i := 0; i < tries && int(preferred)+i <= 65535; i++ {
		l, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", fmt.Sprint(int(preferred)+i)))
		if err != nil {
			last = err
			continue
		}
		port := uint16(l.Addr().(*net.TCPAddr).Port)
		e.mu.Lock()
		e.listener, e.port = l, port
		e.mu.Unlock()
		e.logf("Слушаю 127.0.0.1:%d", port)
		go e.acceptLoop(l)
		go e.pool.warmUp()
		return port, nil
	}
	e.mu.Lock()
	e.stopped = true
	e.mu.Unlock()
	return 0, last
}

// Stop closes the port and every connection.
func (e *Engine) Stop() {
	e.mu.Lock()
	e.stopped = true
	l := e.listener
	e.listener, e.port = nil, 0
	open := make([]net.Conn, 0, len(e.sessions))
	for c := range e.sessions {
		open = append(open, c)
	}
	e.sessions = map[net.Conn]struct{}{}
	e.mu.Unlock()
	if l != nil {
		l.Close()
	}
	for _, c := range open {
		c.Close()
	}
	e.pool.closeAll()
	e.logf("Остановлен")
}

func (e *Engine) acceptLoop(l net.Listener) {
	defer recoverPanic("прокси Telegram: приём соединений")
	for {
		conn, err := l.Accept()
		if err != nil {
			e.mu.Lock()
			if !e.stopped && e.listener == l {
				e.dead = true
			}
			e.mu.Unlock()
			return
		}
		go e.handle(conn)
	}
}

// handle is one client.
func (e *Engine) handle(client net.Conn) {
	defer recoverPanic("прокси Telegram: соединение клиента")
	e.mu.Lock()
	if e.stopped {
		e.mu.Unlock()
		client.Close()
		return
	}
	e.sessions[client] = struct{}{}
	e.stats.Total++
	e.stats.Active++
	e.mu.Unlock()
	defer func() {
		client.Close()
		e.mu.Lock()
		delete(e.sessions, client)
		e.stats.Active--
		e.mu.Unlock()
	}()
	if tcp, ok := client.(*net.TCPConn); ok {
		tcp.SetNoDelay(true)
	}

	client.SetReadDeadline(time.Now().Add(10 * time.Second))
	header := make([]byte, handshakeLength)
	if _, err := io.ReadFull(client, header); err != nil {
		e.count(func(s *Stats) { s.Failures++ })
		e.logf("Ошибка соединения: %v", err)
		return
	}
	client.SetReadDeadline(time.Time{})
	hs := ParseHandshake(header, e.secret)
	if hs == nil {
		e.count(func(s *Stats) { s.WrongSecret++ })
		e.logf("Неверное рукопожатие (чужой secret или протокол)")
		return
	}
	dcIndex := hs.DC
	if hs.IsMedia {
		dcIndex = -hs.DC
	}
	relayInit := MakeRelayInit(hs.Tag, dcIndex)
	ciphers := MakeCiphers(hs, e.secret, relayInit)
	tag := fmt.Sprintf("DC%d", hs.DC)
	if hs.IsMedia {
		tag += " media"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	var ws *wsConn
	if !hs.IsTestDC {
		ws = e.pool.take(ctx, hs.DC, hs.IsMedia)
	}
	cancel()
	if ws != nil {
		e.count(func(s *Stats) { s.WebSocket++ })
		e.logf("%s → WebSocket", tag)
		if err := ws.send(relayInit); err != nil {
			ws.close()
			e.count(func(s *Stats) { s.Failures++ })
			e.logf("Ошибка соединения: %v", err)
			return
		}
		e.bridgeWS(client, ciphers, hs.Transport, ws)
		return
	}

	table := e.cfg.DataCenterAddress
	if hs.IsTestDC {
		table = e.cfg.TestDataCenterAddress
	}
	address, ok := table[hs.DC]
	if !ok {
		e.count(func(s *Stats) { s.Failures++ })
		e.logf("%s: неизвестный дата-центр", tag)
		return
	}
	e.logf("%s → прямое TCP %s", tag, address)
	ctx, cancel = context.WithTimeout(context.Background(), 10*time.Second)
	dial := e.cfg.Dial
	if dial == nil {
		dial = (&net.Dialer{}).DialContext
	}
	remote, err := dial(ctx, "tcp", net.JoinHostPort(address, "443"))
	cancel()
	if err != nil {
		e.count(func(s *Stats) { s.Failures++ })
		e.logf("Ошибка соединения: %v", err)
		return
	}
	defer remote.Close()
	if _, err := remote.Write(relayInit); err != nil {
		e.count(func(s *Stats) { s.Failures++ })
		e.logf("Ошибка соединения: %v", err)
		return
	}
	e.count(func(s *Stats) { s.DirectTCP++ })
	e.bridgeTCP(client, ciphers, remote)
}

func (e *Engine) bridgeWS(client net.Conn, c *Ciphers, transport Transport, ws *wsConn) {
	done := make(chan struct{}, 2)
	go func() { // the client to Telegram
		defer func() { done <- struct{}{} }()
		defer recoverPanic("прокси Telegram: от клиента к Telegram (WebSocket)")
		splitter := NewSplitter(transport)
		buf := make([]byte, 64*1024)
		for {
			n, err := client.Read(buf)
			if n > 0 {
				e.count(func(s *Stats) { s.BytesUp += int64(n) })
				plain := xor(c.FromClient, buf[:n])
				encrypted := xor(c.ToTelegram, plain)
				parts := splitter.Split(encrypted, plain)
				if len(parts) > 0 {
					if serr := ws.sendBatch(parts); serr != nil {
						return
					}
				}
			}
			if err != nil {
				if tail := splitter.Flush(); tail != nil {
					ws.send(tail)
				}
				return
			}
		}
	}()
	go func() { // Telegram to the client
		defer func() { done <- struct{}{} }()
		defer recoverPanic("прокси Telegram: от Telegram к клиенту (WebSocket)")
		for {
			message, err := ws.receive()
			if err != nil {
				return
			}
			e.count(func(s *Stats) { s.BytesDown += int64(len(message)) })
			if _, err := client.Write(xor(c.ToClient, xor(c.FromTelegram, message))); err != nil {
				return
			}
		}
	}()
	<-done
	client.Close()
	ws.close()
	<-done
}

func (e *Engine) bridgeTCP(client net.Conn, c *Ciphers, remote net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		defer func() { done <- struct{}{} }()
		defer recoverPanic("прокси Telegram: от клиента к Telegram (TCP)")
		buf := make([]byte, 64*1024)
		for {
			n, err := client.Read(buf)
			if n > 0 {
				e.count(func(s *Stats) { s.BytesUp += int64(n) })
				if _, werr := remote.Write(xor(c.ToTelegram, xor(c.FromClient, buf[:n]))); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		defer recoverPanic("прокси Telegram: от Telegram к клиенту (TCP)")
		buf := make([]byte, 64*1024)
		for {
			n, err := remote.Read(buf)
			if n > 0 {
				e.count(func(s *Stats) { s.BytesDown += int64(n) })
				if _, werr := client.Write(xor(c.ToClient, xor(c.FromTelegram, buf[:n]))); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	<-done
	client.Close()
	remote.Close()
	<-done
}
