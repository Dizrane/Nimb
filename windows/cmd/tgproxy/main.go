// tgproxy runs the Telegram proxy of Nimb from a console, for trying it:
//
//	tgproxy [-port 1443] [-secret <32 hex digits>]   run the proxy and print the tg://proxy link
//	tgproxy -selftest                                 start a proxy, ask real Telegram servers for req_pq through it, report
package main

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"time"

	"github.com/Dizrane/Nimb/windows/internal/tgproxy"
)

func main() {
	port := flag.Uint("port", 1443, "port to listen on (the next free one is taken if it is busy)")
	secretHex := flag.String("secret", "", "secret of 32 hex digits (a random one if empty)")
	selftest := flag.Bool("selftest", false, "ask Telegram for req_pq through the proxy")
	flag.Parse()

	if *secretHex == "" {
		b := make([]byte, 16)
		rand.Read(b)
		*secretHex = hex.EncodeToString(b)
	}
	cfg := tgproxy.DefaultConfig()
	cfg.Logf = func(s string) { fmt.Printf("%s  %s\n", time.Now().Format("15:04:05"), s) }
	engine, err := tgproxy.New(*secretHex, cfg)
	if err != nil {
		fatal(err)
	}
	if *selftest {
		os.Exit(selfTest(engine, *secretHex))
	}
	p, err := engine.Start(uint16(*port))
	if err != nil {
		fatal(err)
	}
	fmt.Printf("tg://proxy?server=127.0.0.1&port=%d&secret=dd%s\n", p, *secretHex)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	tick := time.NewTicker(10 * time.Second)
	for {
		select {
		case <-stop:
			engine.Stop()
			return
		case <-tick.C:
			s := engine.Stats()
			fmt.Printf("connections %d (active %d), websocket %d, tcp %d, failures %d, wrong secret %d, up %d, down %d\n",
				s.Total, s.Active, s.WebSocket, s.DirectTCP, s.Failures, s.WrongSecret, s.BytesUp, s.BytesDown)
		}
	}
}

// selfTest is what Telegram Desktop does first with a new connection: an unencrypted req_pq_multi, to which a data center answers
// with resPQ and the same nonce. Done for every data center the proxy knows, through the proxy.
func selfTest(engine *tgproxy.Engine, secretHex string) int {
	port, err := engine.Start(0)
	if err != nil {
		fatal(err)
	}
	defer engine.Stop()
	secret, _ := hex.DecodeString(secretHex)
	failed := 0
	for _, dc := range []int{1, 2, 3, 4, 5} {
		before := engine.Stats()
		ok, detail := reqPQ(fmt.Sprintf("127.0.0.1:%d", port), secret, dc)
		after := engine.Stats()
		path := "?"
		switch {
		case after.WebSocket > before.WebSocket:
			path = "WebSocket"
		case after.DirectTCP > before.DirectTCP:
			path = "direct TCP"
		}
		status := "ok  "
		switch {
		case ok:
		case path == "direct TCP":
			// A direct connection to Telegram does not get through in many networks; that is why the proxy prefers the gateway.
			status = "warn"
		default:
			status, failed = "FAIL", failed+1
		}
		fmt.Printf("%s DC%d via %-10s %s\n", status, dc, path, detail)
	}
	if failed > 0 {
		fmt.Printf("%d data centers did not answer through the WebSocket gateway\n", failed)
		return 1
	}
	return 0
}

func reqPQ(proxy string, secret []byte, dc int) (bool, string) {
	client, err := tgproxy.DialClient(proxy, secret, dc)
	if err != nil {
		return false, err.Error()
	}
	defer client.Close()
	var nonce [16]byte
	rand.Read(nonce[:])
	// auth_key_id (0), message_id, length, req_pq_multi#be7e8ef1 nonce
	msg := make([]byte, 8)
	msg = binary.LittleEndian.AppendUint64(msg, uint64(time.Now().Unix())<<32&^3)
	msg = binary.LittleEndian.AppendUint32(msg, 20)
	msg = binary.LittleEndian.AppendUint32(msg, 0xbe7e8ef1)
	msg = append(msg, nonce[:]...)
	start := time.Now()
	if err := client.SendPacket(msg); err != nil {
		return false, err.Error()
	}
	resp, err := client.ReadPacket(10 * time.Second)
	if err != nil {
		return false, err.Error()
	}
	// auth_key_id(8) message_id(8) length(4) resPQ#05162463 nonce(16)
	if len(resp) < 40 || binary.LittleEndian.Uint32(resp[20:]) != 0x05162463 || string(resp[24:40]) != string(nonce[:]) {
		return false, fmt.Sprintf("an answer that is not resPQ (%d bytes)", len(resp))
	}
	return true, fmt.Sprintf("resPQ in %d ms", time.Since(start).Milliseconds())
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
