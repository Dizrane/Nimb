//go:build windows

// Nimb for Windows: the window. The interface is plain HTML, CSS and JavaScript (frontend/dist), drawn by the WebView2 of the
// system; everything it does goes through the methods of App. The service (cmd/nimb-svc) does what needs administrator rights.
package main

import (
	"context"
	"embed"
	"os"
	"path/filepath"
	"runtime/debug"
	"slices"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/logger"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	defer func() {
		if v := recover(); v != nil {
			logPanic("главный поток", v, debug.Stack())
			os.Exit(2)
		}
	}()
	afterWebView2Crash = waitForPreviousProcess()
	useOwnTaskbarIcon()
	app := NewApp()
	err := wails.Run(&options.App{
		Title: "Nimb",
		// The size of the window with a frame; sizeWindow makes it exactly right for a client area of 1100 by 660 as soon as it is up.
		Width:             1116,
		Height:            699,
		MinWidth:          1116,
		MinHeight:         699,
		BackgroundColour:  &options.RGBA{R: 0, G: 0, B: 0, A: 255},
		AssetServer:       &assetserver.Options{Assets: assets},
		OnStartup:         app.startup,
		OnBeforeClose:     app.beforeClose,
		HideWindowOnClose: true,
		StartHidden:       slices.Contains(os.Args[1:], "--hidden"),
		OnShutdown: func(context.Context) {
			logExit("приложение закрывается (Wails вызвал OnShutdown)")
			endSession()
		},
		Logger:             wailsLog{},
		LogLevel:           logger.WARNING,
		LogLevelProduction: logger.WARNING,
		Bind:               []any{app},
		SingleInstanceLock: &options.SingleInstanceLock{
			UniqueId:               "com.nimb.windows",
			OnSecondInstanceLaunch: app.secondInstance,
		},
		Windows: &windows.Options{
			Theme: windows.Dark,
			CustomTheme: &windows.ThemeSettings{
				DarkModeTitleBar:          windows.RGB(0, 0, 0),
				DarkModeTitleBarInactive:  windows.RGB(0, 0, 0),
				DarkModeTitleText:         windows.RGB(0, 0, 0), // as the bar: the text stays for the taskbar and Alt+Tab, but is not seen (the Mac has none)
				DarkModeTitleTextInactive: windows.RGB(0, 0, 0),
				DarkModeBorder:            windows.RGB(28, 28, 30),
				DarkModeBorderInactive:    windows.RGB(28, 28, 30),
			},
			// The cache of WebView2 goes inside the folder that the uninstaller removes (by default it is %APPDATA%\Nimb.exe).
			WebviewUserDataPath:  filepath.Join(dataDir(), "WebView2"),
			WebviewIsTransparent: false,
			DisableWindowIcon:    false,
		},
	})
	if err != nil {
		logLine("выход: Wails вернул ошибку: " + err.Error())
		println("error:", err.Error())
		return
	}
	logExit("Wails закончил работу без ошибки")
}
