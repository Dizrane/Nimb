//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows/registry"

	"github.com/Dizrane/Nimb/windows/internal/session"
)

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

// The command that starts Nimb with Windows: the exe of this copy, quietly (to the tray, no window).
func autostartCommand() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return `"` + exe + `" --hidden`
}

// autostartOn says whether Nimb is in the list of programs that start with Windows (and points at this exe).
func autostartOn() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	v, _, err := k.GetStringValue("Nimb")
	return err == nil && strings.EqualFold(v, autostartCommand())
}

func setAutostart(on bool) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if !on {
		if err := k.DeleteValue("Nimb"); err != nil && err != registry.ErrNotExist {
			return err
		}
		return nil
	}
	return k.SetStringValue("Nimb", autostartCommand())
}

// A file that exists while Nimb runs and holds the version that made it: if it is there at the start, the last run did not end by
// itself (a crash, a power cut). A run that ended because the installer put a newer version in its place (the file names another version)
// or because Windows was shutting down (the window removes the file, see watchSessionEnd) is not unexpected.
func sessionMarker() string { return filepath.Join(dataDir(), "session.marker") }

// beginSession reads what the last run left and makes the mark of this one. upgradedFrom is the version that was running when the
// installer stopped it, or empty.
func beginSession(version, lastLogLine string) (previousEndedBadly bool, upgradedFrom string) {
	raw, err := os.ReadFile(sessionMarker())
	os.MkdirAll(dataDir(), 0o700)
	os.WriteFile(sessionMarker(), []byte(version), 0o600)
	if err != nil {
		return false, ""
	}
	return session.Interpret(string(raw), version, lastLogLine)
}

func endSession() { os.Remove(sessionMarker()) }

// restoreSession puts the mark back: a controlled exit was prepared (the update) and did not happen, so the program goes on running and a
// crash from now on must be told as one.
func restoreSession() { os.WriteFile(sessionMarker(), []byte(Version), 0o600) }
