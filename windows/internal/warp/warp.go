// Package warp makes the personal part of the Nimb tunnel the way the macOS app does it (Sources/Nimb/Warp/WarpRegistration.swift):
// it registers an anonymous Cloudflare WARP account with a fresh key and builds the settings of the tunnel, the shared
// camouflage of the preset plus this account's key and address. Nothing about the person is sent: a new public key and the
// time of the registration.
package warp

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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

// Account is an anonymous account at Cloudflare and the settings of the tunnel made for it.
type Account struct {
	ID     string `json:"id"`
	Token  string `json:"token"`
	Config string `json:"config"` // text of the settings, with the private key in it
}

// Register makes a new account.
func Register(ctx context.Context) (*Account, error) {
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
		status, data, err := send(ctx, "POST", host, "/"+apiVersion+"/reg", "", body)
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
	return nil, fmt.Errorf("не удалось получить ключи у Cloudflare (%s)", problem)
}

// Unregister deletes the account at Cloudflare. An account that is already gone counts as deleted.
func Unregister(ctx context.Context, id, token string) error {
	if !idPattern.MatchString(id) || !idPattern.MatchString(token) {
		return errors.New("у аккаунта нет правильных данных для удаления")
	}
	for _, host := range hosts {
		status, _, err := send(ctx, "DELETE", host, "/"+apiVersion+"/reg/"+id, token, nil)
		if err == nil && ((status >= 200 && status < 300) || status == 404) {
			return nil
		}
	}
	return errors.New("не удалось удалить аккаунт: Cloudflare не ответил")
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

var errUnexpected = errors.New("Cloudflare ответил что-то непонятное")

// accountFrom builds the settings from the answer of Cloudflare, the private key (base64) and the shared preset.
func accountFrom(data []byte, privateKey, preset string) (*Account, error) {
	var r reply
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, errUnexpected
	}
	if !idPattern.MatchString(r.ID) || !idPattern.MatchString(r.Token) || len(r.Config.Peers) == 0 {
		return nil, errUnexpected
	}
	peer := r.Config.Peers[0]
	ip, _, ok := strings.Cut(peer.Endpoint.V4, ":")
	if !ok || peer.PublicKey == "" || ip == "" {
		return nil, errUnexpected
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
		return nil, errors.New("заготовка туннеля повреждена")
	}
	text := "[Interface]\nPrivateKey = " + privateKey + "\nAddress = " + strings.Join(addresses, ", ") + "\n" +
		strings.Replace(parts[0], "[Interface]", "", 1) +
		"\n[Peer]\nPublicKey = " + peer.PublicKey + "\nEndpoint = " + ip + fmt.Sprintf(":%d\n", endpointPort) + parts[1]
	return &Account{ID: r.ID, Token: r.Token, Config: text}, nil
}

func send(ctx context.Context, method, host, path, token string, payload any) (int, []byte, error) {
	var body io.Reader
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return 0, nil, err
		}
		body = bytes.NewReader(b)
	}
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, "https://"+host+path, body)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "okhttp/3.12.1")
	req.Header.Set("CF-Client-Version", "1.1.1.1/6.81")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, data, err
}
