package tgproxy

import (
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"io"
	"net"
	"time"
)

// Client speaks to a proxy the way Telegram Desktop does. The service does not need it; the tests and the self-test of the
// proxy (cmd/tgproxy) do, to try the proxy without a Telegram app.
type Client struct {
	conn net.Conn
	enc  cipher.Stream
	dec  cipher.Stream
}

// DialClient connects to the proxy and sends the 64-byte header for a data center (negative: media), with the padded
// intermediate transport.
func DialClient(address string, secret []byte, dcIndex int) (*Client, error) {
	conn, err := net.DialTimeout("tcp", address, 5*time.Second)
	if err != nil {
		return nil, err
	}
	header := randomHeader()
	prekeyAndIV := header[skip : skip+prekey+ivLength]
	key := keyFrom(prekeyAndIV[:prekey], secret)
	putTail(header, key, prekeyAndIV[prekey:], tagSecure, dcIndex)

	enc := ctr(key, prekeyAndIV[prekey:])
	enc.XORKeyStream(make([]byte, handshakeLength), make([]byte, handshakeLength))
	rev := reversed(prekeyAndIV)
	dec := ctr(keyFrom(rev[:prekey], secret), rev[prekey:])
	if _, err := conn.Write(header); err != nil {
		conn.Close()
		return nil, err
	}
	return &Client{conn: conn, enc: enc, dec: dec}, nil
}

// SendPacket sends one packet of the padded intermediate transport: its length, the payload, and up to three bytes of padding.
func (c *Client) SendPacket(payload []byte) error {
	var pad [1]byte
	rand.Read(pad[:])
	padding := int(pad[0] % 4)
	packet := binary.LittleEndian.AppendUint32(nil, uint32(len(payload)+padding))
	packet = append(packet, payload...)
	packet = append(packet, make([]byte, padding)...)
	return c.SendRaw(packet)
}

// SendRaw sends bytes as they are (encrypted for the proxy).
func (c *Client) SendRaw(data []byte) error {
	_, err := c.conn.Write(xor(c.enc, data))
	return err
}

// ReadPacket reads one packet of the padded intermediate transport and returns its payload (with the padding, if any).
func (c *Client) ReadPacket(timeout time.Duration) ([]byte, error) {
	c.conn.SetReadDeadline(time.Now().Add(timeout))
	var head [4]byte
	if _, err := io.ReadFull(c.conn, head[:]); err != nil {
		return nil, err
	}
	length := binary.LittleEndian.Uint32(xor(c.dec, head[:])) & 0x7fffffff
	if length > 1<<24 {
		return nil, io.ErrUnexpectedEOF
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(c.conn, body); err != nil {
		return nil, err
	}
	return xor(c.dec, body), nil
}

// Close closes the connection.
func (c *Client) Close() { c.conn.Close() }
