// Package notice holds the rules of the notifications of Nimb that do not depend on the system: the tags that keep the test
// notification and the notification about a new version apart, and what is shown when the window is in front. It is the port of the rules of
// Sources/Nimb/Notifier.swift.
package notice

// The tags. They are different on purpose: the test must not replace the notification about an update, nor the other way round.
const (
	TestTag   = "nimb-test"
	UpdateTag = "nimb-update"
)

// The words of the test notification.
const (
	TestTitle = "Проверка уведомлений"
	TestText  = "Если вы это видите, Nimb сможет сообщить о новой версии."
)

// ShowsInFront tells whether a notification is shown when the window of Nimb is in front: the window already has the button for an
// update, so that one is not; the test is the exception, it is asked for in that very window.
func ShowsInFront(tag string) bool { return tag == TestTag }
