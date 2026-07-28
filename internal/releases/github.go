package releases

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/xZenLabs/zen-pm/internal/cabundle"
	"github.com/xZenLabs/zen-pm/internal/httpdiag"
)

const githubResponseLimit = 4 * 1024 * 1024

var githubAPIBaseURL = "https://api.github.com"

type ReleaseAsset struct {
	Name   string `json:"name"`
	URL    string `json:"url"`
	Size   int64  `json:"size,omitempty"`
	Digest string `json:"digest,omitempty"`
}

type Release struct {
	TagName    string         `json:"tag_name"`
	Name       string         `json:"name,omitempty"`
	Prerelease bool           `json:"prerelease,omitempty"`
	Assets     []ReleaseAsset `json:"assets"`
}

// ReadmeDocument is the raw README Markdown together with the directory used
// to resolve relative links and images embedded in it.
type ReadmeDocument struct {
	Readme  string
	BaseURL string
}

func GitHubRepository(source string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(source))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || !strings.EqualFold(u.Hostname(), "github.com") {
		return "", false
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", false
	}
	repo := strings.TrimSuffix(parts[1], ".git")
	if repo == "" {
		return "", false
	}
	return parts[0] + "/" + repo, true
}

func GitHubReleaseURL(source, tag string) (string, error) {
	repository, ok := GitHubRepository(source)
	if !ok {
		return "", fmt.Errorf("source is not a GitHub repository")
	}
	tag = strings.TrimSpace(tag)
	if tag == "" {
		return "", fmt.Errorf("release tag is required")
	}
	return "https://github.com/" + repository + "/releases/tag/" + url.PathEscape(tag), nil
}

// FetchReadme retrieves Markdown from a repository-hosted README URL.
func FetchReadme(readmeURL string) (string, error) {
	document, err := FetchReadmeDocument(readmeURL)
	if err != nil {
		return "", err
	}
	return document.Readme, nil
}

// FetchReadmeDocument retrieves Markdown and the final response directory
// after following redirects.
func FetchReadmeDocument(readmeURL string) (ReadmeDocument, error) {
	u, err := url.Parse(strings.TrimSpace(readmeURL))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return ReadmeDocument{}, fmt.Errorf("README URL must be an HTTP(S) URL")
	}
	req, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		return ReadmeDocument{}, err
	}
	req.Header.Set("User-Agent", "ZenPackageManager")
	client := cabundle.Client(15 * time.Second)
	resp, err := client.Do(req)
	if err != nil {
		return ReadmeDocument{}, fmt.Errorf("README request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return ReadmeDocument{}, fmt.Errorf("README request: %w", httpdiag.ResponseError(resp))
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, githubResponseLimit+1))
	if err != nil {
		return ReadmeDocument{}, err
	}
	if len(data) > githubResponseLimit {
		return ReadmeDocument{}, fmt.Errorf("README response is too large")
	}
	baseURL, err := readmeBaseURL(resp.Request.URL)
	if err != nil {
		return ReadmeDocument{}, err
	}
	return ReadmeDocument{Readme: string(data), BaseURL: baseURL}, nil
}

func readmeBaseURL(readmeURL *url.URL) (string, error) {
	if readmeURL == nil || readmeURL.Scheme == "" || readmeURL.Host == "" {
		return "", fmt.Errorf("README response has no URL")
	}
	base := *readmeURL
	base.RawQuery = ""
	base.Fragment = ""
	if !strings.HasSuffix(base.Path, "/") {
		base.Path = base.Path[:strings.LastIndex(base.Path, "/")+1]
	}
	return base.String(), nil
}

// FetchGitHubReleases returns up to limit releases in one request. The frontend
// paginates the result for display; fetching them all at once keeps GitHub API
// calls low, which matters under the anonymous rate limit (60 req/hr per IP).
func FetchGitHubReleases(source string, limit int) ([]Release, error) {
	repository, ok := GitHubRepository(source)
	if !ok {
		return nil, fmt.Errorf("source is not a GitHub repository")
	}
	if limit < 1 {
		limit = 10
	}
	if limit > 100 {
		limit = 100
	}
	path := fmt.Sprintf("/repos/%s/releases?per_page=%d", repository, limit)
	data, err := githubRequest(path, "application/vnd.github+json")
	if err != nil {
		return nil, err
	}
	var response []struct {
		TagName    string `json:"tag_name"`
		Name       string `json:"name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			Name   string `json:"name"`
			URL    string `json:"browser_download_url"`
			Size   int64  `json:"size"`
			Digest string `json:"digest"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(data, &response); err != nil {
		return nil, fmt.Errorf("decode GitHub releases: %w", err)
	}
	out := make([]Release, 0, len(response))
	for _, item := range response {
		if item.Draft || strings.TrimSpace(item.TagName) == "" {
			continue
		}
		release := Release{
			TagName:    item.TagName,
			Name:       item.Name,
			Prerelease: item.Prerelease,
			Assets:     []ReleaseAsset{},
		}
		for _, asset := range item.Assets {
			if strings.HasSuffix(strings.ToLower(asset.Name), ".zip") && asset.URL != "" {
				release.Assets = append(release.Assets, ReleaseAsset{Name: asset.Name, URL: asset.URL, Size: asset.Size, Digest: asset.Digest})
			}
		}
		if len(release.Assets) > 0 {
			out = append(out, release)
		}
	}
	return out, nil
}

// ResolveGitHubReleaseAsset returns the requested asset from a GitHub release.
// An empty tag selects the newest non-prerelease release. asset may be an exact
// filename or a suffix beginning with a dot (for example, ".koplugin.zip").
// Version and ABI spelling changes are tolerated when unambiguous.
func ResolveGitHubReleaseAsset(source, tag, asset string) (Release, ReleaseAsset, error) {
	tag = strings.TrimSpace(tag)
	asset = strings.TrimSpace(asset)
	if asset == "" {
		return Release{}, ReleaseAsset{}, fmt.Errorf("release asset name is required")
	}

	releases, err := FetchGitHubReleases(source, 30)
	if err != nil {
		return Release{}, ReleaseAsset{}, err
	}
	for _, release := range releases {
		if tag != "" && release.TagName != tag {
			continue
		}
		if tag == "" && release.Prerelease {
			continue
		}
		if candidate, ok := matchReleaseAsset(release.Assets, asset); ok {
			return release, candidate, nil
		}
		if tag != "" {
			return Release{}, ReleaseAsset{}, fmt.Errorf("release %q has no asset matching %q", tag, asset)
		}
	}
	if tag != "" {
		return Release{}, ReleaseAsset{}, fmt.Errorf("GitHub release %q not found", tag)
	}
	return Release{}, ReleaseAsset{}, fmt.Errorf("no GitHub release asset matching %q", asset)
}

// LatestGitHubRelease returns the highest-version release containing asset.
// Prereleases are considered only when allowPrerelease is true.
func LatestGitHubRelease(source, asset string, allowPrerelease bool) (Release, ReleaseAsset, error) {
	asset = strings.TrimSpace(asset)
	if asset == "" {
		return Release{}, ReleaseAsset{}, fmt.Errorf("release asset name is required")
	}

	items, err := FetchGitHubReleases(source, 100)
	if err != nil {
		return Release{}, ReleaseAsset{}, err
	}

	var latest Release
	var latestAsset ReleaseAsset
	for _, release := range items {
		if release.Prerelease && !allowPrerelease {
			continue
		}
		candidate, ok := matchReleaseAsset(release.Assets, asset)
		if !ok {
			continue
		}
		if latest.TagName == "" || releaseGreater(release, latest) {
			latest, latestAsset = release, candidate
		}
	}
	if latest.TagName == "" {
		return Release{}, ReleaseAsset{}, fmt.Errorf("no compatible GitHub release asset matching %q", asset)
	}
	return latest, latestAsset, nil
}

func githubRequest(path, accept string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, strings.TrimRight(githubAPIBaseURL, "/")+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("User-Agent", "ZenPackageManager")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	client := cabundle.Client(15 * time.Second)
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("GitHub request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("GitHub request: %w", httpdiag.ResponseError(resp))
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, githubResponseLimit+1))
	if err != nil {
		return nil, err
	}
	if len(data) > githubResponseLimit {
		return nil, fmt.Errorf("GitHub response is too large")
	}
	return data, nil
}

func NormalizeVersion(value string) string {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "refs/tags/")
	value = strings.TrimLeftFunc(value, func(r rune) bool {
		return r == 'v' || r == 'V' || (!unicode.IsDigit(r) && r != '.')
	})
	return strings.TrimSpace(value)
}

func VersionGreater(a, b string) bool {
	a = NormalizeVersion(a)
	b = NormalizeVersion(b)
	if versionBase(a) == versionBase(b) {
		aPrerelease := strings.Contains(a, "-")
		bPrerelease := strings.Contains(b, "-")
		if aPrerelease != bPrerelease {
			return !aPrerelease
		}
	}
	an := versionNumbers(a)
	bn := versionNumbers(b)
	if len(an) > 0 || len(bn) > 0 {
		max := len(an)
		if len(bn) > max {
			max = len(bn)
		}
		for i := 0; i < max; i++ {
			av, bv := 0, 0
			if i < len(an) {
				av = an[i]
			}
			if i < len(bn) {
				bv = bn[i]
			}
			if av > bv {
				return true
			}
			if av < bv {
				return false
			}
		}
		return false
	}
	return strings.Compare(a, b) > 0
}

func versionBase(value string) string {
	value = NormalizeVersion(value)
	if index := strings.IndexByte(value, '-'); index >= 0 {
		return value[:index]
	}
	return value
}

func releaseGreater(left, right Release) bool {
	if versionBase(left.TagName) == versionBase(right.TagName) {
		if left.Prerelease != right.Prerelease {
			return !left.Prerelease
		}
	}
	return VersionGreater(left.TagName, right.TagName)
}

func versionNumbers(value string) []int {
	var out []int
	start := -1
	for i, r := range value {
		if unicode.IsDigit(r) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			if n, err := strconv.Atoi(value[start:i]); err == nil {
				out = append(out, n)
			}
			start = -1
		}
	}
	if start >= 0 {
		if n, err := strconv.Atoi(value[start:]); err == nil {
			out = append(out, n)
		}
	}
	return out
}
