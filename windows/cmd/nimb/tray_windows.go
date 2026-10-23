//go:build windows

package main

import (
	_ "embed"
	"strconv"
	"time"

	"fyne.io/systray"
)

// A provider in the submenu of the neural networks.
type trayProvider struct {
	id, name string
	item     *systray.MenuItem
}

// The menu is built as on the Mac (StatusMenuController.swift): «Нейросети» and «Telegram» each open a small menu of their own (the switch,
// and under it the providers, or «Открыть в Telegram» and «Скопировать ссылку»), so that it is clear what belongs to what.
var trayItems struct {
	all, ai, tg, media     *systray.MenuItem
	update, tgOpen, tgCopy *systray.MenuItem
	aiToggle, tgToggle     *systray.MenuItem
	aiProviders            []trayProvider
}

func startTray(a *App) {
	goSafe("значок у часов", func() { systray.Run(func() { onTrayReady(a) }, func() {}) })
}

func stopTray() { systray.Quit() }

func onTrayReady(a *App) {
	setTrayIcon(0)
	systray.SetTitle("Nimb")
	systray.SetTooltip("Nimb")
	systray.SetOnTapped(a.ShowWindow)
	// Shown only while a newer version exists, is being installed, or did not install (pressing it installs it, or opens the window).
	trayItems.update = systray.AddMenuItem("Обновить", "")
	trayItems.update.Hide()
	trayItems.all = systray.AddMenuItem("Включить всё", "")
	systray.AddSeparator()
	trayItems.ai = systray.AddMenuItemCheckbox("Нейросети", "", false)
	trayItems.aiToggle = trayItems.ai.AddSubMenuItem("Включить", "")
	trayItems.ai.AddSeparator()
	for _, p := range providerList() {
		trayItems.aiProviders = append(trayItems.aiProviders, trayProvider{p.ID, p.Name, trayItems.ai.AddSubMenuItemCheckbox(p.Name, "", false)})
	}
	trayItems.tg = systray.AddMenuItemCheckbox("Telegram", "", false)
	trayItems.tgToggle = trayItems.tg.AddSubMenuItem("Включить прокси", "")
	// Shown while the proxy of Telegram is on.
	trayItems.tgOpen = trayItems.tg.AddSubMenuItem("Открыть в Telegram", "")
	trayItems.tgCopy = trayItems.tg.AddSubMenuItem("Скопировать ссылку", "")
	trayItems.tgOpen.Hide()
	trayItems.tgCopy.Hide()
	trayItems.media = systray.AddMenuItemCheckbox("YouTube и Discord", "", false)
	systray.AddSeparator()
	open := systray.AddMenuItem("Открыть Nimb", "")
	quit := systray.AddMenuItem("Выйти", "")

	for _, p := range trayItems.aiProviders {
		goKeep("выбор провайдера в меню значка", func() {
			for range p.item.ClickedCh {
				a.SetProvider(p.id)
			}
		})
	}
	goKeep("меню значка", func() {
		for {
			select {
			case <-trayItems.all.ClickedCh:
				st := a.GetState()
				a.SetAll(!(st.AI.On && st.Telegram.On && st.Media.On))
			case <-trayItems.aiToggle.ClickedCh:
				a.SetAI(!a.GetState().AI.On)
			case <-trayItems.tgToggle.ClickedCh:
				a.SetTelegram(!a.GetState().Telegram.On)
			case <-trayItems.media.ClickedCh:
				a.SetMedia(!trayItems.media.Checked())
			case <-trayItems.tgOpen.ClickedCh:
				a.OpenTelegram()
			case <-trayItems.tgCopy.ClickedCh:
				a.CopyLink()
			case <-trayItems.update.ClickedCh:
				if u := a.upd.view(); u.Error != "" {
					a.ShowWindow()
				} else if u.Available && u.Installing == "" {
					a.InstallUpdate()
				}
			case <-open.ClickedCh:
				a.ShowWindow()
			case <-quit.ClickedCh:
				a.quitFrom("пункт «Выйти» в меню значка у часов")
				return
			}
		}
	})
	goKeep("обновление значка у часов", func() { refreshTray(a) })
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
		refreshServiceMenus(st, check)
		if st.Telegram.On {
			trayItems.tgOpen.Show()
			trayItems.tgCopy.Show()
		} else {
			trayItems.tgOpen.Hide()
			trayItems.tgCopy.Hide()
		}
		refreshUpdateItem(st.Update)
		all := st.AI.On && st.Telegram.On && st.Media.On
		if all {
			trayItems.all.SetTitle("Выключить всё")
		} else {
			trayItems.all.SetTitle("Включить всё")
		}
		setTrayIcon(countOn(st.AI.On, st.Telegram.On, st.Media.On))
		setWindowIcon(st.AI.On)
		sleepSeconds(3)
	}
}

// refreshServiceMenus sets the titles and the switches inside the menus of «Нейросети» and «Telegram», as the Mac does: what is on, or what
// is going on, stands after the name.
func refreshServiceMenus(st State, check func(*systray.MenuItem, bool)) {
	chosen := ""
	for _, p := range trayItems.aiProviders {
		on := p.id == st.AI.Provider
		check(p.item, on)
		if on {
			chosen = p.name
		}
		if st.AI.Busy {
			p.item.Disable()
		} else {
			p.item.Enable()
		}
	}
	switch {
	case st.AI.Busy:
		trayItems.ai.SetTitle("Нейросети · переключаю…")
	case st.AI.On && chosen != "":
		trayItems.ai.SetTitle("Нейросети · " + chosen)
	default:
		trayItems.ai.SetTitle("Нейросети")
	}
	if st.AI.On {
		trayItems.aiToggle.SetTitle("Выключить")
	} else if chosen != "" {
		trayItems.aiToggle.SetTitle("Включить (" + chosen + ")")
	} else {
		trayItems.aiToggle.SetTitle("Включить")
	}
	if st.AI.Busy {
		trayItems.aiToggle.Disable()
	} else {
		trayItems.aiToggle.Enable()
	}

	switch {
	case st.Telegram.Busy:
		trayItems.tg.SetTitle("Telegram · запускаю…")
	case st.Telegram.On:
		trayItems.tg.SetTitle("Telegram · 127.0.0.1:" + strconv.Itoa(st.Telegram.Port))
	default:
		trayItems.tg.SetTitle("Telegram")
	}
	if st.Telegram.On {
		trayItems.tgToggle.SetTitle("Остановить прокси")
	} else {
		trayItems.tgToggle.SetTitle("Включить прокси")
	}
	if st.Telegram.Busy {
		trayItems.tgToggle.Disable()
	} else {
		trayItems.tgToggle.Enable()
	}
}

func countOn(services ...bool) int {
	n := 0
	for _, on := range services {
		if on {
			n++
		}
	}
	return n
}

func sleepSeconds(n int) { time.Sleep(time.Duration(n) * time.Second) }

// refreshUpdateItem is the item of the update at the top of the menu: «Обновить до X» while there is a newer version, the step while
// it is being installed (not to be pressed), and «Не удалось обновить, открыть Nimb» when it did not work (opens the window).
func refreshUpdateItem(u UpdateView) {
	item := trayItems.update
	switch {
	case u.Installing != "":
		item.SetTitle("Обновление: " + u.Installing)
		item.Disable()
		item.Show()
	case u.Error != "":
		item.SetTitle("Не удалось обновить, открыть Nimb")
		item.Enable()
		item.Show()
	case u.Available:
		item.SetTitle("Обновить до " + u.Version)
		item.Enable()
		item.Show()
	default:
		item.Hide()
	}
}
