//go:build windows

// Nimb for Windows: the window. The interface is plain HTML, CSS and JavaScript (frontend/dist), drawn by the WebView2 of the
// system; everything it does goes through the methods of App. The service (cmd/nimb-svc) does what needs administrator rights.
package main

import (
	"context"
	"embed"
	"os"
	"path/filepath"
	"slices"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	app := NewApp()
	err := wails.Run(&options.App{
		Title:             "Nimb",
		Width:             1100,
		Height:            680,
		MinWidth:          900,
		MinHeight:         560,
		BackgroundColour:  &options.RGBA{R: 0, G: 0, B: 0, A: 255},
		AssetServer:       &assetserver.Options{Assets: assets},
		OnStartup:         app.startup,
		OnBeforeClose:     app.beforeClose,
		HideWindowOnClose: true,
		StartHidden:       slices.Contains(os.Args[1:], "--hidden"),
		OnShutdown:        func(context.Context) { endSession() },
		Bind:              []any{app},
		SingleInstanceLock: &options.SingleInstanceLock{
			UniqueId:               "com.nimb.windows",
			OnSecondInstanceLaunch: app.secondInstance,
		},
		Windows: &windows.Options{
			Theme: windows.Dark,
			CustomTheme: &windows.ThemeSettings{
				DarkModeTitleBar:          windows.RGB(0, 0, 0),
				DarkModeTitleBarInactive:  windows.RGB(0, 0, 0),
				DarkModeTitleText:         windows.RGB(235, 235, 240),
				DarkModeTitleTextInactive: windows.RGB(120, 120, 128),
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
		println("error:", err.Error())
	}
}
