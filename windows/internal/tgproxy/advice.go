package tgproxy

import "time"

// TunnelAdvice is when the proxy of Telegram tells the person to try the tunnel: some providers let only a part of the servers of Telegram
// through (the rest, where some files and pictures are kept, open only through the tunnel), and some let none through (then not a single
// connection of the proxy gets to Telegram, and it is said at once). The proxy works alone; this is only advice, and it goes away as soon as
// the tunnel is on or the errors stop. It is the port of TelegramTunnelAdvice (TelegramPage.swift).
type TunnelAdvice string

const (
	AdviceNone    TunnelAdvice = ""
	AdviceBlocked TunnelAdvice = "blocked"
	AdvicePartly  TunnelAdvice = "partly"
)

// AdviceQuiet is how long without a new failure before the advice is withdrawn.
const AdviceQuiet = 10 * time.Minute

// AdviceFor: reached is the number of connections that got to Telegram (by the WebSocket or directly) since the proxy was started.
func AdviceFor(failures, reached int, failuresRecently, tunnelIsOff bool) TunnelAdvice {
	if !tunnelIsOff || !failuresRecently {
		return AdviceNone
	}
	if reached == 0 && failures >= 2 {
		return AdviceBlocked
	}
	if failures >= 5 {
		return AdvicePartly
	}
	return AdviceNone
}

// Words are what the person reads.
func (a TunnelAdvice) Words() string {
	switch a {
	case AdviceBlocked:
		return "Ваша сеть не пускает Telegram: прокси до его серверов не достаёт. Туннель «YouTube и Discord» их откроет."
	case AdvicePartly:
		return "Часть файлов Telegram лежит на серверах, до которых ваша сеть не достаёт: прокси сам с этим не справится. Туннель «YouTube и Discord» их откроет."
	}
	return ""
}
