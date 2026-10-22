package sitecheck

import "os"

func readMac() (string, error) {
	raw, err := os.ReadFile("../../../Sources/Nimb/SiteChecker.swift")
	return string(raw), err
}
