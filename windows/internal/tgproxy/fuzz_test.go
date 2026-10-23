package tgproxy

import (
	"bufio"
	"bytes"
	"net"
	"testing"
	"time"
)

// What comes from the network must never make the proxy panic: a client may send anything, and so may a server that is not the one we
// think it is. The corpus is a few real shapes; `go test -fuzz` finds the rest.

func FuzzSplitter(f *testing.F) {
	f.Add([]byte{0x01, 1, 2, 3, 4}, uint8(0))
	f.Add([]byte{0x7f, 0xff, 0xff, 0xff, 1, 2, 3, 4}, uint8(0))
	f.Add([]byte{4, 0, 0, 0, 1, 2, 3, 4}, uint8(1))
	f.Add([]byte{0xff, 0xff, 0xff, 0xff, 1}, uint8(2))
	f.Fuzz(func(t *testing.T, data []byte, kind uint8) {
		s := NewSplitter(Transport(kind % 3))
		// In pieces of different sizes, as a network gives them.
		for i := 0; i < len(data); i += 1 + i%7 {
			end := min(len(data), i+1+i%7)
			s.Split(data[i:end], data[i:end])
		}
		s.Flush()
	})
}

func FuzzParseHandshake(f *testing.F) {
	f.Add(make([]byte, handshakeLength))
	f.Add(bytes.Repeat([]byte{0xee}, handshakeLength))
	f.Fuzz(func(t *testing.T, header []byte) {
		secret := bytes.Repeat([]byte{7}, 16)
		if len(header) != handshakeLength {
			header = append(header, make([]byte, handshakeLength)...)[:handshakeLength]
		}
		if hs := ParseHandshake(header, secret); hs != nil {
			MakeCiphers(hs, secret, MakeRelayInit(hs.Tag, hs.DC))
		}
	})
}

// discardConn is the other end of a connection that takes everything (the answers to a ping or a close).
type discardConn struct{ net.Conn }

func (discardConn) Write(b []byte) (int, error)      { return len(b), nil }
func (discardConn) Close() error                     { return nil }
func (discardConn) SetWriteDeadline(time.Time) error { return nil }

func FuzzReadFrame(f *testing.F) {
	f.Add([]byte{0x82, 0x03, 1, 2, 3})
	f.Add([]byte{0x82, 0x7e, 0x00, 0x05, 1, 2, 3, 4, 5})
	f.Add([]byte{0x82, 0xfe, 0x00, 0x02, 1, 2, 3, 4, 9, 9})
	f.Add([]byte{0x88, 0x00})
	f.Fuzz(func(t *testing.T, data []byte) {
		w := &wsConn{conn: discardConn{}, reader: bufio.NewReader(bytes.NewReader(data)), createdAt: time.Now()}
		for i := 0; i < 8; i++ {
			if _, err := w.receive(); err != nil {
				return
			}
		}
	})
}

func TestARecoveredPanicIsToldAndTheProgramGoesOn(t *testing.T) {
	var where string
	var stack []byte
	OnPanic = func(w string, v any, s []byte) { where, stack = w, s }
	defer func() { OnPanic = nil }()
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer recoverPanic("проверка")
		var m map[string]int
		m["a"] = 1 // a panic: assignment to a nil map
	}()
	<-done
	if where != "проверка" || !bytes.Contains(stack, []byte("fuzz_test.go")) {
		t.Errorf("where=%q stack=%q", where, stack)
	}
}
