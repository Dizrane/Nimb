//go:build windows

package main

import (
	"os"
	"path/filepath"
	"sync"

	"github.com/Dizrane/Nimb/windows/internal/buildcheck"
	"github.com/Dizrane/Nimb/windows/internal/report"
)

// Whether this is a build of ours: see internal/buildcheck. Both variables are given to the linker by installer/build.sh and are empty in a build from the sources:
//   - officialReportKey is the key of this version, mixed with its number;
//   - officialFiles lists the sums of the files that stand next to the window and that it works with: "nimb-svc.exe=<sha256>;wintun.dll=<sha256>".
var (
	officialReportKey string
	officialFiles     string
)

func init() { report.SetKey(report.Unmix(officialReportKey, Version)) }

var buildLooked struct {
	once    sync.Once
	problem string
}

// buildProblem says why this build is not ours, in words for a report; "" when it is. It is looked at once: it reads the files.
func buildProblem() string {
	buildLooked.once.Do(func() {
		buildLooked.problem = buildcheck.Problem(report.Unmix(officialReportKey, Version) != nil, officialFiles, installDir())
	})
	return buildLooked.problem
}

// buildLine is the line of a report about the build: «Сборка: наша / изменена (причина)».
func buildLine() string {
	if problem := buildProblem(); problem != "" {
		return "Сборка: изменена (" + problem + ")"
	}
	return "Сборка: наша"
}

func installDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Dir(exe)
}
