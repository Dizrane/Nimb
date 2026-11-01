// Package callbackguard holds one test: Go lets a program make at most 2000 callbacks with syscall.NewCallback and never frees them, so
// a callback made on every call of a function that is called again and again (the tray asks for the window every 3 seconds) kills the
// program after about 100 minutes ("compileCallback: function ... too many callbacks"). The test reads all the sources of the module and
// fails when a callback is made anywhere but in a package variable or inside sync.OnceValue / sync.Once.Do.
package callbackguard

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"
)

func isCallbackMaker(call *ast.CallExpr) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	return ok && (sel.Sel.Name == "NewCallback" || sel.Sel.Name == "NewCallbackCDecl")
}

// isOnce says whether the call is sync.OnceValue(...), sync.OnceFunc(...), sync.OnceValues(...) or x.Do(...).
func isOnce(call *ast.CallExpr) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	switch sel.Sel.Name {
	case "OnceValue", "OnceValues", "OnceFunc":
		return true
	case "Do":
		return true
	}
	return false
}

func TestCallbacksAreMadeOnce(t *testing.T) {
	root := filepath.Join("..", "..")
	fset := token.NewFileSet()
	checked := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "node_modules" || d.Name() == "callbackguard" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") {
			return nil
		}
		file, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Errorf("%s: %v", path, err)
			return nil
		}
		for _, decl := range file.Decls {
			fn, isFunc := decl.(*ast.FuncDecl)
			if !isFunc {
				continue // a package variable runs once
			}
			var stack []ast.Node
			ast.Inspect(fn, func(n ast.Node) bool {
				if n == nil {
					stack = stack[:len(stack)-1]
					return true
				}
				stack = append(stack, n)
				call, ok := n.(*ast.CallExpr)
				if !ok || !isCallbackMaker(call) {
					return true
				}
				checked++
				for _, up := range stack[:len(stack)-1] {
					if outer, ok := up.(*ast.CallExpr); ok && isOnce(outer) {
						return true
					}
				}
				t.Errorf("%s: a callback is made inside func %s on every call; at most 2000 can be made in a program's life, make it once (package variable or sync.OnceValue)",
					fset.Position(call.Pos()), fn.Name.Name)
				return true
			})
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if checked == 0 {
		t.Log("no callback is made inside a function")
	}
}
