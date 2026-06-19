package releases

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const githubTimeout = 8 * time.Second

func LatestGitHubReleaseTag(source string) (string, error) {
	api, ok := githubLatestReleaseURL(source)
	if !ok {
		return "", fmt.Errorf("not a github repository URL")
	}
	tag, err := fetchGitHubReleaseTag(api)
	if err == nil && tag != "" {
		return tag, nil
	}
	tagsAPI := strings.TrimSuffix(api, "/releases/latest") + "/tags?per_page=1"
	return fetchGitHubTag(tagsAPI)
}

func githubLatestReleaseURL(source string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(source))
	if err != nil || u.Host == "" {
		return "", false
	}
	host := strings.ToLower(u.Host)
	if host != "github.com" && host != "www.github.com" {
		return "", false
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		return "", false
	}
	repo := strings.TrimSuffix(parts[1], ".git")
	if repo == "" {
		return "", false
	}
	return "https://api.github.com/repos/" + url.PathEscape(parts[0]) + "/" + url.PathEscape(repo) + "/releases/latest", true
}

func fetchGitHubReleaseTag(api string) (string, error) {
	var body struct {
		TagName string `json:"tag_name"`
	}
	if err := fetchJSON(api, &body); err != nil {
		return "", err
	}
	if strings.TrimSpace(body.TagName) == "" {
		return "", fmt.Errorf("latest release had no tag")
	}
	return body.TagName, nil
}

func fetchGitHubTag(api string) (string, error) {
	var body []struct {
		Name string `json:"name"`
	}
	if err := fetchJSON(api, &body); err != nil {
		return "", err
	}
	if len(body) == 0 || strings.TrimSpace(body[0].Name) == "" {
		return "", fmt.Errorf("repository had no tags")
	}
	return body[0].Name, nil
}

func fetchJSON(api string, target interface{}) error {
	client := &http.Client{Timeout: githubTimeout}
	req, err := http.NewRequest(http.MethodGet, api, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "ZenPM")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("github returned HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(target)
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
