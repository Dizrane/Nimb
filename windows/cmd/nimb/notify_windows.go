//go:build windows

package main

import (
	"os"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	shell32       = windows.NewLazySystemDLL("shell32.dll")
	user32        = windows.NewLazySystemDLL("user32.dll")
	pNotifyIcon   = shell32.NewProc("Shell_NotifyIconW")
	pExtractIcon  = shell32.NewProc("ExtractIconW")
	pCreateWindow = user32.NewProc("CreateWindowExW")
	pDestroyWin   = user32.NewProc("DestroyWindow")
	pForeground   = user32.NewProc("GetForegroundWindow")
	pWindowThread = user32.NewProc("GetWindowThreadProcessId")
)

// notifyIconData is NOTIFYICONDATAW (shellapi.h).
type notifyIconData struct {
	Size            uint32
	Wnd             uintptr
	ID              uint32
	Flags           uint32
	CallbackMessage uint32
	Icon            uintptr
	Tip             [128]uint16
	State           uint32
	StateMask       uint32
	Info            [256]uint16
	Version         uint32
	InfoTitle       [64]uint16
	InfoFlags       uint32
	GUID            windows.GUID
	BalloonIcon     uintptr
}

func copyUTF16(dst []uint16, s string) {
	u, _ := windows.UTF16FromString(s)
	if len(u) > len(dst) {
		u = append(u[:len(dst)-1], 0)
	}
	copy(dst, u)
}

// live is the notifications that are on the screen, by tag: a second one with the same tag replaces the first (the test notification
// is made again at every press and there is one of it, not a row), and each has the moment it was made, so that the timer of the
// first does not take away the second.
var live struct {
	mu   sync.Mutex
	last map[string]*liveBalloon
}

type liveBalloon struct {
	data *notifyIconData
	wnd  uintptr
}

// remove takes a balloon away from the screen.
func (b *liveBalloon) remove() {
	pNotifyIcon.Call(2, uintptr(unsafe.Pointer(b.data)))
	pDestroyWin.Call(b.wnd)
}

// balloon shows a message near the clock, as the notification of Windows. The icon of the tray is drawn by a library that has no
// notifications, so the message comes from a small icon of its own (the icon of Nimb), which is there for a few seconds and then goes.
// The tag and the number keep the notifications apart: the test does not replace the update, nor the update the test.
func balloon(tag string, id uint32, title, text string) {
	live.mu.Lock()
	previous := live.last[tag]
	delete(live.last, tag)
	live.mu.Unlock()
	if previous != nil {
		previous.remove() // the new one replaces it, and the banner is shown again
	}
	exe, err := os.Executable()
	if err != nil {
		return
	}
	path, _ := windows.UTF16PtrFromString(exe)
	icon, _, _ := pExtractIcon.Call(0, uintptr(unsafe.Pointer(path)), 0)
	class, _ := windows.UTF16PtrFromString("STATIC")
	const hwndMessage = ^uintptr(2) // HWND_MESSAGE (-3): a window that is only a name for the icon
	wnd, _, _ := pCreateWindow.Call(0, uintptr(unsafe.Pointer(class)), 0, 0, 0, 0, 0, 0, hwndMessage, 0, 0, 0)
	if wnd == 0 {
		return
	}
	data := &notifyIconData{Wnd: wnd, ID: id, Flags: 0x2 | 0x4 | 0x10, Icon: icon, InfoFlags: 1}
	data.Size = uint32(unsafe.Sizeof(*data))
	copyUTF16(data.Tip[:], "Nimb")
	copyUTF16(data.Info[:], text)
	copyUTF16(data.InfoTitle[:], title)
	if r, _, _ := pNotifyIcon.Call(0, uintptr(unsafe.Pointer(data))); r == 0 {
		pDestroyWin.Call(wnd)
		return
	}
	mine := &liveBalloon{data: data, wnd: wnd}
	live.mu.Lock()
	if live.last == nil {
		live.last = map[string]*liveBalloon{}
	}
	live.last[tag] = mine
	live.mu.Unlock()
	go func() {
		time.Sleep(12 * time.Second)
		live.mu.Lock()
		if live.last[tag] == mine {
			delete(live.last, tag)
			live.mu.Unlock()
			mine.remove()
			return
		}
		live.mu.Unlock()
	}()
}

// windowInFront tells whether a window of this program is the one the person is working in.
func windowInFront() bool {
	h, _, _ := pForeground.Call()
	if h == 0 {
		return false
	}
	var pid uint32
	pWindowThread.Call(h, uintptr(unsafe.Pointer(&pid)))
	return pid == uint32(os.Getpid())
}
