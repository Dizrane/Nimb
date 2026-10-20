//go:build windows

package main

import (
	_ "embed"
	"time"

	"fyne.io/systray"
)

//go:embed build/windows/tray-idle.ico
var trayIdle []byte

//go:embed build/windows/tray-active.ico
var trayActive []byte

var trayItems struct {
	all, ai, tg, media *systray.MenuItem
}

func startTray(a *App) {
	go systray.Run(func() { onTrayReady(a) }, func() {})
}

func stopTray() { systray.Quit() }

func onTrayReady(a *App) {
	systray.SetIcon(trayIdle)
	systray.SetTitle("Nimb")
	systray.SetTooltip("Nimb")
	systray.SetOnTapped(a.ShowWindow)
	trayItems.all = systray.AddMenuItem("Включить всё", "")
	systray.AddSeparator()
	trayItems.ai = systray.AddMenuItemCheckbox("Нейросети", "", false)
	trayItems.tg = systray.AddMenuItemCheckbox("Telegram", "", false)
	trayItems.media = systray.AddMenuItemCheckbox("YouTube и Discord", "", false)
	systray.AddSeparator()
	open := systray.AddMenuItem("Открыть Nimb", "")
	quit := systray.AddMenuItem("Выйти", "")

	go func() {
		for {
			select {
			case <-trayItems.all.ClickedCh:
				st := a.GetState()
				a.SetAll(!(st.AI.On && st.Telegram.On && st.Media.On))
			case <-trayItems.ai.ClickedCh:
				a.SetAI(!trayItems.ai.Checked())
			case <-trayItems.tg.ClickedCh:
				a.SetTelegram(!trayItems.tg.Checked())
			case <-trayItems.media.ClickedCh:
				a.SetMedia(!trayItems.media.Checked())
			case <-open.ClickedCh:
				a.ShowWindow()
			case <-quit.ClickedCh:
				a.Quit()
				return
			}
		}
	}()
	go refreshTray(a)
}

// refreshTray keeps the menu and the icon in step with the services.
func refreshTray(a *App) {
	for {
		st := a.GetState()
		check := func(item *systray.MenuItem, on bool) {
			if on {
				item.Check()
			} else {
				item.Uncheck()
			}
		}
		check(trayItems.ai, st.AI.On)
		check(trayItems.tg, st.Telegram.On)
		check(trayItems.media, st.Media.On)
		all := st.AI.On && st.Telegram.On && st.Media.On
		if all {
			trayItems.all.SetTitle("Выключить всё")
		} else {
			trayItems.all.SetTitle("Включить всё")
		}
		if st.AI.On || st.Telegram.On || st.Media.On {
			systray.SetIcon(trayActive)
		} else {
			systray.SetIcon(trayIdle)
		}
		sleepSeconds(3)
	}
}

func sleepSeconds(n int) { time.Sleep(time.Duration(n) * time.Second) }
