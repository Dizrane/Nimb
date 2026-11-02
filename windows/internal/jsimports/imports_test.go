// Package jsimports holds one test: the page of Nimb is plain JavaScript modules that no Go test or vet looks at, and a function of another
// module that is called without being imported only fails when that line runs (the first setup once died with «morph is not defined»).
// The test reads frontend/dist/js/*.js and fails when a file calls a function that another module exports, and neither imports nor
// declares it.
package jsimports

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

var (
	reBlockComment = regexp.MustCompile(`(?s)/\*.*?\*/`)
	reLineComment  = regexp.MustCompile(`(?m)(^|[^:'"` + "`" + `\\])//.*$`)
	reString       = regexp.MustCompile("'(?:[^'\\\\\\n]|\\\\.)*'|\"(?:[^\"\\\\\\n]|\\\\.)*\"")
	reExport       = regexp.MustCompile(`(?m)^export\s+(?:async\s+)?(?:function\*?|const|let|class)\s+([A-Za-z_$][\w$]*)`)
	reImport       = regexp.MustCompile(`(?s)import\s*\{([^}]*)\}\s*from\s*['"]\./([\w.-]+)['"]`)
	reDeclared     = regexp.MustCompile(`(?:function\*?|const|let|var|class)\s+([A-Za-z_$][\w$]*)`)
)

// code is the source without comments and the words in quotes (a call inside a text is not a call). Template strings stay: their ${...}
// holds real calls.
func code(src string) string { return reString.ReplaceAllString(uncommented(src), "''") }

func uncommented(src string) string {
	src = reBlockComment.ReplaceAllString(src, "")
	return reLineComment.ReplaceAllString(src, "$1")
}

func TestEveryCalledFunctionOfAnotherModuleIsImported(t *testing.T) {
	dir := filepath.Join("..", "..", "cmd", "nimb", "frontend", "dist", "js")
	files, err := filepath.Glob(filepath.Join(dir, "*.js"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no scripts found in %s: %v", dir, err)
	}
	src, heads := map[string]string{}, map[string]string{} // the code, and the code with its words in quotes (the imports name modules in quotes)
	exports := map[string][]string{}                       // module -> names it exports
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		name := filepath.Base(f)
		src[name], heads[name] = code(string(raw)), uncommented(string(raw))
		for _, m := range reExport.FindAllStringSubmatch(src[name], -1) {
			exports[name] = append(exports[name], m[1])
		}
	}
	names := make([]string, 0, len(src))
	for n := range src {
		names = append(names, n)
	}
	sort.Strings(names)
	checked := 0
	for _, file := range names {
		text := src[file]
		imported := map[string]bool{}
		for _, m := range reImport.FindAllStringSubmatch(heads[file], -1) {
			if _, ok := src[m[2]]; !ok {
				t.Errorf("%s imports ./%s, which is not there", file, m[2])
			}
			for _, part := range strings.Split(m[1], ",") {
				if f := strings.Fields(part); len(f) > 0 {
					imported[f[len(f)-1]] = true // «a as b» gives b
				}
			}
		}
		declared := map[string]bool{}
		for _, m := range reDeclared.FindAllStringSubmatch(text, -1) {
			declared[m[1]] = true
		}
		for module, list := range exports {
			if module == file {
				continue
			}
			for _, name := range list {
				if imported[name] || declared[name] {
					continue
				}
				call := regexp.MustCompile(`(^|[^.\w$])` + regexp.QuoteMeta(name) + `\s*\(`)
				checked++
				if call.MatchString(text) {
					t.Errorf("%s calls %s(), which %s exports, but does not import it", file, name, module)
				}
			}
		}
	}
	if checked == 0 {
		t.Fatal("nothing was checked")
	}
}
