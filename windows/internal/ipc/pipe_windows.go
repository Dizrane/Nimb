//go:build windows

package ipc

import (
	"net"
	"time"

	"github.com/Microsoft/go-winio"
)

// PipeName is where the service listens.
const PipeName = `\\.\pipe\nimb-helper`

// The pipe is open to the system, the administrators and the people who sit at this computer (interactive logon), and to nobody
// else. Remote clients are refused by the pipe itself (go-winio creates it with FILE_PIPE_REJECT_REMOTE_CLIENTS).
const pipeSecurity = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)"

// Listen opens the pipe of the service.
func Listen() (net.Listener, error) {
	return winio.ListenPipe(PipeName, &winio.PipeConfig{
		SecurityDescriptor: pipeSecurity,
		InputBufferSize:    MaxLine,
		OutputBufferSize:   65536,
	})
}

// Dial connects to the service.
func Dial(timeout time.Duration) (net.Conn, error) {
	return winio.DialPipe(PipeName, &timeout)
}
