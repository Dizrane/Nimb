// Package buildcheck says whether this is a build of ours (BuildCheck of the Mac, Sources/Nimb/Report/BuildCheck.swift). What a changed build
// does says nothing about Nimb (a service or a wintun.dll of another build left next to the window, a build from the sources), so such a build
// sends no reports at all, by itself or by hand; the report in the window still shows what it found. The relay turns away what has no
// signature of a release (internal/report/sign.go): this is the first line.
//
// A build is ours when it has the key of its release and the files that it works with (the service, wintun.dll) are the ones that the build
// made: installer/build.sh gives the sums of them to the linker as "nimb-svc.exe=<sha256>;wintun.dll=<sha256>". Windows has no signature of the
// program itself that could be checked from inside (the installer is not signed), so nothing here says a patched Nimb.exe is not ours: the lock for
// that is the relay's, which turns the key off when it is taken.
package buildcheck

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// PausedWords is for the window of a build that sends nothing (the words of the Mac).
const PausedWords = "Приложение изменено или собрано не из официального выпуска, поэтому тестирование приостановлено. Разработчик не отвечает за изменённые сборки."

// PausedShort is the same in a few words, for the line of the switch.
const PausedShort = "Тестирование приостановлено: сборка изменена."

// Problem says why a build is not ours, in words for a report; "" when it is. hasKey: the program has the key of its release; files are the sums
// from the linker; dir is the folder the files stand in (the one of the program).
func Problem(hasKey bool, files, dir string) string {
	if !hasKey {
		return "собрано не из официального выпуска"
	}
	for _, item := range strings.Split(files, ";") {
		name, want, ok := strings.Cut(item, "=")
		if !ok || name == "" || strings.ContainsAny(name, `/\`) {
			continue
		}
		got, err := sumOf(filepath.Join(dir, name))
		switch {
		case os.IsNotExist(err):
			return "нет файла " + name + " рядом с программой"
		case err != nil:
			// A file that cannot be read now (a lock of an antivirus) is not judged.
		case got != strings.ToLower(want):
			return "файл " + name + " не наш: сумма другая"
		}
	}
	return ""
}

// sumOf is the SHA-256 of a file, in hex.
func sumOf(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
