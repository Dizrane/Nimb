//go:build windows

package dnsx

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/windows"
)

func recoveryPath() (string, error) {
	system, err := windows.GetSystemDirectory()
	return filepath.Join(system, "drivers", "etc", "hosts"), err
}

func readRecoveryHosts(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > 4<<20 {
		return nil, errors.New("не удалось безопасно прочитать hosts")
	}
	return os.ReadFile(path)
}

func HasLegacyGeoHideHosts() bool {
	path, err := recoveryPath()
	if err != nil {
		return false
	}
	data, err := readRecoveryHosts(path)
	return err == nil && hasLegacyHosts(data)
}

var replaceHostsFile = windows.NewLazySystemDLL("kernel32.dll").NewProc("ReplaceFileW")

// RemoveLegacyGeoHideHosts preserves the system file's ACL with ReplaceFileW.
func RemoveLegacyGeoHideHosts() error {
	path, err := recoveryPath()
	if err != nil {
		return err
	}
	return removeLegacyHosts(path, Flush)
}

func removeLegacyHosts(path string, flush func()) error {
	before, err := readRecoveryHosts(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	after, err := stripLegacyHosts(before)
	if err != nil || bytes.Equal(before, after) {
		return err
	}

	tmp, err := os.CreateTemp(filepath.Dir(path), ".nimb-hosts-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, writeErr := tmp.Write(after)
	closeErr := tmp.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		return err
	}
	if current, err := readRecoveryHosts(path); err != nil || !bytes.Equal(current, before) {
		return errors.New("файл hosts изменился во время записи")
	}
	dest, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	source, err := windows.UTF16PtrFromString(tmp.Name())
	if err != nil {
		return err
	}
	ok, _, winErr := replaceHostsFile.Call(uintptr(unsafe.Pointer(dest)), uintptr(unsafe.Pointer(source)), 0, 0, 0, 0)
	if ok == 0 {
		return fmt.Errorf("не удалось заменить hosts: %w", winErr)
	}
	flush()
	if current, err := readRecoveryHosts(path); err != nil || !bytes.Equal(current, after) {
		return errors.New("не удалось подтвердить запись hosts")
	}
	return nil
}
