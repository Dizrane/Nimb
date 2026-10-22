// Package session tells whether the last run of the window ended unexpectedly. The window leaves a mark while it runs (a file with the
// version that made it) and removes it when it ends by itself; a mark that is still there at the next start means the run was cut off.
// Not every cut-off is a crash: the installer stops the old window before it puts the new one in its place, and that must not be
// reported as «закончился неожиданно».
package session

import "strings"

// Interpret reads the mark that the last run left. endedBadly is true for a run that nobody ended on purpose: the mark of the same
// version (a crash, a forced close, a power cut) or the old mark "running" that was written before the version was put into it.
// upgradedFrom is the version of the mark when it is another one: the installer of this version replaced that one.
func Interpret(mark, version string) (endedBadly bool, upgradedFrom string) {
	mark = strings.TrimSpace(mark)
	if mark == "" || mark == "running" || mark == version {
		return true, ""
	}
	return false, mark
}
