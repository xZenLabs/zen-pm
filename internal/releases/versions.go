package releases

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/xZenLabs/zen-pm/internal/cabundle"
	"github.com/xZenLabs/zen-pm/internal/httpdiag"
)

// FetchVersions retrieves a repository-generated versions.json document.
func FetchVersions(versionsURL string) ([]Release, error) {
	u, err := url.Parse(strings.TrimSpace(versionsURL))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, fmt.Errorf("versions URL must be an HTTP(S) URL")
	}
	req, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ZenPackageManager")
	resp, err := cabundle.Client(15 * time.Second).Do(req)
	if err != nil {
		return nil, fmt.Errorf("versions request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return []Release{}, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("versions request: %w", httpdiag.ResponseError(resp))
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, githubResponseLimit+1))
	if err != nil {
		return nil, err
	}
	if len(data) > githubResponseLimit {
		return nil, fmt.Errorf("versions response is too large")
	}
	return decodeVersions(data)
}

func decodeVersions(data []byte) ([]Release, error) {
	if strings.TrimSpace(string(data)) == "" {
		return []Release{}, nil
	}
	var document struct {
		Releases []Release `json:"releases"`
	}
	if err := json.Unmarshal(data, &document); err != nil {
		return nil, fmt.Errorf("decode versions response: %w", err)
	}
	return document.Releases, nil
}

// ResolveVersionsAsset finds an asset in a repository-generated versions file.
func ResolveVersionsAsset(versionsURL, tag, asset string) (Release, ReleaseAsset, error) {
	tag = strings.TrimSpace(tag)
	asset = strings.TrimSpace(asset)
	if asset == "" {
		return Release{}, ReleaseAsset{}, fmt.Errorf("release asset name is required")
	}
	items, err := FetchVersions(versionsURL)
	if err != nil {
		return Release{}, ReleaseAsset{}, err
	}
	for _, release := range items {
		if tag != "" && release.TagName != tag && NormalizeVersion(release.TagName) != NormalizeVersion(tag) {
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
		return Release{}, ReleaseAsset{}, fmt.Errorf("release %q not found", tag)
	}
	return Release{}, ReleaseAsset{}, fmt.Errorf("no release asset matching %q", asset)
}
