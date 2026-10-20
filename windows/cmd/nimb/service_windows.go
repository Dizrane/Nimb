//go:build windows

package main

import (
	"errors"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/ipc"
)

var errNoService = errors.New("Служба Nimb не запущена. Переустановите Nimb или запустите службу «Nimb: помощник».")

// callService sends one command to the service of Nimb.
func callService(req ipc.Request) (ipc.Response, error) {
	conn, err := ipc.Dial(3 * time.Second)
	if err != nil {
		return ipc.Response{}, errNoService
	}
	resp, err := ipc.Call(conn, req)
	if err != nil {
		return ipc.Response{}, err
	}
	if !resp.OK && resp.Error != "" {
		return resp, errors.New(resp.Error)
	}
	return resp, nil
}
