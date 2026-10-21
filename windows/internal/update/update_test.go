package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func rel(tag string, body string, assets ...string) ghRelease {
	r := ghRelease{Tag: tag, Body: body, PageURL: "https://example.test/" + tag}
	for _, a := range assets {
		r.Assets = append(r.Assets, ghAsset{Name: a, URL: "https://github.com/x/" + tag + "/" + a})
	}
	return r
}

const hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func TestTagsOfWindows(t *testing.T) {
	for tag, want := range map[string]string{"windows-v0.1.1": "0.1.1", "windows-v1": "1", "windows-v0.10.0": "0.10.0"} {
		if v, ok := TagVersion(tag); !ok || v != want {
			t.Errorf("%q: %q %v", tag, v, ok)
		}
	}
	for _, tag := range []string{"v0.9.10", "0.9.10", "V1.0", "windows-0.1.1", "windows-v0.1.1-beta", "windows-v", "latest", "", "xwindows-v0.1.1", "windows-v0.1.1.zip"} {
		if _, ok := TagVersion(tag); ok {
			t.Errorf("%q is not a tag of Windows", tag)
		}
	}
}

func TestNewestTakesWindowsReleasesOnly(t *testing.T) {
	win := func(v string) ghRelease {
		return rel("windows-v"+v, "", AssetName(v, "amd64"), AssetName(v, "arm64"))
	}
	pre := func(r ghRelease) ghRelease { r.Prerelease = true; return r }
	list := []ghRelease{
		rel("v0.9.10", "", "Nimb-0.9.10.zip", "Nimb-Setup-9.9.9-amd64.exe"), // a release of the Mac, whatever it holds
		pre(win("0.1.1")), win("0.1.9"), pre(win("0.1.10")), win("0.1.2"),
		rel("windows-v9.0.0", "", AssetName("9.0.0", "amd64")), // a draft is below
	}
	list[len(list)-1].Draft = true
	got, ok := newest(list, "amd64")
	if !ok || got.Version != "0.1.10" || got.AssetName != "Nimb-Setup-0.1.10-amd64.exe" {
		t.Fatalf("got %+v: the highest version counts numerically (0.1.10 over 0.1.9), pre-releases are taken, drafts and tags of the Mac are not", got)
	}
	if got, _ := newest(list, "arm64"); got.AssetName != "Nimb-Setup-0.1.10-arm64.exe" {
		t.Errorf("arm64: %+v", got)
	}
}

func TestNewestNeedsTheInstallerOfThisArchitecture(t *testing.T) {
	list := []ghRelease{rel("windows-v0.2.0", "", "Nimb-Setup-0.2.0-arm64.exe"), rel("windows-v0.1.0", "", "Nimb-Setup-0.1.0-amd64.exe")}
	if got, ok := newest(list, "amd64"); !ok || got.Version != "0.1.0" {
		t.Errorf("amd64 takes the newest that has its installer: %+v %v", got, ok)
	}
	if _, ok := newest([]ghRelease{rel("v0.9.9", "", "Nimb-0.9.9.zip")}, "amd64"); ok {
		t.Error("nothing for Windows")
	}
	if _, ok := newest(nil, "amd64"); ok {
		t.Error("an empty list")
	}
	if got, _ := newest([]ghRelease{rel("windows-v0.1.0", "", "Nimb-Setup-0.1.0-amd64.exe.sig")}, "amd64"); got.Version != "" {
		t.Error("a file with a longer name is not the installer")
	}
}

func TestTheHashIsTheOneOnTheLineOfTheFile(t *testing.T) {
	other := strings.Repeat("a", 64)
	body := fmt.Sprintf("Что нового\n%s  Nimb-Setup-0.1.2-arm64.exe\n%s  Nimb-Setup-0.1.2-amd64.exe\n", other, strings.ToUpper(hash))
	if got := SHA256For("Nimb-Setup-0.1.2-amd64.exe", body); got != hash {
		t.Errorf("got %q (lower case, from its own line)", got)
	}
	if SHA256For("Nimb-Setup-0.1.2-x86.exe", body) != "" || SHA256For("a.exe", "") != "" || SHA256For("a.exe", "a.exe без суммы") != "" {
		t.Error("no hash on the line, no hash")
	}
	r := rel("windows-v0.1.2", body, "Nimb-Setup-0.1.2-amd64.exe")
	if got, _ := newest([]ghRelease{r}, "amd64"); got.SHA256 != hash {
		t.Errorf("%+v", got)
	}
}

func TestVersionsCompareNumerically(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{{"0.1.10", "0.1.9", true}, {"0.2", "0.1.9", true}, {"1.0.0", "0.9.9", true}, {"0.1.1", "0.1.1", false}, {"0.1", "0.1.0", false}, {"0.1.0", "0.1.1", false}, {"v0.1.2", "0.1.1", true}} {
		if got := IsNewer(c.a, c.b); got != c.want {
			t.Errorf("IsNewer(%q, %q) = %v", c.a, c.b, got)
		}
	}
}

func TestTheFeedNamesTheNewestTagOfWindows(t *testing.T) {
	feed := `<feed><entry><link href="https://github.com/Dizrane/Nimb/releases/tag/v0.9.10"/></entry>
	<entry><link href="https://github.com/Dizrane/Nimb/releases/tag/windows-v0.1.9"/></entry>
	<entry><link href="https://github.com/Dizrane/Nimb/releases/tag/windows-v0.1.10"/></entry>
	<entry><link href="https://github.com/Dizrane/Nimb/releases/tag/windows-v9.9.9-beta"/></entry></feed>`
	if got, ok := NewestTagInFeed(feed); !ok || got != "windows-v0.1.10" {
		t.Errorf("got %q %v", got, ok)
	}
	if _, ok := NewestTagInFeed(`<link href="/releases/tag/v0.9.10"/>`); ok {
		t.Error("the Mac has no place in this feed")
	}
}

func TestOneNotificationForOneVersion(t *testing.T) {
	if !ShouldTell("0.1.2", "") || ShouldTell("0.1.2", "0.1.2") || ShouldTell("0.1.1", "0.1.2") || !ShouldTell("0.1.3", "0.1.2") || !ShouldTell("0.1.10", "0.1.9") {
		t.Error("told once, an older one never, a newer one again")
	}
}

func TestACheckIsDueEveryTenMinutes(t *testing.T) {
	t0 := time.Unix(1_800_000_000, 0)
	if !IsDue(time.Time{}, t0, Interval) || IsDue(t0, t0.Add(30*time.Second), Interval) || IsDue(t0, t0.Add(9*time.Minute), Interval) {
		t.Error("first at once, not within nine minutes")
	}
	if !IsDue(t0, t0.Add(10*time.Minute), Interval) || !IsDue(t0, t0.Add(10*time.Minute-3*time.Second), Interval) || IsDue(t0, t0.Add(10*time.Minute-20*time.Second), Interval) {
		t.Error("a few seconds of slack, not more")
	}
}

func TestOnlyAnAddressOnThisComputerReplacesGitHub(t *testing.T) {
	for _, ok := range []string{"http://127.0.0.1:8080", "http://localhost:9000/", "http://[::1]:1"} {
		if Override(ok) == "" {
			t.Errorf("%q is on this computer", ok)
		}
	}
	for _, bad := range []string{"", "http://example.com", "https://127.0.0.1:1", "http://127.0.0.1.evil.com", "http://192.168.1.5:80", "ftp://127.0.0.1", "127.0.0.1"} {
		if Override(bad) != "" {
			t.Errorf("%q must not be taken", bad)
		}
	}
}

// ---- the network part, against a stand-in for GitHub -----------------------------------------------------------------------

type fake struct {
	srv       *httptest.Server
	installer []byte
	apiStatus int
	feed      bool
	asked     map[string]int
}

func newFake(t *testing.T, installer []byte, apiStatus int) *fake {
	f := &fake{installer: installer, apiStatus: apiStatus, asked: map[string]int{}}
	sum := sha256.Sum256(installer)
	body := hex.EncodeToString(sum[:]) + "  Nimb-Setup-0.1.5-amd64.exe\n"
	mux := http.NewServeMux()
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	mux.HandleFunc("/repos/"+Repository+"/releases", func(w http.ResponseWriter, r *http.Request) {
		f.asked["api"]++
		if f.apiStatus != 200 {
			w.WriteHeader(f.apiStatus)
			return
		}
		list := []ghRelease{
			rel("v0.9.10", "", "Nimb-0.9.10.zip"),
			{Tag: "windows-v0.1.5", Body: body, PageURL: f.srv.URL + "/page", Prerelease: true,
				Assets: []ghAsset{{Name: "Nimb-Setup-0.1.5-amd64.exe", URL: f.srv.URL + "/download/Nimb-Setup-0.1.5-amd64.exe"}}},
		}
		json.NewEncoder(w).Encode(list)
	})
	mux.HandleFunc("/"+Repository+"/releases.atom", func(w http.ResponseWriter, r *http.Request) {
		f.asked["feed"]++
		fmt.Fprintf(w, `<feed><link href="%s/%s/releases/tag/v0.9.10"/><link href="%s/%s/releases/tag/windows-v0.1.5"/></feed>`, f.srv.URL, Repository, f.srv.URL, Repository)
	})
	mux.HandleFunc("/"+Repository+"/releases/tag/windows-v0.1.5", func(w http.ResponseWriter, r *http.Request) {
		f.asked["page"]++
		fmt.Fprintf(w, "<html><a href=\"/x/Nimb-Setup-0.1.5-amd64.exe\">Nimb-Setup-0.1.5-amd64.exe</a><p>%s</p></html>", body)
	})
	mux.HandleFunc("/"+Repository+"/releases/download/windows-v0.1.5/Nimb-Setup-0.1.5-amd64.exe", func(w http.ResponseWriter, r *http.Request) { w.Write(f.installer) })
	mux.HandleFunc("/download/Nimb-Setup-0.1.5-amd64.exe", func(w http.ResponseWriter, r *http.Request) { w.Write(f.installer) })
	return f
}

func (f *fake) client() *Client {
	c := NewClient("amd64")
	c.base = f.srv.URL
	return c
}

func TestLatestFromTheAPI(t *testing.T) {
	f := newFake(t, []byte("installer"), 200)
	got, err := f.client().Latest(context.Background())
	if err != nil || got.Version != "0.1.5" || got.AssetName != "Nimb-Setup-0.1.5-amd64.exe" || len(got.SHA256) != 64 || f.asked["feed"] != 0 {
		t.Fatalf("%+v %v %v", got, err, f.asked)
	}
}

func TestLatestFromThePagesWhenTheAPIRefuses(t *testing.T) {
	for _, status := range []int{403, 429, 500} {
		f := newFake(t, []byte("installer"), status)
		got, err := f.client().Latest(context.Background())
		if err != nil || got.Version != "0.1.5" || len(got.SHA256) != 64 || f.asked["feed"] != 1 || f.asked["page"] != 1 {
			t.Fatalf("status %d: %+v %v %v", status, got, err, f.asked)
		}
	}
}

func TestTheLimitIsToldWhenThePagesDoNotHelp(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(403) }))
	defer srv.Close()
	c := NewClient("amd64")
	c.base = srv.URL
	if _, err := c.Latest(context.Background()); err != ErrLimit {
		t.Errorf("err = %v", err)
	}
}

func TestDownloadChecksTheHash(t *testing.T) {
	f := newFake(t, []byte("the installer"), 200)
	c := f.client()
	r, err := c.Latest(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	// a file that is not the one of the release
	f.installer = []byte("something else")
	var said []string
	if _, err := c.Download(context.Background(), r, dir, func(s string) { said = append(said, s) }); err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("err = %v", err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("the wrong file stays: %v", entries)
	}
	if strings.Join(said, ",") != "Загрузка…,Проверка…" {
		t.Errorf("status: %v", said)
	}
	// the right one
	f.installer = []byte("the installer")
	path, err := c.Download(context.Background(), r, dir, func(string) {})
	if err != nil || filepath.Base(path) != "Nimb-Setup-0.1.5-amd64.exe" {
		t.Fatalf("%q %v", path, err)
	}
	if raw, _ := os.ReadFile(path); string(raw) != "the installer" {
		t.Error("content")
	}
}

func TestDownloadNeedsAHashAndAnAddressOfGitHub(t *testing.T) {
	f := newFake(t, []byte("x"), 200)
	c := f.client()
	r, _ := c.Latest(context.Background())
	noHash := r
	noHash.SHA256 = ""
	if _, err := c.Download(context.Background(), noHash, t.TempDir(), func(string) {}); err == nil || !strings.Contains(err.Error(), "нет SHA-256") {
		t.Errorf("no hash: %v", err)
	}
	foreign := r
	foreign.URL = "http://203.0.113.5/Nimb-Setup-0.1.5-amd64.exe"
	if _, err := c.Download(context.Background(), foreign, t.TempDir(), func(string) {}); err == nil || !strings.Contains(err.Error(), "не с GitHub") {
		t.Errorf("foreign address: %v", err)
	}
	// the real client takes only GitHub
	real := NewClient("amd64")
	real.base = ""
	for _, bad := range []string{"http://github.com/x", "https://evil.example/x", "https://github.com.evil.example/x", "https://127.0.0.1/x"} {
		if real.allowedURL(bad) {
			t.Errorf("%q must not be downloaded from", bad)
		}
	}
	for _, good := range []string{"https://github.com/Dizrane/Nimb/releases/download/windows-v0.1.5/x.exe", "https://release-assets.githubusercontent.com/x"} {
		if !real.allowedURL(good) {
			t.Errorf("%q is GitHub", good)
		}
	}
	weird := r
	weird.AssetName = `..\evil.exe`
	if _, err := c.Download(context.Background(), weird, t.TempDir(), func(string) {}); err == nil {
		t.Error("a name with a path")
	}
}
