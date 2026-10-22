// Package update finds the newer version of Nimb for Windows and brings the installer. It is the port of Sources/Nimb/Updater.swift: the
// same sources (the API of GitHub, and the pages of the release when the API refuses), the same hash in the description of the release.
//
// The repository holds the releases of both versions, so "the latest release" of GitHub is of no use: it is whichever was made last. A
// release of Windows has the tag `windows-vX.Y.Z` (a pre-release, so that the Mac never takes it for the latest), and the installer
// `Nimb-Setup-X.Y.Z-<arch>.exe`. The tags of the Mac (`v0.9.10`) and everything else are not for this program.
package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Repository is where the releases are.
const Repository = "Dizrane/Nimb"

// Interval is how often the program asks about a new version: at the start, and then every ten minutes as long as it runs, never
// oftener (GitHub lets 60 requests an hour through for one address, and many people share one).
const Interval = 10 * time.Minute

// Release is a version that can be installed.
type Release struct {
	Version   string
	AssetName string
	URL       string // of the installer
	SHA256    string // from the description of the release; empty when it is not there
	PageURL   string
}

type ghAsset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}

type ghRelease struct {
	Tag        string    `json:"tag_name"`
	Body       string    `json:"body"`
	PageURL    string    `json:"html_url"`
	Assets     []ghAsset `json:"assets"`
	Draft      bool      `json:"draft"`
	Prerelease bool      `json:"prerelease"`
}

var reTag = regexp.MustCompile(`^windows-v([0-9]+(?:\.[0-9]+)*)$`)

// TagVersion is the version of a tag of Windows ("windows-v0.1.2" gives "0.1.2"); ok is false for any other tag.
func TagVersion(tag string) (version string, ok bool) {
	m := reTag.FindStringSubmatch(tag)
	if m == nil {
		return "", false
	}
	return m[1], true
}

// AssetName is the name of the installer for a version and an architecture ("amd64" or "arm64").
func AssetName(version, arch string) string {
	return fmt.Sprintf("Nimb-Setup-%s-%s.exe", version, arch)
}

// newest is the release with the highest version among those for Windows and this architecture: published (a draft is left out),
// a tag of Windows, and the installer is there. Pre-releases are taken (the releases of Windows are pre-releases). It is not the first
// of the list: the order is the order of making them.
func newest(list []ghRelease, arch string) (Release, bool) {
	var best Release
	found := false
	for _, r := range list {
		version, ok := TagVersion(r.Tag)
		if !ok || r.Draft {
			continue
		}
		name := AssetName(version, arch)
		var asset *ghAsset
		for i := range r.Assets {
			if r.Assets[i].Name == name {
				asset = &r.Assets[i]
			}
		}
		if asset == nil || (found && !IsNewer(version, best.Version)) {
			continue
		}
		best = Release{Version: version, AssetName: name, URL: asset.URL, SHA256: SHA256For(name, r.Body), PageURL: r.PageURL}
		found = true
	}
	return best, found
}

var reHash = regexp.MustCompile(`[0-9a-fA-F]{64}`)

// SHA256For is the hash written on the same line as the name of the file, lower case: the notes list one "hash  file" line per file.
func SHA256For(name, text string) string {
	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, name) {
			if h := reHash.FindString(line); h != "" {
				return strings.ToLower(h)
			}
		}
	}
	return ""
}

// IsNewer compares dotted numeric versions: "0.1.10" is newer than "0.1.9".
func IsNewer(candidate, current string) bool {
	a, b := parts(candidate), parts(current)
	for i := 0; i < max(len(a), len(b)); i++ {
		var x, y int
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func parts(version string) []int {
	var out []int
	for _, p := range strings.Split(strings.TrimLeft(version, "vV"), ".") {
		n, _ := strconv.Atoi(p)
		out = append(out, n)
	}
	return out
}

var reFeedTag = regexp.MustCompile(`/releases/tag/([^"?#/<>\s]+)`)

// NewestTagInFeed is the tag of Windows with the highest version in an Atom feed of releases.
func NewestTagInFeed(feed string) (tag string, ok bool) {
	best := ""
	for _, m := range reFeedTag.FindAllStringSubmatch(feed, -1) {
		if v, isWin := TagVersion(m[1]); isWin && (best == "" || IsNewer(v, best)) {
			best, tag, ok = v, m[1], true
		}
	}
	return tag, ok
}

// ShouldTell: one notification for one version, ever: not after a restart, not at the next check, and not for an older version if
// GitHub answers with a stale page for a moment. A newer version is told about again. told is the last version that was told.
func ShouldTell(version, told string) bool { return told == "" || IsNewer(version, told) }

// RetryAfterFailure: after a check that failed (GitHub did not answer) the next one comes sooner, so that «не удалось проверить» does
// not stay at the bottom of the window for ten minutes. The requests that GitHub never answered are not counted by its limit.
const RetryAfterFailure = 2 * time.Minute

// Wait is how long to wait before the next check. A check that GitHub refused because of its limit is not tried again sooner: that
// would only use the limit up.
func Wait(interval time.Duration, afterFailure bool) time.Duration {
	if afterFailure {
		return min(RetryAfterFailure, interval)
	}
	return interval
}

// IsDue tells whether a check is due: the timer is not exact, so a few seconds of slack.
func IsDue(lastTry, now time.Time, interval time.Duration) bool {
	return now.Sub(lastTry) >= interval-min(5*time.Second, interval/10)
}

// Client asks GitHub.
type Client struct {
	Arch string // "amd64" or "arm64"
	HTTP *http.Client
	// base is the place of GitHub; empty means the real one. See Override.
	base string
}

// Override reads the address of a stand-in for GitHub from NIMB_UPDATE_URL, for trying the update without a real release. It is
// taken only when it is on this computer (127.0.0.1, ::1 or localhost): an address that someone else could put there would make the
// program run an installer of their choice.
func Override(env string) string {
	u, err := url.Parse(env)
	if err != nil || u.Scheme != "http" {
		return ""
	}
	switch u.Hostname() {
	case "127.0.0.1", "::1", "localhost":
		return strings.TrimRight(env, "/")
	}
	return ""
}

// NewClient is a client for this computer's architecture.
func NewClient(arch string) *Client {
	return &Client{Arch: arch, HTTP: &http.Client{Timeout: 15 * time.Second}, base: Override(os.Getenv("NIMB_UPDATE_URL"))}
}

func (c *Client) api() string {
	if c.base != "" {
		return c.base
	}
	return "https://api.github.com"
}

func (c *Client) web() string {
	if c.base != "" {
		return c.base
	}
	return "https://github.com"
}

func (c *Client) get(ctx context.Context, address, accept string) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", address, nil)
	if err != nil {
		return nil, 0, err
	}
	if accept != "" {
		req.Header.Set("Accept", accept)
	}
	req.Header.Set("User-Agent", "Nimb-Windows")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	return body, resp.StatusCode, err
}

// ErrLimit means that GitHub refused because of the number of requests.
var ErrLimit = errors.New("GitHub ограничил число запросов с вашего адреса. Попробуйте через несколько минут.")

// ErrNoRelease means that GitHub answered and there is no release of Nimb for Windows with the installer for this computer (yet). It is an
// answer, not a failure of the check.
var ErrNoRelease = errors.New("На GitHub нет релиза Nimb для Windows")

// Latest is the newest release for this computer: from the API of GitHub, or from the pages of the release when the API refuses
// (the pages have no such limit).
func (c *Client) Latest(ctx context.Context) (Release, error) {
	rel, err := c.latestFromAPI(ctx)
	if err == nil {
		return rel, nil
	}
	if page, perr := c.latestFromPage(ctx); perr == nil {
		return page, nil
	}
	return Release{}, err
}

func (c *Client) latestFromAPI(ctx context.Context) (Release, error) {
	body, status, err := c.get(ctx, c.api()+"/repos/"+Repository+"/releases?per_page=20", "application/vnd.github+json")
	if err != nil {
		return Release{}, errors.New("GitHub не ответил.")
	}
	if status != 200 {
		if status == 403 || status == 429 {
			return Release{}, ErrLimit
		}
		return Release{}, errors.New("GitHub не отдал информацию о релизе.")
	}
	var list []ghRelease
	if err := json.Unmarshal(body, &list); err != nil {
		return Release{}, errors.New("GitHub отдал непонятный ответ.")
	}
	rel, ok := newest(list, c.Arch)
	if !ok {
		return Release{}, fmt.Errorf("%w с файлом Nimb-Setup-*-%s.exe.", ErrNoRelease, c.Arch)
	}
	return rel, nil
}

// latestFromPage reads the feed of releases (it names the tags, the newest of Windows is taken) and then the page of that release,
// which has the installer and, in its description, the hash on the line with the file name.
func (c *Client) latestFromPage(ctx context.Context) (Release, error) {
	feed, status, err := c.get(ctx, c.web()+"/"+Repository+"/releases.atom", "")
	if err != nil || status != 200 {
		return Release{}, errors.New("GitHub не отдал список релизов.")
	}
	tag, ok := NewestTagInFeed(string(feed))
	if !ok {
		return Release{}, errors.New("В списке релизов нет версии для Windows.")
	}
	version, _ := TagVersion(tag)
	page := c.web() + "/" + Repository + "/releases/tag/" + tag
	html, status, err := c.get(ctx, page, "")
	if err != nil || status != 200 {
		return Release{}, errors.New("GitHub не отдал страницу релиза.")
	}
	name := AssetName(version, c.Arch)
	if !strings.Contains(string(html), name) {
		return Release{}, errors.New("На странице релиза нет файла " + name + ".")
	}
	return Release{Version: version, AssetName: name, URL: c.web() + "/" + Repository + "/releases/download/" + tag + "/" + name,
		SHA256: SHA256For(name, string(html)), PageURL: page}, nil
}

// allowedHost: the installer comes from GitHub (its release files are served from githubusercontent.com), or from this computer when
// the address of GitHub is overridden.
func (c *Client) allowedURL(address string) bool {
	u, err := url.Parse(address)
	if err != nil {
		return false
	}
	if c.base != "" {
		return Override(u.Scheme+"://"+u.Host) != ""
	}
	host := u.Hostname()
	return u.Scheme == "https" && (host == "github.com" || strings.HasSuffix(host, ".github.com") || strings.HasSuffix(host, ".githubusercontent.com"))
}

// Download brings the installer into dir and checks it against the hash of the release. Without a hash nothing is downloaded: the
// installer has no signature yet, so the hash is the only check. The file is deleted if the hash does not match.
func (c *Client) Download(ctx context.Context, rel Release, dir string, status func(string)) (path string, err error) {
	if rel.SHA256 == "" {
		return "", errors.New("В описании релиза нет SHA-256, установка отменена.")
	}
	if !c.allowedURL(rel.URL) {
		return "", errors.New("Адрес установщика не с GitHub, установка отменена.")
	}
	if rel.AssetName != filepath.Base(rel.AssetName) || !strings.HasPrefix(rel.AssetName, "Nimb-Setup-") {
		return "", errors.New("Неожиданное имя установщика, установка отменена.")
	}
	status("Загрузка…")
	req, err := http.NewRequestWithContext(ctx, "GET", rel.URL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Nimb-Windows")
	resp, err := (&http.Client{Timeout: 10 * time.Minute}).Do(req)
	if err != nil {
		return "", errors.New("Не удалось скачать " + rel.AssetName + ".")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", errors.New("Не удалось скачать " + rel.AssetName + ".")
	}
	path = filepath.Join(dir, rel.AssetName)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, 200<<20))
	f.Close()
	if err != nil {
		os.Remove(path)
		return "", errors.New("Не удалось скачать " + rel.AssetName + ".")
	}
	status("Проверка…")
	if hex.EncodeToString(h.Sum(nil)) != strings.ToLower(rel.SHA256) {
		os.Remove(path)
		return "", errors.New("SHA-256 скачанного файла не совпадает с указанным в релизе. Установка отменена.")
	}
	return path, nil
}
