// Package awgconf reads the settings of a tunnel in the format of WireGuard and AmneziaWG ([Interface] and [Peer] with
// "Key = Value" lines). It is the port of Sources/Nimb/Warp/WarpConfig.swift: only known keys are taken, every value is
// checked, and nothing in the file is ever executed. Lines that would run commands (PostUp and the like) are left out.
package awgconf

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
)

// Error is a mistake in the settings, worded for the person.
type Error struct{ Message string }

func (e *Error) Error() string { return e.Message }

func fail(format string, args ...any) error { return &Error{fmt.Sprintf(format, args...)} }

// Config is a checked tunnel: one interface and exactly one peer.
type Config struct {
	PrivateKey string // base64, 32 bytes
	Addresses  []netip.Prefix
	MTU        int
	// Device holds the AmneziaWG settings of the interface (Jc, S1, H1, I1 ...) as key and value of the UAPI, in the order of the file.
	Device []KV

	PublicKey           string // base64, 32 bytes
	PresharedKey        string // base64, 32 bytes, may be empty
	Endpoint            string // host:port or [v6]:port
	AllowedIPs          []netip.Prefix
	PersistentKeepalive string
	ProtocolVersion     string

	// Ignored lists what was left out, with the reason, to show to the person.
	Ignored []string
}

// KV is one setting of the interface as the UAPI of the daemon names it.
type KV struct{ Key, Value string }

// IsFullTunnel tells whether all traffic is meant to go into the tunnel.
func (c *Config) IsFullTunnel() bool {
	for _, p := range c.AllowedIPs {
		if p.Bits() == 0 {
			return true
		}
	}
	return false
}

var deviceKeys = map[string]string{
	"jc": "jc", "jmin": "jmin", "jmax": "jmax", "s1": "s1", "s2": "s2", "s3": "s3", "s4": "s4",
	"h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4", "i1": "i1", "i2": "i2", "i3": "i3", "i4": "i4", "i5": "i5",
	"headerprotectionkey": "header_protection_key", "contentpaddingaddition": "content_padding_addition",
	"rekeyaftertime": "rekey_after_time", "rekeytimeout": "rekey_timeout", "rejectaftertime": "reject_after_time",
	"keepalivetimeout": "keepalive_timeout", "maxhandshakeattempts": "max_handshake_attempts",
	"randomtrailers": "random_trailers", "disablecookies": "disable_cookies",
}

// These must be a number or a range, like Jc = 120 or H1 = 100-200.
var numeric = map[string]bool{
	"jc": true, "jmin": true, "jmax": true, "s1": true, "s2": true, "s3": true, "s4": true,
	"h1": true, "h2": true, "h3": true, "h4": true,
}

var (
	numberOrRange = regexp.MustCompile(`^\d{1,10}(-\d{1,10})?$`)
	cidr          = regexp.MustCompile(`^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]{2,39})/[0-9]{1,3}$`)
	endpointRe    = regexp.MustCompile(`^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}$`)
	smallNumber   = regexp.MustCompile(`^\d{1,3}$`)
)

// Parse reads and checks the settings.
func Parse(text string) (*Config, error) {
	c := &Config{MTU: 1280}
	section := ""
	peers := 0
	var seenPrivate, seenPublic, seenEndpoint bool

	for _, raw := range strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' }) {
		line := strings.TrimSpace(raw)
		// A comment after a value; the I1-I5 lines are left alone, their text is free-form.
		if !strings.HasPrefix(strings.ToLower(line), "i") {
			if i := strings.Index(line, " #"); i >= 0 {
				line = strings.TrimSpace(line[:i])
			}
		}
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(line)
			if section == "[peer]" {
				peers++
			}
			if section != "[interface]" && section != "[peer]" {
				return nil, fail("Неизвестный раздел %s.", line)
			}
			continue
		}
		eq := strings.Index(line, "=")
		if eq < 0 {
			return nil, fail("Строка без «=»: %s.", head(line, 40))
		}
		name := strings.TrimSpace(line[:eq])
		key := strings.ToLower(name)
		value := strings.TrimSpace(line[eq+1:])

		switch section {
		case "[interface]":
			if err := c.interfaceLine(name, key, value, &seenPrivate); err != nil {
				return nil, err
			}
		case "[peer]":
			if peers != 1 {
				return nil, fail("Поддерживается один сервер ([Peer]), а в настройках их несколько.")
			}
			if err := c.peerLine(name, key, value, &seenPublic, &seenEndpoint); err != nil {
				return nil, err
			}
		default:
			return nil, fail("Настройка вне раздела: %s.", head(line, 40))
		}
	}
	switch {
	case !seenPrivate:
		return nil, fail("Нет PrivateKey в разделе [Interface].")
	case !seenPublic || !seenEndpoint:
		return nil, fail("В разделе [Peer] нужны PublicKey и Endpoint.")
	case len(c.AllowedIPs) == 0:
		return nil, fail("В разделе [Peer] нет AllowedIPs.")
	case len(c.Addresses) == 0:
		return nil, fail("В разделе [Interface] нет Address.")
	}
	return c, nil
}

func (c *Config) interfaceLine(name, key, value string, seenPrivate *bool) error {
	switch key {
	case "privatekey":
		if err := requireKey(value, "PrivateKey"); err != nil {
			return err
		}
		*seenPrivate = true
		c.PrivateKey = value
	case "address":
		for _, part := range splitList(value) {
			p, err := prefix(part)
			if err != nil {
				return fail("Неверный Address: %s.", part)
			}
			c.Addresses = append(c.Addresses, p)
		}
	case "mtu":
		mtu, err := strconv.Atoi(value)
		if err != nil || mtu < 576 || mtu > 1500 {
			return fail("MTU должен быть от 576 до 1500.")
		}
		c.MTU = mtu
	case "dns":
		c.Ignored = append(c.Ignored, "DNS (DNS туннеля задаёт сама служба)")
	case "listenport", "table", "saveconfig":
		c.Ignored = append(c.Ignored, name)
	case "preup", "postup", "predown", "postdown":
		c.Ignored = append(c.Ignored, name+" (команды не выполняются)")
	default:
		uapi, known := deviceKeys[key]
		if !known {
			c.Ignored = append(c.Ignored, name)
			return nil
		}
		if err := requireValue(value, name); err != nil {
			return err
		}
		if numeric[uapi] && !numberOrRange.MatchString(value) {
			return fail("%s должен быть числом или диапазоном, а не «%s».", name, head(value, 30))
		}
		c.Device = append(c.Device, KV{uapi, value})
	}
	return nil
}

func (c *Config) peerLine(name, key, value string, seenPublic, seenEndpoint *bool) error {
	switch key {
	case "publickey":
		if err := requireKey(value, "PublicKey"); err != nil {
			return err
		}
		*seenPublic = true
		c.PublicKey = value
	case "presharedkey":
		if err := requireKey(value, "PresharedKey"); err != nil {
			return err
		}
		c.PresharedKey = value
	case "endpoint":
		i := strings.LastIndex(value, ":")
		port := 0
		if i >= 0 {
			port, _ = strconv.Atoi(value[i+1:])
		}
		if !endpointRe.MatchString(value) || port < 1 || port > 65535 {
			return fail("Неверный Endpoint: %s.", head(value, 60))
		}
		*seenEndpoint = true
		c.Endpoint = value
	case "allowedips":
		for _, part := range splitList(value) {
			p, err := prefix(part)
			if err != nil {
				return fail("Неверный AllowedIPs: %s.", part)
			}
			c.AllowedIPs = append(c.AllowedIPs, p)
		}
	case "persistentkeepalive":
		if !numberOrRange.MatchString(value) {
			return fail("PersistentKeepalive должен быть числом.")
		}
		c.PersistentKeepalive = value
	case "protocolversion":
		if !smallNumber.MatchString(value) {
			return fail("ProtocolVersion должен быть числом.")
		}
		c.ProtocolVersion = value
	default:
		c.Ignored = append(c.Ignored, name)
	}
	return nil
}

// UAPI is the text for the configuration interface of the daemon ("set=1"): keys in hex, one setting a line.
// Without a keepalive nothing is sent until the first packet of the person, and the wait for the handshake would fail,
// so 25 seconds is added.
func (c *Config) UAPI() (string, error) {
	var b strings.Builder
	priv, err := hexKey(c.PrivateKey)
	if err != nil {
		return "", err
	}
	pub, err := hexKey(c.PublicKey)
	if err != nil {
		return "", err
	}
	fmt.Fprintf(&b, "private_key=%s\n", priv)
	for _, kv := range c.Device {
		fmt.Fprintf(&b, "%s=%s\n", kv.Key, kv.Value)
	}
	fmt.Fprintf(&b, "replace_peers=true\npublic_key=%s\nendpoint=%s\n", pub, c.Endpoint)
	if c.PresharedKey != "" {
		psk, err := hexKey(c.PresharedKey)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", psk)
	}
	keepalive := c.PersistentKeepalive
	if keepalive == "" {
		keepalive = "25"
	}
	fmt.Fprintf(&b, "persistent_keepalive_interval=%s\n", keepalive)
	if c.ProtocolVersion != "" {
		fmt.Fprintf(&b, "protocol_version=%s\n", c.ProtocolVersion)
	}
	b.WriteString("replace_allowed_ips=true\n")
	for _, p := range c.AllowedIPs {
		fmt.Fprintf(&b, "allowed_ip=%s\n", p)
	}
	return b.String(), nil
}

func hexKey(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(raw) != 32 {
		return "", fail("Ключ должен быть ключом WireGuard (44 символа base64).")
	}
	return hex.EncodeToString(raw), nil
}

func requireKey(value, name string) error {
	if _, err := hexKey(value); err != nil {
		return fail("%s должен быть ключом WireGuard (44 символа base64).", name)
	}
	return nil
}

// Values go into one line of the input of the daemon: printable characters only, and not too long.
func requireValue(value, name string) error {
	if value == "" || len(value) > 4096 {
		return fail("Недопустимое значение %s.", name)
	}
	for _, r := range value {
		if r < 0x20 || r >= 0x7f {
			return fail("Недопустимое значение %s.", name)
		}
	}
	return nil
}

func prefix(part string) (netip.Prefix, error) {
	if !cidr.MatchString(part) {
		return netip.Prefix{}, fail("not a CIDR")
	}
	return netip.ParsePrefix(part)
}

func splitList(value string) []string {
	var out []string
	for _, part := range strings.Split(value, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

func head(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
