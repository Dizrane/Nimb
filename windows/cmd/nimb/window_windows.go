//go:build windows

package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"

	"github.com/wailsapp/wails/v2/pkg/runtime"
	"golang.org/x/sys/windows"
)

// The window is as the Mac one (WindowConfigurator.contentSize in Sources/Nimb/Theme.swift): what the page sees, the client area
// without the frame and the title bar, is fixed at 1100 by 660. Wails takes the size of the whole
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

const (
	wmEndSession = 0x0016
	wmSysCommand = 0x0112
	scClose      = 0xF060
)

// windowProc is the procedure that the window had before watchWindowMessages put its own in front of it.
var windowProc atomic.Uintptr
var windowApp atomic.Pointer[App]

// Go keeps at most 2000 callbacks made by syscall.NewCallback per program and never frees one, so a callback must be made once, not on
// every call: the tray asks for the window every 3 seconds, and a new callback each time killed the window (and the icon at the clock)
// after about 100 minutes. internal/callbackguard fails the tests when a callback is made anywhere but once.
var ownWindowSearch struct {
	sync.Mutex
	pid   uint32
	found uintptr
}

var enumOwnWindow = sync.OnceValue(func() uintptr {
	return syscall.NewCallback(func(hwnd, _ uintptr) uintptr {
		var owner uint32
		pWindowThread.Call(hwnd, uintptr(unsafe.Pointer(&owner)))
		if owner != ownWindowSearch.pid {
			return 1
		}
		name := make([]uint16, 64)
		n, _, _ := pGetClassName.Call(hwnd, uintptr(unsafe.Pointer(&name[0])), uintptr(len(name)))
		if windows.UTF16ToString(name[:n]) == "wailsWindow" {
			ownWindowSearch.found = hwnd
			return 0
		}
		return 1
	})
})

// ownWindow finds the window of this program that Wails made.
func ownWindow() uintptr {
	ownWindowSearch.Lock()
	defer ownWindowSearch.Unlock()
	ownWindowSearch.pid, ownWindowSearch.found = uint32(os.Getpid()), 0
	pEnumWindows.Call(enumOwnWindow(), 0)
	return ownWindowSearch.found
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

// sizeWindow fixes the client area at 1100 by 660, accounting for the current frame and screen DPI.
func (a *App) sizeWindow() {
	hwnd := ownWindow()
	if hwnd == 0 {
		logLine("размер окна: окно не найдено, размер остаётся таким, какой задан в программе")
		return
	}
	w, h := outerSize(hwnd)
	runtime.WindowSetMinSize(a.ctx, w, h)
	runtime.WindowSetMaxSize(a.ctx, w, h)
	runtime.WindowSetSize(a.ctx, w, h)
	logLine("размер окна: чтобы рабочая область была 1100×660, он вместе с рамкой " + strconv.Itoa(w) + "×" + strconv.Itoa(h))
}

// watchWindowMessages distinguishes the window close command (the cross, Alt+F4) from a direct WM_CLOSE sent by Windows, and records
// the end of a Windows session. Only the former may hide the window; a system termination always reaches Wails.
func (a *App) watchWindowMessages() {
	hwnd := ownWindow()
	if hwnd == 0 {
		return
	}
	previous, _, _ := pGetWindowLong.Call(hwnd, ^uintptr(3)) // GWLP_WNDPROC (-4)
	if previous == 0 {
		logLine("закрытие окна: исходная оконная процедура не найдена")
		return
	}
	// Publish the original procedure before installing the callback: the UI thread can receive a message immediately.
	windowProc.Store(previous)
	windowApp.Store(a)
	if installed, _, err := pSetWindowLong.Call(hwnd, ^uintptr(3), windowMessageProc()); installed == 0 {
		logLine("закрытие окна: не удалось установить обработчик: " + err.Error())
	}
}

var windowMessageProc = sync.OnceValue(func() uintptr {
	return syscall.NewCallback(func(h, msg, wparam, lparam uintptr) uintptr {
		if msg == wmSysCommand && wparam&0xFFF0 == scClose {
			if a := windowApp.Load(); a != nil {
				if a.settings.get().Enabled() {
					runtime.WindowHide(a.ctx)
				} else {
					goSafe("закрытие окна", func() { a.quitFrom("закрытие окна при выключенной работе в фоне") })
				}
				return 0
			}
		}
		if msg == wmEndSession && wparam != 0 {
			endSession()
			logExit("Windows завершает сеанс (выключение, перезагрузка или выход из учётной записи)")
		}
		r, _, _ := pCallWindowProc.Call(windowProc.Load(), h, msg, wparam, lparam)
		return r
	})
})

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
