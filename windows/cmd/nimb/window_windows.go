//go:build windows

package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"syscall"
	"unsafe"

	"github.com/wailsapp/wails/v2/pkg/runtime"
	"golang.org/x/sys/windows"
)

// The window is as the Mac one (WindowConfigurator.minimumSize in Sources/Nimb/Theme.swift): what the page sees, the client area
// without the frame and the title bar, is at least 1100 by 660 and is exactly that the first time. Wails takes the size of the whole
// window (frame and title bar included), so the size of the frame is asked of the system for this window and this screen.
const (
	clientWidth  = 1100
	clientHeight = 660
)

var (
	pAdjustRectForDpi = user32.NewProc("AdjustWindowRectExForDpi")
	pGetDpiForWindow  = user32.NewProc("GetDpiForWindow")
	pEnumWindows      = user32.NewProc("EnumWindows")
	pGetClassName     = user32.NewProc("GetClassNameW")
	pGetWindowLong    = user32.NewProc("GetWindowLongPtrW")
	pSetWindowLong    = user32.NewProc("SetWindowLongPtrW")
	pCallWindowProc   = user32.NewProc("CallWindowProcW")
	pGetClientRect    = user32.NewProc("GetClientRect")
)

const wmEndSession = 0x0016

// windowProc is the procedure that the window had before watchSessionEnd put its own in front of it.
var windowProc uintptr

// ownWindow finds the window of this program that Wails made.
func ownWindow() uintptr {
	var found uintptr
	pid := uint32(os.Getpid())
	cb := syscall.NewCallback(func(hwnd, _ uintptr) uintptr {
		var owner uint32
		pWindowThread.Call(hwnd, uintptr(unsafe.Pointer(&owner)))
		if owner != pid {
			return 1
		}
		name := make([]uint16, 64)
		n, _, _ := pGetClassName.Call(hwnd, uintptr(unsafe.Pointer(&name[0])), uintptr(len(name)))
		if windows.UTF16ToString(name[:n]) == "wailsWindow" {
			found = hwnd
			return 0
		}
		return 1
	})
	pEnumWindows.Call(cb, 0)
	return found
}

// outerSize is the size of a window (in the units of Wails: device independent pixels) whose client area is clientWidth by
// clientHeight on this screen.
func outerSize(hwnd uintptr) (w, h int) {
	dpi, _, _ := pGetDpiForWindow.Call(hwnd)
	if dpi == 0 {
		dpi = 96
	}
	scale := float64(dpi) / 96
	rect := windows.Rect{Right: int32(math.Round(clientWidth * scale)), Bottom: int32(math.Round(clientHeight * scale))}
	style, _, _ := pGetWindowLong.Call(hwnd, uintptr(^uintptr(15)))   // GWL_STYLE (-16)
	exStyle, _, _ := pGetWindowLong.Call(hwnd, uintptr(^uintptr(19))) // GWL_EXSTYLE (-20)
	pAdjustRectForDpi.Call(uintptr(unsafe.Pointer(&rect)), style, 0, exStyle, dpi)
	return int(math.Ceil(float64(rect.Right-rect.Left) / scale)), int(math.Ceil(float64(rect.Bottom-rect.Top) / scale))
}

// sizeWindow makes the client area at least 1100 by 660, and exactly that the first time with this window design (after that the
// size the person left it with is kept).
func (a *App) sizeWindow() {
	hwnd := ownWindow()
	if hwnd == 0 {
		logLine("размер окна: окно не найдено, размер остаётся таким, какой задан в программе")
		return
	}
	w, h := outerSize(hwnd)
	runtime.WindowSetMinSize(a.ctx, w, h)
	if !a.settings.get().WindowSized {
		runtime.WindowSetSize(a.ctx, w, h)
		a.settings.update(func(s *Settings) { s.WindowSized = true })
	}
	logLine("размер окна: чтобы рабочая область была 1100×660, он вместе с рамкой " + strconv.Itoa(w) + "×" + strconv.Itoa(h))
}

// watchSessionEnd: when Windows shuts down or the person logs off, the program is ended without being asked to close, and the mark of a
// running program (see beginSession) would stay and be taken for a crash at the next start. Wails does not hand this message on, so a
// procedure of ours stands in front of the window's: it removes the mark when the session ends, and passes every message on.
func (a *App) watchSessionEnd() {
	hwnd := ownWindow()
	if hwnd == 0 {
		return
	}
	cb := syscall.NewCallback(func(h, msg, wparam, lparam uintptr) uintptr {
		if msg == wmEndSession && wparam != 0 {
			endSession()
			logExit("Windows завершает сеанс (выключение, перезагрузка или выход из учётной записи)")
		}
		r, _, _ := pCallWindowProc.Call(windowProc, h, msg, wparam, lparam)
		return r
	})
	windowProc, _, _ = pSetWindowLong.Call(hwnd, ^uintptr(3), cb) // GWLP_WNDPROC (-4)
}

// windowFacts says, for a report, how large the page is and how the screen is scaled: a window that is too small or a scale of 150% is
// the first thing to look at when a page looks wrong.
func windowFacts() string {
	hwnd := ownWindow()
	if hwnd == 0 {
		return "Окно: не найдено"
	}
	dpi, _, _ := pGetDpiForWindow.Call(hwnd)
	if dpi == 0 {
		dpi = 96
	}
	var rc windows.Rect
	pGetClientRect.Call(hwnd, uintptr(unsafe.Pointer(&rc)))
	scale := float64(dpi) / 96
	return fmt.Sprintf("Окно: рабочая область %d×%d, масштаб экрана %d%%", int(math.Round(float64(rc.Right-rc.Left)/scale)), int(math.Round(float64(rc.Bottom-rc.Top)/scale)), int(dpi)*100/96)
}
