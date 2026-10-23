package tgproxy

import "runtime/debug"

// OnPanic is told when a goroutine of the proxy panicked and was stopped: where, what, and the stack. A panic in one connection (a client
// that sent something the proxy did not expect) must end that connection and nothing else; the program must not die of it, and the word of
// what happened must reach a log. The program sets it; without it the panic is only swallowed.
var OnPanic func(where string, value any, stack []byte)

// recoverPanic is deferred first thing in a goroutine of the proxy.
func recoverPanic(where string) {
	if v := recover(); v != nil && OnPanic != nil {
		OnPanic(where, v, debug.Stack())
	}
}
