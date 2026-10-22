//go:build windows

package main

import (
	_ "embed"
	"encoding/binary"
	"fmt"
	"unsafe"

	"fyne.io/systray"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// The icons are made by tools/icons/main.go. The tray shows the ring of the Mac menu bar: dashed and dim while nothing is on, solid while
// one or two services are on, thicker while all three are. The «light» ones are for the dark taskbar, the «dark» ones for the light one.
//
//go:embed build/windows/tray-none-light.ico
var trayNoneLight []byte

//go:embed build/windows/tray-some-light.ico
var traySomeLight []byte

//go:embed build/windows/tray-all-light.ico
var trayAllLight []byte

//go:embed build/windows/tray-none-dark.ico
var trayNoneDark []byte

//go:embed build/windows/tray-some-dark.ico
var traySomeDark []byte

//go:embed build/windows/tray-all-dark.ico
var trayAllDark []byte

// The window (the title, the taskbar, Alt+Tab) has the two icons of the Mac Dock: the active one while the AI services are on.
//
//go:embed build/windows/window-idle.ico
var windowIdle []byte

//go:embed build/windows/window-active.ico
var windowActive []byte

var (
	pSendMessage       = user32.NewProc("SendMessageW")
	pCreateIconFromRes = user32.NewProc("CreateIconFromResourceEx")
	pMetricsForDpi     = user32.NewProc("GetSystemMetricsForDpi")
	pSetAppID          = shell32.NewProc("SetCurrentProcessExplicitAppUserModelID")
)

const (
	wmSetIcon   = 0x0080
	iconSmall   = 0
	iconBig     = 1
	smCxIcon    = 11
	smCxSmIcon  = 49
	iconVersion = 0x00030000
)

// useOwnTaskbarIcon gives the process an identity of its own. Without one the taskbar takes the icon of the button from the shortcut of
// the Start menu that points to the .exe, and never from the window, so the icon of the state would not show there.
func useOwnTaskbarIcon() {
	id, _ := windows.UTF16PtrFromString("Nimb.Windows")
	pSetAppID.Call(uintptr(unsafe.Pointer(id)))
}

// trayIcon is the icon for the number of services that are on (0 to 3), for the theme of the taskbar.
func trayIcon(on int, lightTaskbar bool) []byte {
	icons := [][]byte{trayNoneLight, traySomeLight, trayAllLight}
	if lightTaskbar {
		icons = [][]byte{trayNoneDark, traySomeDark, trayAllDark}
	}
	switch on {
	case 0:
		return icons[0]
	case 3:
		return icons[2]
	}
	return icons[1]
}

// lightTaskbar tells whether the taskbar (and the tray) uses the light theme; the setting is not the one of the apps.
func lightTaskbar() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	v, _, err := k.GetIntegerValue("SystemUsesLightTheme")
	return err == nil && v == 1
}

var shownTray struct {
	on     int
	light  bool
	chosen bool
}

// setTrayIcon changes the icon of the tray only when it is another one.
func setTrayIcon(on int) {
	light := lightTaskbar()
	if shownTray.chosen && shownTray.on == on && shownTray.light == light {
		return
	}
	shownTray.on, shownTray.light, shownTray.chosen = on, light, true
	systray.SetIcon(trayIcon(on, light))
}

var shownWindow struct {
	hwnd   uintptr
	active bool
	chosen bool
}

// setWindowIcon gives the window the icon of the state; the icons of the system (the .exe in Explorer) stay the normal one.
func setWindowIcon(active bool) {
	hwnd := ownWindow()
	if hwnd == 0 {
		return
	}
	if shownWindow.chosen && shownWindow.hwnd == hwnd && shownWindow.active == active {
		return
	}
	data := windowIdle
	if active {
		data = windowActive
	}
	dpi, _, _ := pGetDpiForWindow.Call(hwnd)
	if dpi == 0 {
		dpi = 96
	}
	for _, kind := range []struct{ metric, which uintptr }{{smCxSmIcon, iconSmall}, {smCxIcon, iconBig}} {
		size, _, _ := pMetricsForDpi.Call(kind.metric, dpi)
		icon := iconOfSize(data, int(size))
		if icon == 0 {
			logLine(fmt.Sprintf("значок окна: нет значка размером %d", size))
			continue
		}
		pSendMessage.Call(hwnd, wmSetIcon, kind.which, icon)
	}
	shownWindow.hwnd, shownWindow.active, shownWindow.chosen = hwnd, active, true
}

// iconOfSize makes an icon of the picture in an .ico file that is the nearest in size (the smallest that is not smaller than wanted).
func iconOfSize(ico []byte, wanted int) uintptr {
	if len(ico) < 6 {
		return 0
	}
	count := int(binary.LittleEndian.Uint16(ico[4:]))
	best, bestSize := -1, 0
	for i := 0; i < count && 22+16*i <= len(ico); i++ {
		entry := ico[6+16*i:]
		size := int(entry[0])
		if size == 0 {
			size = 256
		}
		if best < 0 || (bestSize < wanted && size > bestSize) || (size >= wanted && size < bestSize) {
			best, bestSize = i, size
		}
	}
	if best < 0 {
		return 0
	}
	entry := ico[6+16*best:]
	length := binary.LittleEndian.Uint32(entry[8:])
	offset := binary.LittleEndian.Uint32(entry[12:])
	if uint64(offset)+uint64(length) > uint64(len(ico)) {
		return 0
	}
	// A picture in an icon file is a PNG; the system makes an icon of the size asked from it.
	icon, _, _ := pCreateIconFromRes.Call(uintptr(unsafe.Pointer(&ico[offset])), uintptr(length), 1, iconVersion, uintptr(wanted), uintptr(wanted), 0)
	return icon
}
