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
)

const githubResponseLimit = 512 * 1024

var githubAPIBaseURL = "https://api.github.com"

type ReleaseAsset struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

type Release struct {
	TagName    string         `json:"tag_name"`
	Name       string         `json:"name,omitempty"`
	Prerelease bool           `json:"prerelease,omitempty"`
	Assets     []ReleaseAsset `json:"assets"`
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

func FetchGitHubReadme(source string) (string, error) {
	repository, ok := GitHubRepository(source)
	if !ok {
		return "", fmt.Errorf("source is not a GitHub repository")
	}
	data, err := githubRequest("/repos/"+repository+"/readme", "application/vnd.github.raw+json")
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func FetchGitHubReleases(source string, limit int) ([]Release, error) {
	repository, ok := GitHubRepository(source)
	if !ok {
		return nil, fmt.Errorf("source is not a GitHub repository")
	}
	if limit < 1 {
		limit = 10
	}
	if limit > 30 {
		limit = 30
	}
	data, err := githubRequest("/repos/"+repository+"/releases?per_page="+strconv.Itoa(limit), "application/vnd.github+json")
	if err != nil {
		return nil, err
	}
	var response []struct {
		TagName    string `json:"tag_name"`
		Name       string `json:"name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
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
				release.Assets = append(release.Assets, ReleaseAsset{Name: asset.Name, URL: asset.URL})
			}
		}
		if len(release.Assets) > 0 {
			out = append(out, release)
		}
	}
	return out, nil
}

func githubRequest(path, accept string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, strings.TrimRight(githubAPIBaseURL, "/")+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("User-Agent", "ZenPackageManager")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("GitHub request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("GitHub request returned %s", resp.Status)
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
