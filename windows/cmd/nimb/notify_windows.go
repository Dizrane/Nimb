//go:build windows

package main

import (
	"os"
	"runtime"
	"sync"
	"syscall"
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
	pForeground   = user32.NewProc("GetForegroundWindow")
	pWindowThread = user32.NewProc("GetWindowThreadProcessId")
	pRegisterCls  = user32.NewProc("RegisterClassExW")
	pDefWindow    = user32.NewProc("DefWindowProcW")
	pGetMessage   = user32.NewProc("GetMessageW")
	pTranslateMsg = user32.NewProc("TranslateMessage")
	pDispatchMsg  = user32.NewProc("DispatchMessageW")
)

// The numbers of the notifications: the icon of each is told apart by its number, and a click on it comes back with the number.
const (
	balloonUpdate uint32 = 1
	balloonTest   uint32 = 2
)

const (
	wmBalloonCallback = 0x8001 // WM_APP + 1: what the icon of a notification sends to the window when it is clicked
	ninBalloonClick   = 0x405  // NIN_BALLOONUSERCLICK
)

// balloonClick is told which notification was clicked; the app sets it before the first notification.
var balloonClick func(id uint32)

type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   uintptr
	Icon       uintptr
	Cursor     uintptr
	Background uintptr
	MenuName   *uint16
	ClassName  *uint16
	IconSmall  uintptr
}

type winMsg struct {
	Wnd     uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      struct{ X, Y int32 }
	Private uint32
}

// balloonProc is the procedure of the one window that all notifications belong to. It is made once: Go never frees a callback.
var balloonProc = sync.OnceValue(func() uintptr {
	return syscall.NewCallback(func(h, msg, wparam, lparam uintptr) uintptr {
		if msg == wmBalloonCallback && uint32(lparam)&0xFFFF == ninBalloonClick {
			if f := balloonClick; f != nil {
				go f(uint32(wparam)) // the loop of the window goes on at once
			}
			return 0
		}
		r, _, _ := pDefWindow.Call(h, msg, wparam, lparam)
		return r
	})
})

// balloonWindow is the one hidden window of the notifications. A window gets its messages only on the thread that made it, so a thread
// of its own is kept for it, with a loop of messages: without the loop a click on a notification would never come to the program.
var balloonWindow = sync.OnceValue(func() uintptr {
	made := make(chan uintptr, 1)
	go func() {
		runtime.LockOSThread()
		name, _ := windows.UTF16PtrFromString("NimbNotifyWindow")
		class := wndClassEx{WndProc: balloonProc(), ClassName: name}
		class.Size = uint32(unsafe.Sizeof(class))
		pRegisterCls.Call(uintptr(unsafe.Pointer(&class)))
		const hwndMessage = ^uintptr(2) // HWND_MESSAGE (-3): a window that is only a name for the icons
		wnd, _, _ := pCreateWindow.Call(0, uintptr(unsafe.Pointer(name)), 0, 0, 0, 0, 0, 0, hwndMessage, 0, 0, 0)
		made <- wnd
		if wnd == 0 {
			return
		}
		var m winMsg
		for {
			if r, _, _ := pGetMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0); int32(r) <= 0 {
				return
			}
			pTranslateMsg.Call(uintptr(unsafe.Pointer(&m)))
			pDispatchMsg.Call(uintptr(unsafe.Pointer(&m)))
		}
	}()
	return <-made
})

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
}

// remove takes a balloon away from the screen.
func (b *liveBalloon) remove() {
	pNotifyIcon.Call(2, uintptr(unsafe.Pointer(b.data)))
}

// balloon shows a message near the clock, as the notification of Windows. The icon of the tray is drawn by a library that has no
// notifications, so the message comes from a small icon of its own (the icon of Nimb), which is there for a few seconds and then goes.
// The tag and the number keep the notifications apart: the test does not replace the update, nor the update the test. A click on the
// notification is passed to balloonClick with its number.
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
	wnd := balloonWindow()
	if wnd == 0 {
		return
	}
	data := &notifyIconData{Wnd: wnd, ID: id, Flags: 0x1 | 0x2 | 0x4 | 0x10, CallbackMessage: wmBalloonCallback, Icon: icon, InfoFlags: 1}
	data.Size = uint32(unsafe.Sizeof(*data))
	copyUTF16(data.Tip[:], "Nimb")
	copyUTF16(data.Info[:], text)
	copyUTF16(data.InfoTitle[:], title)
	if r, _, _ := pNotifyIcon.Call(0, uintptr(unsafe.Pointer(data))); r == 0 {
		return
	}
	mine := &liveBalloon{data: data}
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
