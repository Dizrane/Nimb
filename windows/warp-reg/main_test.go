package main

import (
	"os"
	"strings"
	"testing"
)

const goodReply = `{"id":"1234abcd-5678","token":"tok-0123456789","config":{"interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:8a36::2"}},"peers":[{"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=","endpoint":{"v4":"162.159.192.1:0"}}]}}`

func TestPresetIsTheOneOfTheMacApp(t *testing.T) {
	mac, err := os.ReadFile("../../Resources/warp-preset.conf")
	if err != nil {
		t.Skip("the repository root is not here")
	}
	if string(mac) != preset {
		t.Fatal("windows/warp-reg/warp-preset.conf differs from Resources/warp-preset.conf: copy it again")
	}
}

func TestSettingsFromAReply(t *testing.T) {
	acc, err := accountFrom([]byte(goodReply), "PRIVATEKEYBASE64=", preset)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"[Interface]\nPrivateKey = PRIVATEKEYBASE64=\nAddress = 172.16.0.2/32, 2606:4700:110:8a36::2/128",
		"MTU = 1280", "Jc = 120", "[Peer]\nPublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\nEndpoint = 162.159.192.1:500\n",
		"AllowedIPs = 0.0.0.0/0, ::/0",
	} {
		if !strings.Contains(acc.Config, want) {
			t.Errorf("settings lack %q", want)
		}
	}
	if acc.ID != "1234abcd-5678" || acc.Token != "tok-0123456789" {
		t.Errorf("account is %q %q", acc.ID, acc.Token)
	}
	if strings.Count(acc.Config, "[Interface]") != 1 || strings.Count(acc.Config, "[Peer]") != 1 {
		t.Error("each section must be there exactly once")
	}
}

func TestStrangeRepliesAreRefused(t *testing.T) {
	for name, body := range map[string]string{
		"not json":       `<html>`,
		"no peers":       `{"id":"1234abcd-5678","token":"tok-0123456789","config":{"interface":{"addresses":{"v4":"1.1.1.1"}},"peers":[]}}`,
		"id with spaces": `{"id":"12 34 56 78","token":"tok-0123456789","config":{"peers":[{"public_key":"k","endpoint":{"v4":"1.2.3.4:0"}}]}}`,
		"no endpoint":    `{"id":"1234abcd-5678","token":"tok-0123456789","config":{"peers":[{"public_key":"k","endpoint":{"v4":""}}]}}`,
	} {
		if _, err := accountFrom([]byte(body), "KEY=", preset); err == nil {
			t.Errorf("%s: should be refused", name)
		}
	}
}
