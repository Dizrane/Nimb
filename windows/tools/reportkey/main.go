// Command reportkey makes the key that signs the reports of one release of Nimb for Windows, as the build puts it into the program:
//
//	reportkey mixed KEYFILE VERSION
//
// KEYFILE holds the master key (the same file that the Mac build uses, outside the repository). The key of the version is made from it
// (report.VersionKey), mixed with the version (report.Mix) and printed in hex: that is what installer/build.sh gives to the linker. The master
// key itself is read here and printed nowhere.
package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/Dizrane/Nimb/windows/internal/report"
)

func main() {
	if len(os.Args) != 4 || os.Args[1] != "mixed" {
		fmt.Fprintln(os.Stderr, "usage: reportkey mixed KEYFILE VERSION")
		os.Exit(2)
	}
	raw, err := os.ReadFile(os.Args[2])
	master := strings.TrimSpace(string(raw))
	if err != nil || master == "" {
		fmt.Fprintln(os.Stderr, "reportkey: no master key in the file")
		os.Exit(1)
	}
	version := os.Args[3]
	fmt.Println(report.Mix([]byte(report.VersionKey(master, version)), version))
}
