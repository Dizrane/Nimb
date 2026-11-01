package report

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"sync"
)

// The signature of a report (the port of Sources/Nimb/Report/ReportSigner.swift; the relay, report-relay/index.js, builds the same line): the
// program signs each report with HMAC-SHA256 over "nimb1|id|version|platform|installation|sha256(text)", in hex, with the key of its own version.
// That key is made from the master key (which never leaves the release maker and the relay) as HMAC-SHA256(master, "nimb-key|windows|" + version)
// in hex letters; a key taken out of one release signs that version only. A build from the sources has no key: it sends nothing.

// ErrNoKey is what a build that is not an official one answers when asked to send.
var ErrNoKey = errors.New("Приложение изменено или собрано не из официального выпуска, поэтому тестирование приостановлено. Разработчик не отвечает за изменённые сборки.")

var (
	keyMu sync.Mutex
	key   []byte
)

// SetKey gives the package the key of this version (nil: not an official build). Called once, at the start.
func SetKey(k []byte) { keyMu.Lock(); key = k; keyMu.Unlock() }

func currentKey() []byte { keyMu.Lock(); defer keyMu.Unlock(); return key }

// Message is the line that is signed; the two sides build the same one.
func Message(id, app, platform, install, text string) string {
	hash := sha256.Sum256([]byte(text))
	return strings.Join([]string{"nimb1", id, app, platform, install, hex.EncodeToString(hash[:])}, "|")
}

// Signature is the HMAC-SHA256 of the message, in hex.
func Signature(message string, key []byte) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(message))
	return hex.EncodeToString(mac.Sum(nil))
}

// VersionKey is the key of one version of Windows made from the master key, in hex letters (the bytes of these letters are the key of the HMAC,
// as the relay takes them). The Mac has its own label (nimb-key|version), so a key of one platform signs nothing of the other.
func VersionKey(master, version string) string {
	return Signature("nimb-key|windows|"+version, []byte(master))
}

// Mix is the key as the build puts it into the program: each byte with the byte of the version, round and round, in hex. In the program it is
// no line of text that a search of the file would show. That is no lock against a person who sets out to take it from a release (nothing in a
// program a person owns is); the lock is the relay's, which turns the key off when it is taken.
func Mix(key []byte, version string) string {
	return hex.EncodeToString(xor(key, version))
}

// Unmix is the reverse of Mix; nil when there is nothing (a build from the sources) or it is not hex.
func Unmix(mixed, version string) []byte {
	raw, err := hex.DecodeString(strings.TrimSpace(mixed))
	if err != nil || len(raw) == 0 {
		return nil
	}
	return xor(raw, version)
}

func xor(in []byte, version string) []byte {
	pad := []byte(version)
	if len(pad) == 0 {
		return nil
	}
	out := make([]byte, len(in))
	for i, b := range in {
		out[i] = b ^ pad[i%len(pad)]
	}
	return out
}
