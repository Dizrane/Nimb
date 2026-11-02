package update

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
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
	// The signature: the fake signs the bytes of `signed` (the installer it started with) with a key of its own, and leaves the signature out
	// when noSig is set.
	pub    ed25519.PublicKey
	priv   ed25519.PrivateKey
	signed []byte
	noSig  bool
}

func newFake(t *testing.T, installer []byte, apiStatus int) *fake {
	f := &fake{installer: installer, apiStatus: apiStatus, asked: map[string]int{}, signed: installer}
	f.pub, f.priv, _ = ed25519.GenerateKey(nil)
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
		assets := []ghAsset{{Name: "Nimb-Setup-0.1.5-amd64.exe", URL: f.srv.URL + "/download/Nimb-Setup-0.1.5-amd64.exe"}}
		if !f.noSig {
			assets = append(assets, ghAsset{Name: "Nimb-Setup-0.1.5-amd64.exe.sig", URL: f.srv.URL + "/download/Nimb-Setup-0.1.5-amd64.exe.sig"})
		}
		list := []ghRelease{
			rel("v0.9.10", "", "Nimb-0.9.10.zip"),
			{Tag: "windows-v0.1.5", Body: body, PageURL: f.srv.URL + "/page", Prerelease: true, Assets: assets},
		}
		json.NewEncoder(w).Encode(list)
	})
	mux.HandleFunc("/"+Repository+"/releases.atom", func(w http.ResponseWriter, r *http.Request) {
		f.asked["feed"]++
		fmt.Fprintf(w, `<feed><link href="%s/%s/releases/tag/v0.9.10"/><link href="%s/%s/releases/tag/windows-v0.1.5"/></feed>`, f.srv.URL, Repository, f.srv.URL, Repository)
	})
	mux.HandleFunc("/"+Repository+"/releases/tag/windows-v0.1.5", func(w http.ResponseWriter, r *http.Request) {
		f.asked["page"]++
		sig := ""
		if !f.noSig {
			sig = `<a href="/x/Nimb-Setup-0.1.5-amd64.exe.sig">Nimb-Setup-0.1.5-amd64.exe.sig</a>`
		}
		fmt.Fprintf(w, "<html><a href=\"/x/Nimb-Setup-0.1.5-amd64.exe\">Nimb-Setup-0.1.5-amd64.exe</a>%s<p>%s</p></html>", sig, body)
	})
	mux.HandleFunc("/"+Repository+"/releases/download/windows-v0.1.5/Nimb-Setup-0.1.5-amd64.exe", func(w http.ResponseWriter, r *http.Request) { w.Write(f.installer) })
	mux.HandleFunc("/download/Nimb-Setup-0.1.5-amd64.exe", func(w http.ResponseWriter, r *http.Request) { w.Write(f.installer) })
	signature := func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, base64.StdEncoding.EncodeToString(ed25519.Sign(f.priv, f.signed)))
	}
	mux.HandleFunc("/download/Nimb-Setup-0.1.5-amd64.exe.sig", signature)
	mux.HandleFunc("/"+Repository+"/releases/download/windows-v0.1.5/Nimb-Setup-0.1.5-amd64.exe.sig", signature)
	return f
}

func (f *fake) client() *Client {
	c := NewClient("amd64")
	c.base = f.srv.URL
	c.Keys = []string{base64.StdEncoding.EncodeToString(f.pub)}
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

func TestNoWindowsReleaseIsAnAnswerNotAFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/releases") {
			w.Write([]byte(`[{"tag_name":"v0.9.12","assets":[]}]`)) // only a release of the Mac
			return
		}
		w.WriteHeader(404)
	}))
	defer srv.Close()
	c := NewClient("amd64")
	c.base = srv.URL
	if _, err := c.Latest(context.Background()); !errors.Is(err, ErrNoRelease) {
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
	f.signed = f.installer // signed by the maker, but not the file of the release: only the hash is wrong
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
	f.signed = f.installer
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

func TestWaitAfterFailureIsShorter(t *testing.T) {
	if got := Wait(Interval, false); got != 10*time.Minute {
		t.Errorf("after a good check: %v", got)
	}
	if got := Wait(Interval, true); got != 2*time.Minute {
		t.Errorf("after a failure: %v", got)
	}
	// A test interval that is already shorter than two minutes is not made longer.
	if got := Wait(30*time.Second, true); got != 30*time.Second {
		t.Errorf("short interval: %v", got)
	}
	last := time.Now()
	if IsDue(last, last.Add(90*time.Second), Wait(Interval, true)) {
		t.Error("90 seconds after a failure is too early")
	}
	if !IsDue(last, last.Add(116*time.Second), Wait(Interval, true)) {
		t.Error("two minutes after a failure (with the slack) is due")
	}
}

func TestWhatsNewTakesThePointsUpToTheFirstHeading(t *testing.T) {
	notes := "Нестабильная версия.\n\nNimb 0.3.1:\n\n1. **Первое.** Слова.\n2. Второе.\n- третье\n\n## Что работает\n- не это\n"
	got := WhatsNew(notes)
	if len(got) != 3 || got[0] != "**Первое.** Слова." || got[1] != "Второе." || got[2] != "третье" {
		t.Errorf("%q", got)
	}
	if len(WhatsNew("")) != 0 || len(WhatsNew("**SHA-256**\n- x")) != 0 {
		t.Error("nothing before the end is nothing")
	}
}

func TestTheStagesAddUpToOneAndAFailureNamesItsStage(t *testing.T) {
	sum := 0.0
	for s := Stage(0); s < StageCount; s++ {
		sum += s.Weight()
		if s.Title() == "" {
			t.Errorf("stage %d has no title", s)
		}
	}
	if sum < 0.999 || sum > 1.001 {
		t.Errorf("weights add up to %v", sum)
	}
	f := newFake(t, []byte("the installer"), 200)
	c := f.client()
	r, err := c.Latest(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	f.installer = []byte("something else")
	var seen []string
	var bytes int64
	_, err = c.Fetch(context.Background(), r, t.TempDir(), Hooks{
		Stage: func(s Stage, st string) { seen = append(seen, s.Title()+":"+st) },
		Bytes: func(done, total int64) { bytes = done },
	})
	var se *StageError
	if !errors.As(err, &se) || se.Stage != StageCheck || !se.Stage.IsOurs() {
		t.Fatalf("err = %#v", err)
	}
	if got := strings.Join(seen, ","); got != "Подготовка:running,Подготовка:done,Загрузка:running,Загрузка:done,Проверка подписи:running" {
		t.Errorf("stages: %s", got)
	}
	if bytes != int64(len("something else")) {
		t.Errorf("bytes %d", bytes)
	}
	noHash := r
	noHash.SHA256 = ""
	if _, err := c.Fetch(context.Background(), noHash, t.TempDir(), Hooks{}); !errors.As(err, &se) || se.Stage != StagePrepare {
		t.Errorf("no hash is a failure of the preparation: %v", err)
	}
}

// RFC 8032, the second test of Ed25519: the same signature that CryptoKit of the Mac makes and checks.
func TestASignatureOfEd25519IsTheOneOfTheMac(t *testing.T) {
	public, _ := hex.DecodeString("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
	signature, _ := hex.DecodeString("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
	keys := []string{base64.StdEncoding.EncodeToString(public)}
	text := base64.StdEncoding.EncodeToString(signature) + "\n" // a .sig file ends with a line break at most
	if !IsSigned([]byte{0x72}, text, keys) {
		t.Fatal("the signature of the standard does not hold")
	}
	if IsSigned([]byte{0x73}, text, keys) {
		t.Error("another file is not signed by it")
	}
	bad := append([]byte(nil), signature...)
	bad[0] ^= 1
	if IsSigned([]byte{0x72}, base64.StdEncoding.EncodeToString(bad), keys) {
		t.Error("a signature that was changed is not one")
	}
	if IsSigned([]byte{0x72}, text, nil) || IsSigned([]byte{0x72}, "not base64!", keys) || IsSigned([]byte{0x72}, "", keys) || IsSigned([]byte{0x72}, text, []string{"AAAA", "x"}) {
		t.Error("no key, no text, a key of the wrong size: nothing is signed")
	}
}

func TestAnInstallerNeedsASignatureOfItsMaker(t *testing.T) {
	f := newFake(t, []byte("the installer"), 200)
	c := f.client()
	r, err := c.Latest(context.Background())
	if err != nil || r.SigURL == "" {
		t.Fatalf("%+v %v", r, err)
	}
	if path, err := c.Download(context.Background(), r, t.TempDir(), func(string) {}); err != nil || path == "" {
		t.Fatalf("signed and right: %v", err)
	}
	var se *StageError
	// a file that was changed after it was signed (the hash of the notes is changed with it by whoever can change the release)
	f.installer = []byte("another installer")
	other := sha256.Sum256(f.installer)
	r.SHA256 = hex.EncodeToString(other[:])
	dir := t.TempDir()
	if _, err := c.Download(context.Background(), r, dir, func(string) {}); !errors.As(err, &se) || se.Stage != StageCheck || !strings.Contains(err.Error(), "Подпись не подошла") {
		t.Fatalf("a changed file: %v", err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("the file that failed stays: %v", entries)
	}
	// a signature that another key made
	f.installer = []byte("the installer")
	otherPub, _, _ := ed25519.GenerateKey(nil)
	c.Keys = []string{base64.StdEncoding.EncodeToString(otherPub)}
	r.SHA256 = hex.EncodeToString(func() []byte { h := sha256.Sum256(f.installer); return h[:] }())
	if _, err := c.Download(context.Background(), r, t.TempDir(), func(string) {}); err == nil || !strings.Contains(err.Error(), "Подпись не подошла") {
		t.Errorf("a signature of another key: %v", err)
	}
	// a release that has no signature (the page of the release and the API)
	for _, status := range []int{200, 403} {
		g := newFake(t, []byte("the installer"), status)
		g.noSig = true
		gc := g.client()
		gr, err := gc.Latest(context.Background())
		if err != nil || gr.SigURL != "" {
			t.Fatalf("status %d: %+v %v", status, gr, err)
		}
		if _, err := gc.Download(context.Background(), gr, t.TempDir(), func(string) {}); !errors.As(err, &se) || se.Stage != StageCheck || !strings.Contains(err.Error(), "нет подписи") {
			t.Errorf("status %d, no signature: %v", status, err)
		}
	}
	// the page of the release names the signature, the API refused
	h := newFake(t, []byte("the installer"), 403)
	hr, err := h.client().Latest(context.Background())
	if err != nil || !strings.HasSuffix(hr.SigURL, "/Nimb-Setup-0.1.5-amd64.exe.sig") {
		t.Errorf("the signature from the page: %+v %v", hr, err)
	}
	if _, err := h.client().Download(context.Background(), hr, t.TempDir(), func(string) {}); err != nil {
		t.Errorf("from the pages: %v", err)
	}
}

// The keys that updates are signed with are the ones of the Mac app: a different list in the two apps would be a quiet mistake.
func TestTheTrustedKeysAreTheOnesOfTheMacApp(t *testing.T) {
	raw, err := os.ReadFile("../../../Sources/Nimb/Updater.swift")
	if err != nil {
		t.Skip("the repository root is not here")
	}
	m := regexp.MustCompile(`static let trustedKeys = \[([^\]]*)\]`).FindStringSubmatch(string(raw))
	if m == nil {
		t.Fatal("no trustedKeys in the Mac app")
	}
	var mac []string
	for _, k := range regexp.MustCompile(`"([^"]+)"`).FindAllStringSubmatch(m[1], -1) {
		mac = append(mac, k[1])
	}
	if strings.Join(mac, ",") != strings.Join(TrustedKeys, ",") {
		t.Errorf("the Mac trusts %v, here %v", mac, TrustedKeys)
	}
}
