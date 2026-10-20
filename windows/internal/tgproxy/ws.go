package tgproxy

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

const maxFrame = 16 * 1024 * 1024

// HandshakeError is an answer other than 101 to the request for a WebSocket.
type HandshakeError struct {
	Status   string
	Location string
}

func (e *HandshakeError) Error() string { return e.Status }

// wsConn is a minimal WebSocket client for Telegram's /apiws gateway: binary frames only, masked on the way out.
type wsConn struct {
	conn      net.Conn
	reader    *bufio.Reader
	writeMu   sync.Mutex
	closed    atomic.Bool
	fragments []byte
	createdAt time.Time
}

// dialWS connects to address (an IP, port 443), asks for the WebSocket upgrade with Host: domain and checks for status 101.
// A sni other than the domain is the "fronting" variant: the certificate is then not checked.
func dialWS(ctx context.Context, address, domain, path, sni string, timeout time.Duration, dial func(ctx context.Context, network, addr string) (net.Conn, error)) (*wsConn, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if dial == nil {
		dial = (&net.Dialer{}).DialContext
	}
	raw, err := dial(ctx, "tcp", net.JoinHostPort(address, "443"))
	if err != nil {
		return nil, err
	}
	if tcp, ok := raw.(*net.TCPConn); ok {
		tcp.SetNoDelay(true)
	}
	serverName := domain
	if sni != "" {
		serverName = sni
	}
	tlsConn := tls.Client(raw, &tls.Config{ServerName: serverName, InsecureSkipVerify: sni != "", MinVersion: tls.VersionTLS12})
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		raw.Close()
		return nil, err
	}
	c, err := upgrade(ctx, tlsConn, domain, path, timeout)
	if err != nil {
		tlsConn.Close()
		return nil, err
	}
	return c, nil
}

func upgrade(ctx context.Context, conn net.Conn, domain, path string, timeout time.Duration) (*wsConn, error) {
	var key [16]byte
	rand.Read(key[:])
	request := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"+
		"Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n",
		path, domain, base64.StdEncoding.EncodeToString(key[:]))
	conn.SetDeadline(time.Now().Add(timeout))
	defer conn.SetDeadline(time.Time{})
	if _, err := io.WriteString(conn, request); err != nil {
		return nil, err
	}
	reader := bufio.NewReaderSize(conn, 64*1024)
	probe, _ := http.NewRequest("GET", "https://"+domain+path, nil)
	resp, err := http.ReadResponse(reader, probe)
	if err != nil {
		return nil, errors.New("ответ на рукопожатие не прочитан")
	}
	if resp.StatusCode != 101 {
		return nil, &HandshakeError{Status: resp.Status, Location: resp.Header.Get("Location")}
	}
	return &wsConn{conn: conn, reader: reader, createdAt: time.Now()}, nil
}

func (w *wsConn) usable() bool { return !w.closed.Load() }

// send writes one binary message.
func (w *wsConn) send(payload []byte) error { return w.sendBatch([][]byte{payload}) }

// sendBatch writes several messages with one write to the network.
func (w *wsConn) sendBatch(parts [][]byte) error {
	if w.closed.Load() {
		return errors.New("WebSocket закрыт")
	}
	var all []byte
	for _, part := range parts {
		all = appendFrame(all, 0x2, part)
	}
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	_, err := w.conn.Write(all)
	return err
}

// receive returns the next whole message from the server, or io.EOF once it has closed the connection.
func (w *wsConn) receive() ([]byte, error) {
	for !w.closed.Load() {
		opcode, payload, fin, err := w.readFrame()
		if err != nil {
			return nil, err
		}
		switch opcode {
		case 0x8:
			w.closed.Store(true)
			w.writeFrame(0x8, payload[:min(2, len(payload))])
			return nil, io.EOF
		case 0x9:
			w.writeFrame(0xA, payload)
		case 0xA:
		default:
			if fin && len(w.fragments) == 0 {
				return payload, nil
			}
			w.fragments = append(w.fragments, payload...)
			if len(w.fragments) > maxFrame {
				return nil, errors.New("сообщение WebSocket слишком большое")
			}
			if fin {
				message := w.fragments
				w.fragments = nil
				return message, nil
			}
		}
	}
	return nil, io.EOF
}

func (w *wsConn) writeFrame(opcode byte, payload []byte) {
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	w.conn.Write(appendFrame(nil, opcode, payload))
}

// close says goodbye (when it can) and closes the connection.
func (w *wsConn) close() {
	if w.closed.Swap(true) {
		w.conn.Close()
		return
	}
	w.conn.SetWriteDeadline(time.Now().Add(time.Second))
	w.writeFrame(0x8, nil)
	w.conn.Close()
}

// appendFrame adds a masked frame (a client must mask) to dst.
func appendFrame(dst []byte, opcode byte, payload []byte) []byte {
	dst = append(dst, 0x80|opcode)
	length := len(payload)
	switch {
	case length < 126:
		dst = append(dst, 0x80|byte(length))
	case length < 65536:
		dst = append(dst, 0x80|126, byte(length>>8), byte(length))
	default:
		dst = append(dst, 0x80|127)
		dst = binary.BigEndian.AppendUint64(dst, uint64(length))
	}
	var mask [4]byte
	rand.Read(mask[:])
	dst = append(dst, mask[:]...)
	start := len(dst)
	dst = append(dst, payload...)
	for i := range payload {
		dst[start+i] ^= mask[i&3]
	}
	return dst
}

func (w *wsConn) readFrame() (opcode byte, payload []byte, fin bool, err error) {
	var head [2]byte
	if _, err = io.ReadFull(w.reader, head[:]); err != nil {
		return
	}
	fin = head[0]&0x80 != 0
	opcode = head[0] & 0x0f
	masked := head[1]&0x80 != 0
	length := uint64(head[1] & 0x7f)
	switch length {
	case 126:
		var b [2]byte
		if _, err = io.ReadFull(w.reader, b[:]); err != nil {
			return
		}
		length = uint64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err = io.ReadFull(w.reader, b[:]); err != nil {
			return
		}
		length = binary.BigEndian.Uint64(b[:])
		if length > maxFrame {
			err = errors.New("кадр WebSocket слишком большой")
			return
		}
	}
	var mask [4]byte
	if masked {
		if _, err = io.ReadFull(w.reader, mask[:]); err != nil {
			return
		}
	}
	payload = make([]byte, length)
	if _, err = io.ReadFull(w.reader, payload); err != nil {
		return
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i&3]
		}
	}
	return
}
