// Package browserdns finds browsers that ask a DNS of their own, over HTTPS, and so never ask the one Nimb has set. Firefox does it
// by default in Russia and Ukraine since 2022 (https://support.mozilla.org/kb/firefox-dns-over-https). It is the port of
// Sources/Nimb/BrowserDNS.swift.
package browserdns

import (
	"regexp"
	"strconv"
)

// FirefoxText is what the person is told.
const FirefoxText = "Firefox мог включить «DNS через HTTPS» (в России он включён по умолчанию): тогда браузер спрашивает адреса у Cloudflare и обходит Nimb. Выключите его: «Настройки» → «Приватность и защита» → «DNS через HTTPS»."

var reMode = regexp.MustCompile(`user_pref\(\s*"network\.trr\.mode"\s*,\s*(\d+)\s*\)`)

// SwitchedOff reads the preferences of a profile (as text): `user_pref("network.trr.mode", 5);` is "off" chosen by hand, 0 is "never
// on". Any other number (2, 3) means the browser asks Cloudflare. The last line about it wins, as in Firefox.
func SwitchedOff(preferences string) bool {
	all := reMode.FindAllStringSubmatch(preferences, -1)
	if len(all) == 0 {
		return false
	}
	mode, err := strconv.Atoi(all[len(all)-1][1])
	return err == nil && (mode == 5 || mode == 0)
}

// FirefoxWarning is the line for the person, or "" when there is nothing to say: no Firefox, a Firefox that never started, or one
// that has DNS over HTTPS switched off in every profile. profiles are the preference files of each profile, as text.
func FirefoxWarning(installed bool, profiles []string) string {
	if !installed || len(profiles) == 0 {
		return ""
	}
	for _, p := range profiles {
		if !SwitchedOff(p) {
			return FirefoxText
		}
	}
	return ""
}
