//go:build windows

package browserdns

import (
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows/registry"
)

// Current is what this computer says: Firefox installed, and the preferences of its profiles.
func Current() string {
	if !firefoxInstalled() {
		return ""
	}
	return FirefoxWarning(true, firefoxProfiles())
}

func firefoxInstalled() bool {
	for _, k := range []struct {
		root registry.Key
		path string
	}{
		{registry.LOCAL_MACHINE, `SOFTWARE\Mozilla\Mozilla Firefox`},
		{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox`},
		{registry.CURRENT_USER, `SOFTWARE\Mozilla\Mozilla Firefox`},
		{registry.LOCAL_MACHINE, `SOFTWARE\Mozilla\Firefox Developer Edition`},
		{registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe`},
		{registry.CURRENT_USER, `SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe`},
	} {
		if key, err := registry.OpenKey(k.root, k.path, registry.QUERY_VALUE); err == nil {
			key.Close()
			return true
		}
	}
	for _, dir := range []string{os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)")} {
		if dir == "" {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, "Mozilla Firefox", "firefox.exe")); err == nil {
			return true
		}
	}
	return false
}

// firefoxProfiles are the preference files (prefs.js and user.js) of each profile, as text. A folder that cannot be read counts as
// a profile with nothing set: better a hint too many than none.
func firefoxProfiles() []string {
	folder := filepath.Join(os.Getenv("APPDATA"), "Mozilla", "Firefox", "Profiles")
	entries, err := os.ReadDir(folder)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		var text []string
		for _, name := range []string{"prefs.js", "user.js"} {
			if raw, err := os.ReadFile(filepath.Join(folder, e.Name(), name)); err == nil {
				text = append(text, string(raw))
			}
		}
		out = append(out, strings.Join(text, "\n"))
	}
	if len(out) == 0 {
		return []string{""}
	}
	return out
}
