package tgproxy

import (
	"bufio"
	"bytes"
	"context"
	"crypto/cipher"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func unhex(s string) []byte { b, _ := hex.DecodeString(s); return b }

// NIST SP 800-38A, F.5.5: CTR-AES256.Encrypt. If AES-CTR is wrong, no Telegram message gets through, and nothing else would show why.
func TestAESCTRMatchesTheNISTVector(t *testing.T) {
	key := unhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
	iv := unhex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
	plain := unhex("6bc1bee22e409f96e93d7e117393172a" + "ae2d8a571e03ac9c9eb76fac45af8e51")
	want := unhex("601ec313775789a5b7a7f504bbf3d228" + "f443e3ca4d62b59aca84e990cacaf5c5")
	if got := xor(ctr(key, iv), plain); !bytes.Equal(got, want) {
		t.Fatalf("got %x", got)
	}
	// In pieces it is the same stream.
	s := ctr(key, iv)
	var got []byte
	for _, piece := range [][]byte{plain[:5], plain[5:25], plain[25:]} {
		got = append(got, xor(s, piece)...)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("pieces: got %x", got)
	}
}

var secret = func() []byte {
	b := make([]byte, 16)
	for i := range b {
		b[i] = byte(i*7 + 3)
	}
	return b
}()

// clientHeader is the header as a client makes it.
func clientHeader(secret []byte, tag [4]byte, dcIndex int) []byte {
	header := randomHeader()
	prekeyAndIV := header[skip : skip+prekey+ivLength]
	putTail(header, keyFrom(prekeyAndIV[:prekey], secret), prekeyAndIV[prekey:], tag, dcIndex)
	return header
}

func TestParseReadsTheDataCenterAndTransport(t *testing.T) {
	cases := []struct {
		name  string
		tag   [4]byte
		index int
		dc    int
		media bool
		test  bool
		tr    Transport
	}{
		{"plain", tagSecure, 2, 2, false, false, PaddedIntermediate},
		{"media", tagSecure, -4, 4, true, false, PaddedIntermediate},
		{"test dc", tagSecure, 10003, 3, false, true, PaddedIntermediate},
		{"abridged", tagAbridged, 1, 1, false, false, Abridged},
		{"intermediate", tagIntermediate, 1, 1, false, false, Intermediate},
	}
	for _, c := range cases {
		h := ParseHandshake(clientHeader(secret, c.tag, c.index), secret)
		if h == nil || h.DC != c.dc || h.IsMedia != c.media || h.IsTestDC != c.test || h.Transport != c.tr {
			t.Errorf("%s: %+v", c.name, h)
		}
	}
}

// The case the warning «Telegram подключается с чужим ключом» is about.
func TestAnotherSecretNoiseAndWrongLengthAreRefused(t *testing.T) {
	other := make([]byte, 16)
	for i := range other {
		other[i] = byte(i*11 + 5)
	}
	if ParseHandshake(clientHeader(other, tagSecure, 2), secret) != nil {
		t.Error("another secret must be refused")
	}
	noise := make([]byte, 64)
	rand.Read(noise)
	if ParseHandshake(noise, secret) != nil || ParseHandshake(make([]byte, 63), secret) != nil || ParseHandshake(make([]byte, 65), secret) != nil {
		t.Error("noise and a wrong length must be refused")
	}
}

func TestTheRelayHeaderCarriesTheTagAndTheDataCenter(t *testing.T) {
	for i := 0; i < 200; i++ {
		relay := MakeRelayInit(tagSecure, 5)
		if len(relay) != 64 || relay[0] == 0xef {
			t.Fatal("bad header")
		}
		plain := xor(ctr(relay[8:40], relay[40:56]), relay)
		if !bytes.Equal(plain[56:60], tagSecure[:]) || int16(binary.LittleEndian.Uint16(plain[60:])) != 5 {
			t.Fatalf("tail is %x", plain[56:64])
		}
	}
}

func TestSplitterCutsPacketsWhatevertheChunks(t *testing.T) {
	packet := func(n int) []byte { // intermediate: length, then payload
		p := binary.LittleEndian.AppendUint32(nil, uint32(n))
		return append(p, bytes.Repeat([]byte{byte(n)}, n)...)
	}
	stream := append(append(packet(8), packet(20)...), packet(4)...)
	// "Encrypted" bytes are the same as plain ones here: the splitter only looks at the plain side and cuts the other.
	for _, chunk := range []int{1, 3, 7, 10, len(stream)} {
		s := NewSplitter(Intermediate)
		var parts [][]byte
		for i := 0; i < len(stream); i += chunk {
			end := min(i+chunk, len(stream))
			parts = append(parts, s.Split(stream[i:end], stream[i:end])...)
		}
		if len(parts) != 3 || len(parts[0]) != 12 || len(parts[1]) != 24 || len(parts[2]) != 8 {
			t.Fatalf("chunk %d: %d parts", chunk, len(parts))
		}
	}
}

func TestSplitterAbridgedShortAndLong(t *testing.T) {
	short := append([]byte{3}, bytes.Repeat([]byte{1}, 12)...) // 3 words
	long := append([]byte{0x7f, 2, 0, 0}, bytes.Repeat([]byte{2}, 8)...)
	stream := append(append([]byte{}, short...), long...)
	s := NewSplitter(Abridged)
	parts := s.Split(stream, stream)
	if len(parts) != 2 || len(parts[0]) != 13 || len(parts[1]) != 12 {
		t.Fatalf("parts %d", len(parts))
	}
}

func TestSplitterGivesUpOnUnknownFramingAndFlushesTheRest(t *testing.T) {
	s := NewSplitter(Intermediate)
	zero := make([]byte, 16)
	if parts := s.Split(zero, zero); len(parts) != 1 || len(parts[0]) != 16 {
		t.Fatalf("unknown framing must pass the bytes on whole: %d", len(parts))
	}
	if parts := s.Split([]byte{1, 2, 3}, []byte{1, 2, 3}); len(parts) != 1 {
		t.Fatal("after giving up everything passes whole")
	}
	s = NewSplitter(Intermediate)
	s.Split([]byte{9, 0, 0, 0, 1}, []byte{9, 0, 0, 0, 1})
	if rest := s.Flush(); len(rest) != 5 || s.Flush() != nil {
		t.Fatal("flush returns the unfinished packet once")
	}
}

func TestFrameRoundTrip(t *testing.T) {
	for _, n := range []int{0, 1, 125, 126, 300, 65535, 65536, 100000} {
		payload := make([]byte, n)
		rand.Read(payload)
		w := &wsConn{reader: bufio.NewReader(bytes.NewReader(appendFrame(nil, 0x2, payload)))}
		opcode, got, fin, err := w.readFrame()
		if err != nil || opcode != 2 || !fin || !bytes.Equal(got, payload) {
			t.Fatalf("n=%d: err=%v opcode=%d fin=%v equal=%v", n, err, opcode, fin, bytes.Equal(got, payload))
		}
	}
}

// ---- a pretend Telegram -------------------------------------------------------------------------------------------------

// pretendTelegram is what a data center does: it reads the 64-byte header, decrypts what the proxy sends, and answers every packet
// with a packet "echo:" plus the payload, encrypted with the other direction of the session.
type pretendTelegram struct {
	mu       sync.Mutex
	messages [][]byte // plain bytes of each WebSocket message (or each read of the TCP stream)
	headers  int
}

func (p *pretendTelegram) record(b []byte) {
	p.mu.Lock()
	p.messages = append(p.messages, b)
	p.mu.Unlock()
}

func (p *pretendTelegram) seen() [][]byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([][]byte(nil), p.messages...)
}

func sessionStreams(relay []byte) (in, out cipher.Stream) {
	in = ctr(relay[8:40], relay[40:56])
	in.XORKeyStream(make([]byte, 64), make([]byte, 64)) // past the header
	rev := reversed(relay[8:56])
	return in, ctr(rev[:32], rev[32:])
}

// answer makes the reply to the packets inside plain: one packet for each.
func answer(plain []byte) []byte {
	var out []byte
	for len(plain) >= 4 {
		n := int(binary.LittleEndian.Uint32(plain) & 0x7fffffff)
		if len(plain) < 4+n {
			break
		}
		payload := append([]byte("echo:"), plain[4:4+n]...)
		out = binary.LittleEndian.AppendUint32(out, uint32(len(payload)))
		out = append(out, payload...)
		plain = plain[4+n:]
	}
	return out
}

func serverFrame(payload []byte) []byte {
	f := []byte{0x82}
	switch n := len(payload); {
	case n < 126:
		f = append(f, byte(n))
	case n < 65536:
		f = append(f, 126, byte(n>>8), byte(n))
	default:
		f = append(f, 127)
		f = binary.BigEndian.AppendUint64(f, uint64(n))
	}
	return append(f, payload...)
}

var testCert = func() tls.Certificate {
	srv := httptest.NewUnstartedServer(http.NotFoundHandler())
	srv.StartTLS()
	defer srv.Close()
	return srv.TLS.Certificates[0]
}()

// gateway is a pretend kws gateway: TLS (with a certificate nobody trusts), the WebSocket upgrade, then the pretend Telegram.
func (p *pretendTelegram) gateway(t *testing.T) string {
	l, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{testCert}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				br := bufio.NewReader(c)
				req, err := http.ReadRequest(br)
				if err != nil || !strings.Contains(req.Header.Get("Upgrade"), "websocket") {
					return
				}
				io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
				w := &wsConn{conn: c, reader: br}
				var in, out cipher.Stream
				for {
					opcode, msg, _, err := w.readFrame()
					if err != nil || opcode == 0x8 {
						return
					}
					if in == nil { // the first message is the 64-byte header
						p.mu.Lock()
						p.headers++
						p.mu.Unlock()
						in, out = sessionStreams(msg)
						continue
					}
					plain := xor(in, msg)
					p.record(plain)
					if reply := answer(plain); len(reply) > 0 {
						c.Write(serverFrame(xor(out, reply)))
					}
				}
			}()
		}
	}()
	return l.Addr().String()
}

// tcp is a pretend data center on a plain TCP port.
func (p *pretendTelegram) tcp(t *testing.T) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				header := make([]byte, 64)
				if _, err := io.ReadFull(c, header); err != nil {
					return
				}
				p.mu.Lock()
				p.headers++
				p.mu.Unlock()
				in, out := sessionStreams(header)
				buf := make([]byte, 65536)
				for {
					n, err := c.Read(buf)
					if n > 0 {
						plain := xor(in, buf[:n])
						p.record(plain)
						if reply := answer(plain); len(reply) > 0 {
							c.Write(xor(out, reply))
						}
					}
					if err != nil {
						return
					}
				}
			}()
		}
	}()
	return l.Addr().String()
}

const testSecretHex = "000102030405060708090a0b0c0d0e0f"

func dialTo(target string) func(ctx context.Context, network, address string) (net.Conn, error) {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "tcp", target)
	}
}

func startEngine(t *testing.T, cfg Config) (*Engine, string, []byte) {
	t.Helper()
	e, err := New(testSecretHex, cfg)
	if err != nil {
		t.Fatal(err)
	}
	port, err := e.Start(0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(e.Stop)
	secret, _ := hex.DecodeString(testSecretHex)
	return e, net.JoinHostPort("127.0.0.1", itoa(port)), secret
}

func itoa(p uint16) string { return fmtUint(p) }

func fmtUint(p uint16) string {
	if p == 0 {
		return "0"
	}
	var b []byte
	for p > 0 {
		b = append([]byte{byte('0' + p%10)}, b...)
		p /= 10
	}
	return string(b)
}

func twoPackets(a, b string) []byte {
	var out []byte
	for _, s := range []string{a, b} {
		out = binary.LittleEndian.AppendUint32(out, uint32(len(s)))
		out = append(out, s...)
	}
	return out
}

func TestEndToEndThroughTheWebSocketGateway(t *testing.T) {
	tg := &pretendTelegram{}
	cfg := DefaultConfig()
	cfg.WebSocketAddress = map[int]string{2: "gateway"}
	cfg.Dial = dialTo(tg.gateway(t))
	e, addr, secret := startEngine(t, cfg)

	client, err := DialClient(addr, secret, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	// Two packets in one write must reach Telegram as two WebSocket messages.
	if err := client.SendRaw(twoPackets("hello", "world!")); err != nil {
		t.Fatal(err)
	}
	var got []string
	for i := 0; i < 2; i++ {
		p, err := client.ReadPacket(5 * time.Second)
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, string(p))
	}
	if got[0] != "echo:hello" || got[1] != "echo:world!" {
		t.Fatalf("answers: %q", got)
	}
	seen := tg.seen()
	if len(seen) != 2 || len(seen[0]) != 4+5 || len(seen[1]) != 4+6 {
		t.Fatalf("Telegram saw %d messages: %q", len(seen), seen)
	}
	st := e.Stats()
	if st.WebSocket != 1 || st.DirectTCP != 0 || st.BytesUp == 0 || st.BytesDown == 0 || st.WrongSecret != 0 {
		t.Fatalf("stats %+v", st)
	}
}

func TestMediaGoesToTheMediaGatewayName(t *testing.T) {
	if got := webSocketDomains(4, true); len(got) != 2 || got[0] != "kws4-1.web.telegram.org" || got[1] != "kws4.web.telegram.org" {
		t.Fatal(got)
	}
	if got := webSocketDomains(203, false); len(got) != 1 || got[0] != "kws2.web.telegram.org" {
		t.Fatal(got)
	}
}

func TestFallsBackToDirectTCP(t *testing.T) {
	tg := &pretendTelegram{}
	cfg := DefaultConfig()
	cfg.WebSocketAddress = map[int]string{} // no gateway for this data center
	cfg.DataCenterAddress = map[int]string{2: "dc2"}
	cfg.Dial = dialTo(tg.tcp(t))
	e, addr, secret := startEngine(t, cfg)

	client, err := DialClient(addr, secret, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.SendPacket([]byte("ping"))
	p, err := client.ReadPacket(5 * time.Second)
	if err != nil || !bytes.HasPrefix(p, []byte("echo:ping")) {
		t.Fatalf("answer %q err %v", p, err)
	}
	if st := e.Stats(); st.DirectTCP != 1 || st.WebSocket != 0 {
		t.Fatalf("stats %+v", st)
	}
}

func TestAnotherSecretIsCountedAndClosed(t *testing.T) {
	cfg := DefaultConfig()
	e, addr, _ := startEngine(t, cfg)
	other := bytes.Repeat([]byte{9}, 16)
	client, err := DialClient(addr, other, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if _, err := client.ReadPacket(3 * time.Second); err == nil {
		t.Fatal("the proxy must close a connection with a wrong key")
	}
	if st := e.Stats(); st.WrongSecret != 1 {
		t.Fatalf("stats %+v", st)
	}
}

func TestAnUnknownDataCenterIsAFailureNotAHang(t *testing.T) {
	cfg := DefaultConfig()
	cfg.WebSocketAddress = map[int]string{}
	e, addr, secret := startEngine(t, cfg)
	client, _ := DialClient(addr, secret, 9)
	defer client.Close()
	if _, err := client.ReadPacket(3 * time.Second); err == nil {
		t.Fatal("expected the connection to be closed")
	}
	if st := e.Stats(); st.Failures != 1 {
		t.Fatalf("stats %+v", st)
	}
}

func TestTheNextFreePortIsTaken(t *testing.T) {
	busy, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	taken := uint16(busy.Addr().(*net.TCPAddr).Port)
	e, _ := New(testSecretHex, DefaultConfig())
	port, err := e.Start(taken)
	if err != nil {
		t.Fatal(err)
	}
	defer e.Stop()
	if port == taken || port < taken || port >= taken+20 {
		t.Fatalf("asked for %d, got %d", taken, port)
	}
}

func TestStopClosesThePortAndTheClients(t *testing.T) {
	cfg := DefaultConfig()
	e, addr, secret := startEngine(t, cfg)
	client, _ := DialClient(addr, secret, 9)
	defer client.Close()
	if !e.IsListening() {
		t.Fatal("should listen")
	}
	e.Stop()
	if e.IsListening() || e.Port() != 0 {
		t.Fatal("should not listen after Stop")
	}
	if c, err := net.DialTimeout("tcp", addr, time.Second); err == nil {
		c.Close()
		t.Fatal("the port must be closed")
	}
}

func TestBadSecretTextIsRefused(t *testing.T) {
	for _, s := range []string{"", "zz", "00", strings.Repeat("0", 31), strings.Repeat("g", 32)} {
		if _, err := New(s, DefaultConfig()); err == nil {
			t.Errorf("%q should be refused", s)
		}
	}
}
