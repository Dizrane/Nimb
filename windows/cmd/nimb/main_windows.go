//go:build windows

// Nimb for Windows: the window. The interface is plain HTML, CSS and JavaScript (frontend/dist), drawn by the WebView2 of the
// system; everything it does goes through the methods of App. The service (cmd/nimb-svc) does what needs administrator rights.
package main

import (
	"embed"

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
		Width:             940,
		Height:            620,
		MinWidth:          800,
		MinHeight:         520,
		BackgroundColour:  &options.RGBA{R: 0, G: 0, B: 0, A: 255},
		AssetServer:       &assetserver.Options{Assets: assets},
		OnStartup:         app.startup,
		OnBeforeClose:     app.beforeClose,
		HideWindowOnClose: true,
		Bind:              []any{app},
		SingleInstanceLock: &options.SingleInstanceLock{
			UniqueId:               "com.nimb.windows",
			OnSecondInstanceLaunch: app.secondInstance,
		},
		Windows: &windows.Options{
			Theme:                windows.Dark,
			WebviewIsTransparent: false,
			DisableWindowIcon:    false,
		},
	})
	if err != nil {
		println("error:", err.Error())
	}
}
