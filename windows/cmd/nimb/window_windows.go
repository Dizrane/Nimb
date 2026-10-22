//go:build windows

package main

import (
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
)

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
		logLine("window: not found, the size is the one of the options")
		return
	}
	w, h := outerSize(hwnd)
	runtime.WindowSetMinSize(a.ctx, w, h)
	if !a.settings.get().WindowSized {
		runtime.WindowSetSize(a.ctx, w, h)
		a.settings.update(func(s *Settings) { s.WindowSized = true })
	}
	logLine("window: outer size for a client of 1100x660 is " + strconv.Itoa(w) + "x" + strconv.Itoa(h))
}
