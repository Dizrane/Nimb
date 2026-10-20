// Package tgproxy is a local MTProto proxy for Telegram Desktop, ported from Sources/Nimb/TelegramProxy (which is itself a port
// of TG WS Proxy by Flowseal, MIT: https://github.com/Flowseal/tg-ws-proxy). The client talks to 127.0.0.1; this side opens the
// same session to Telegram's WebSocket gateway (kws<N>.web.telegram.org), which networks slow down far less than plain MTProto,
// and falls back to a direct TCP connection to the data center.
package tgproxy

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"slices"
)

const (
	handshakeLength = 64
	skip            = 8
	prekey          = 32
	ivLength        = 16
	protoTagPos     = 56
	dcIndexPos      = 60
)

var (
	tagAbridged     = [4]byte{0xef, 0xef, 0xef, 0xef}
	tagIntermediate = [4]byte{0xee, 0xee, 0xee, 0xee}
	tagSecure       = [4]byte{0xdd, 0xdd, 0xdd, 0xdd}
)

// Transport is how the client cuts its messages.
type Transport int

const (
	Abridged Transport = iota
	Intermediate
	PaddedIntermediate
)

// Handshake is what the 64-byte header of a client says.
type Handshake struct {
	DC        int
	IsMedia   bool
	IsTestDC  bool
	Tag       [4]byte
	Transport Transport
	// clientPrekeyAndIV is the 48 bytes after the first 8: key and IV of the client's side.
	clientPrekeyAndIV []byte
}

func ctr(key, iv []byte) cipher.Stream {
	block, err := aes.NewCipher(key)
	if err != nil {
		panic(err) // the key is always 32 bytes
	}
	return cipher.NewCTR(block, iv)
}

func keyFrom(prekeyPart, secret []byte) []byte {
	h := sha256.New()
	h.Write(prekeyPart)
	h.Write(secret)
	return h.Sum(nil)
}

// xor runs the stream over data and returns the result (a copy).
func xor(s cipher.Stream, data []byte) []byte {
	out := make([]byte, len(data))
	s.XORKeyStream(out, data)
	return out
}

// ParseHandshake reads the 64-byte obfuscated2 header the client sends first. It returns nil if the secret or the protocol is wrong.
func ParseHandshake(header, secret []byte) *Handshake {
	if len(header) != handshakeLength {
		return nil
	}
	prekeyAndIV := slices.Clone(header[skip : skip+prekey+ivLength])
	decrypted := xor(ctr(keyFrom(prekeyAndIV[:prekey], secret), prekeyAndIV[prekey:]), header)

	var tag [4]byte
	copy(tag[:], decrypted[protoTagPos:protoTagPos+4])
	var transport Transport
	switch tag {
	case tagAbridged:
		transport = Abridged
	case tagIntermediate:
		transport = Intermediate
	case tagSecure:
		transport = PaddedIntermediate
	default:
		return nil
	}
	index := int16(binary.LittleEndian.Uint16(decrypted[dcIndexPos:]))
	dc := int(index)
	if dc < 0 {
		dc = -dc
	}
	isTest := dc >= 10000
	if isTest {
		dc -= 10000
	}
	return &Handshake{DC: dc, IsMedia: index < 0, IsTestDC: isTest, Tag: tag, Transport: transport, clientPrekeyAndIV: prekeyAndIV}
}

// forbiddenStarts are the first four bytes that a header must not begin with: they would look like another protocol (HTTP, TLS).
var forbiddenStarts = [][4]byte{
	{0x48, 0x45, 0x41, 0x44}, {0x50, 0x4f, 0x53, 0x54}, {0x47, 0x45, 0x54, 0x20},
	tagIntermediate, tagSecure, {0x16, 0x03, 0x01, 0x02}, {0x4f, 0x50, 0x54, 0x49},
}

// randomHeader is 64 random bytes that do not look like another protocol.
func randomHeader() []byte {
	header := make([]byte, handshakeLength)
	for {
		rand.Read(header)
		if header[0] == 0xef {
			continue
		}
		var start [4]byte
		copy(start[:], header[:4])
		if slices.Contains(forbiddenStarts, start) {
			continue
		}
		if header[4] == 0 && header[5] == 0 && header[6] == 0 && header[7] == 0 {
			continue
		}
		return header
	}
}

// putTail writes the protocol tag and the data center into the encrypted tail of a header, so that whoever has the key of the
// header reads them and nobody else sees anything but noise. keystreamKey and iv are the key and IV that encrypt the header.
func putTail(header []byte, keystreamKey, iv []byte, tag [4]byte, dcIndex int) {
	keystream := xor(ctr(keystreamKey, iv), make([]byte, handshakeLength))
	var random [2]byte
	rand.Read(random[:])
	tail := []byte{tag[0], tag[1], tag[2], tag[3], 0, 0, random[0], random[1]}
	binary.LittleEndian.PutUint16(tail[4:], uint16(int16(dcIndex)))
	for i := 0; i < 8; i++ {
		header[protoTagPos+i] = tail[i] ^ keystream[protoTagPos+i]
	}
}

// MakeRelayInit is the 64-byte header this proxy sends to Telegram: random, with the protocol tag and the DC in its encrypted tail.
func MakeRelayInit(tag [4]byte, dcIndex int) []byte {
	header := randomHeader()
	putTail(header, header[skip:skip+prekey], header[skip+prekey:skip+prekey+ivLength], tag, dcIndex)
	return header
}

// Ciphers carry a session: the client side (with the secret) and the Telegram side (plain keys).
type Ciphers struct {
	FromClient   cipher.Stream
	ToClient     cipher.Stream
	ToTelegram   cipher.Stream
	FromTelegram cipher.Stream
}

func reversed(b []byte) []byte {
	r := slices.Clone(b)
	slices.Reverse(r)
	return r
}

// MakeCiphers builds the four streams of a session. The two that continue a header are advanced past it.
func MakeCiphers(h *Handshake, secret, relayInit []byte) *Ciphers {
	zero := make([]byte, handshakeLength)
	fromClient := ctr(keyFrom(h.clientPrekeyAndIV[:prekey], secret), h.clientPrekeyAndIV[prekey:])
	fromClient.XORKeyStream(make([]byte, handshakeLength), zero)

	rev := reversed(h.clientPrekeyAndIV)
	toClient := ctr(keyFrom(rev[:prekey], secret), rev[prekey:])

	relay := relayInit[skip : skip+prekey+ivLength]
	toTelegram := ctr(relay[:prekey], relay[prekey:])
	toTelegram.XORKeyStream(make([]byte, handshakeLength), zero)
	relayRev := reversed(relay)
	fromTelegram := ctr(relayRev[:prekey], relayRev[prekey:])
	return &Ciphers{FromClient: fromClient, ToClient: toClient, ToTelegram: toTelegram, FromTelegram: fromTelegram}
}

// Splitter cuts the stream into MTProto transport packets, so that each goes to Telegram in a WebSocket frame of its own.
type Splitter struct {
	transport Transport
	cipherBuf []byte
	plainBuf  []byte
	disabled  bool
}

// NewSplitter starts a splitter for a transport.
func NewSplitter(t Transport) *Splitter { return &Splitter{transport: t} }

// Split takes the next bytes (encrypted for Telegram, and the same bytes in the clear) and returns the whole packets.
func (s *Splitter) Split(cipherBytes, plain []byte) [][]byte {
	if len(cipherBytes) == 0 {
		return nil
	}
	if s.disabled {
		return [][]byte{cipherBytes}
	}
	s.cipherBuf = append(s.cipherBuf, cipherBytes...)
	s.plainBuf = append(s.plainBuf, plain...)

	var parts [][]byte
	offset := 0
	for offset < len(s.cipherBuf) {
		length, ok := s.nextLength(offset, len(s.cipherBuf)-offset)
		if !ok {
			break
		}
		if length <= 0 {
			parts = append(parts, slices.Clone(s.cipherBuf[offset:]))
			offset = len(s.cipherBuf)
			s.disabled = true
			break
		}
		parts = append(parts, slices.Clone(s.cipherBuf[offset:offset+length]))
		offset += length
	}
	if offset > 0 {
		s.cipherBuf = s.cipherBuf[offset:]
		s.plainBuf = s.plainBuf[offset:]
	}
	return parts
}

// Flush returns what is left (an unfinished packet) when the client has gone.
func (s *Splitter) Flush() []byte {
	if len(s.cipherBuf) == 0 {
		return nil
	}
	rest := slices.Clone(s.cipherBuf)
	s.cipherBuf, s.plainBuf = nil, nil
	return rest
}

// nextLength: ok false means that more bytes are needed; a length of 0 or less means the framing is not known and the splitting stops.
func (s *Splitter) nextLength(offset, available int) (int, bool) {
	if available <= 0 {
		return 0, false
	}
	p := s.plainBuf
	switch s.transport {
	case Abridged:
		first := p[offset]
		var header, payload int
		if first == 0x7f || first == 0xff {
			if available < 4 {
				return 0, false
			}
			payload = (int(p[offset+1]) | int(p[offset+2])<<8 | int(p[offset+3])<<16) * 4
			header = 4
		} else {
			payload = int(first&0x7f) * 4
			header = 1
		}
		if payload <= 0 {
			return 0, true
		}
		if available >= header+payload {
			return header + payload, true
		}
		return 0, false
	default:
		if available < 4 {
			return 0, false
		}
		raw := binary.LittleEndian.Uint32(p[offset:])
		payload := int(raw & 0x7fff_ffff)
		if payload <= 0 {
			return 0, true
		}
		if available >= 4+payload {
			return 4 + payload, true
		}
		return 0, false
	}
}
