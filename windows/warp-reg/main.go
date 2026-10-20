// warp-reg registers an anonymous Cloudflare WARP account and writes the settings of the tunnel as an AmneziaWG .conf file, for
// trying the tunnel by hand (for example in the official AmneziaWG client). The service of Nimb does the same by itself.
//
//	warp-reg -out nimb-warp.conf     register and write the settings
//	warp-reg -delete nimb-warp.conf  delete the account that the file was made for
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/Dizrane/Nimb/windows/internal/warp"
)

func main() {
	out := flag.String("out", "nimb-warp.conf", "file for the settings of the tunnel")
	del := flag.String("delete", "", "settings file whose account is to be deleted")
	flag.Parse()

	if *del != "" {
		if err := deleteFor(*del); err != nil {
			fatal(err)
		}
		fmt.Println("account deleted")
		return
	}
	acc, err := warp.Register(context.Background())
	if err != nil {
		fatal(err)
	}
	// The account id and token travel in comments of the file: the client ignores them, and `-delete` reads them.
	text := acc.Config + fmt.Sprintf("\n# nimb-account-id=%s\n# nimb-account-token=%s\n", acc.ID, acc.Token)
	if err := os.WriteFile(*out, []byte(text), 0o600); err != nil {
		fatal(err)
	}
	fmt.Printf("written %s (account %s). Delete the account with: warp-reg -delete %s\n", *out, acc.ID, *out)
}

func deleteFor(file string) error {
	raw, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	var id, token string
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if v, ok := strings.CutPrefix(line, "# nimb-account-id="); ok {
			id = v
		}
		if v, ok := strings.CutPrefix(line, "# nimb-account-token="); ok {
			token = v
		}
	}
	return warp.Unregister(context.Background(), id, token)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
