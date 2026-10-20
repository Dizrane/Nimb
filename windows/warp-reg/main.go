// warp-reg makes the personal part of the Nimb tunnel the way the macOS app does it (Sources/Nimb/Warp/WarpRegistration.swift):
// it registers an anonymous Cloudflare WARP account with a fresh key and writes the settings of the tunnel, the shared camouflage
// of the preset plus this account's key and address, as an AmneziaWG .conf file. Stage 0 of the Windows version: the file is
// opened in the official AmneziaWG client to see whether the tunnel works on Windows. Nothing about the person is sent: a new
// public key and the time of the registration.
//
//	warp-reg -out nimb-warp.conf     register and write the settings
//	warp-reg -delete nimb-warp.conf  delete the account that the file was made for
package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

//go:embed warp-preset.conf
var preset string

const (
	apiVersion   = "v0a2223"
	endpointPort = 500
)

// Two names of the same service: some networks let one of them through and not the other.
var hosts = []string{"zero-trust-client.cloudflareclient.com", "api.cloudflareclient.com"}

var idPattern = regexp.MustCompile(`^[0-9A-Za-z-]{8,64}$`)

type account struct {
	ID, Token string
	Config    string
}

func main() {
	out := flag.String("out", "nimb-warp.conf", "file for the settings of the tunnel")
	del := flag.String("delete", "", "settings file whose account is to be deleted")
	flag.Parse()

	if *del != "" {
		if err := deleteFor(*del); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	acc, err := register()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	// The account id and token travel in comments of the file: the client ignores them, and `-delete` reads them.
	text := acc.Config + fmt.Sprintf("\n# nimb-account-id=%s\n# nimb-account-token=%s\n", acc.ID, acc.Token)
	if err := os.WriteFile(*out, []byte(text), 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	fmt.Printf("written %s (account %s). Open it in the AmneziaWG client; delete the account with: warp-reg -delete %s\n", *out, acc.ID, *out)
}

func register() (*account, error) {
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	body := map[string]any{
		"key":        base64.StdEncoding.EncodeToString(key.PublicKey().Bytes()),
		"install_id": "", "fcm_token": "",
		"tos":  time.Now().UTC().Format(time.RFC3339),
		"type": "Android", "model": "PC", "locale": "en_US",
	}
	problem := "no answer"
	for _, host := range hosts {
		status, data, err := send("POST", host, "/"+apiVersion+"/reg", "", body)
		if err != nil {
			problem = err.Error()
			continue
		}
		if status != 200 {
			problem = fmt.Sprintf("answer %d", status)
			continue
		}
		return accountFrom(data, base64.StdEncoding.EncodeToString(key.Bytes()), preset)
	}
	return nil, fmt.Errorf("could not get keys from Cloudflare (%s)", problem)
}

// reply is the part of the answer of Cloudflare that is used.
type reply struct {
	ID     string `json:"id"`
	Token  string `json:"token"`
	Config struct {
		Interface struct {
			Addresses struct {
				V4 string `json:"v4"`
				V6 string `json:"v6"`
			} `json:"addresses"`
		} `json:"interface"`
		Peers []struct {
			PublicKey string `json:"public_key"`
			Endpoint  struct {
				V4 string `json:"v4"`
			} `json:"endpoint"`
		} `json:"peers"`
	} `json:"config"`
}

// accountFrom builds the settings file from the answer of Cloudflare, the private key (base64) and the shared preset.
func accountFrom(data []byte, privateKey, preset string) (*account, error) {
	var r reply
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, errors.New("Cloudflare answered with something unexpected")
	}
	if !idPattern.MatchString(r.ID) || !idPattern.MatchString(r.Token) || len(r.Config.Peers) == 0 {
		return nil, errors.New("Cloudflare answered with something unexpected")
	}
	peer := r.Config.Peers[0]
	ip, _, ok := strings.Cut(peer.Endpoint.V4, ":")
	if !ok || peer.PublicKey == "" || ip == "" {
		return nil, errors.New("Cloudflare answered with something unexpected")
	}
	var addresses []string
	if r.Config.Interface.Addresses.V4 != "" {
		addresses = append(addresses, r.Config.Interface.Addresses.V4+"/32")
	}
	if r.Config.Interface.Addresses.V6 != "" {
		addresses = append(addresses, r.Config.Interface.Addresses.V6+"/128")
	}
	parts := strings.Split(preset, "[Peer]")
	if len(parts) != 2 {
		return nil, errors.New("the preset of the tunnel is damaged")
	}
	text := "[Interface]\nPrivateKey = " + privateKey + "\nAddress = " + strings.Join(addresses, ", ") + "\n" +
		strings.Replace(parts[0], "[Interface]", "", 1) +
		"\n[Peer]\nPublicKey = " + peer.PublicKey + "\nEndpoint = " + ip + fmt.Sprintf(":%d\n", endpointPort) + parts[1]
	return &account{ID: r.ID, Token: r.Token, Config: text}, nil
}

func deleteFor(file string) error {
	raw, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	var id, token string
	for _, line := range strings.Split(string(raw), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "# nimb-account-id="); ok {
			id = v
		}
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "# nimb-account-token="); ok {
			token = v
		}
	}
	if !idPattern.MatchString(id) || !idPattern.MatchString(token) {
		return errors.New("the file has no account to delete")
	}
	for _, host := range hosts {
		status, _, err := send("DELETE", host, "/"+apiVersion+"/reg/"+id, token, nil)
		if err == nil && ((status >= 200 && status < 300) || status == 404) {
			fmt.Println("account deleted")
			return nil
		}
	}
	return errors.New("could not delete the account (Cloudflare did not answer); it expires by itself")
}

func send(method, host, path, token string, payload any) (int, []byte, error) {
	var body io.Reader
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return 0, nil, err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, "https://"+host+path, body)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "okhttp/3.12.1")
	req.Header.Set("CF-Client-Version", "1.1.1.1/6.81")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	return resp.StatusCode, data, err
}
