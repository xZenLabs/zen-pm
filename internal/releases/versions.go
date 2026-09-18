package releases

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/xZenLabs/zen-pm/internal/cabundle"
	"github.com/xZenLabs/zen-pm/internal/httpdiag"
)

const (
	versionsCacheTTL        = 2 * time.Minute
	versionsCacheMaxEntries = 8
	versionsCacheEntryLimit = 512 * 1024
	versionsFetchAttempts   = 2
	versionsRetryDelay      = 100 * time.Millisecond
)

type versionsCacheEntry struct {
	data      []byte
	expiresAt time.Time
}

var versionsCache = struct {
	sync.Mutex
	entries map[string]versionsCacheEntry
}{entries: make(map[string]versionsCacheEntry)}

// FetchVersions retrieves a repository-generated versions.json document.
func FetchVersions(versionsURL string) ([]Release, error) {
	u, err := url.Parse(strings.TrimSpace(versionsURL))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, fmt.Errorf("versions URL must be an HTTP(S) URL")
	}
	cacheKey := u.String()
	if data, ok := cachedVersions(cacheKey, time.Now()); ok {
		return decodeVersions(data)
	}

	client := cabundle.Client(15 * time.Second)
	var lastErr error
	for attempt := 1; attempt <= versionsFetchAttempts; attempt++ {
		data, items, retry, err := fetchVersionsOnce(client, cacheKey)
		if err == nil {
			if data != nil && len(data) <= versionsCacheEntryLimit {
				cacheVersions(cacheKey, data, time.Now())
			}
			return items, nil
		}
		lastErr = err
		if !retry || attempt == versionsFetchAttempts {
			return nil, err
		}
		time.Sleep(versionsRetryDelay * time.Duration(attempt))
	}
	return nil, lastErr
}

func fetchVersionsOnce(client *http.Client, versionsURL string) ([]byte, []Release, bool, error) {
	req, err := http.NewRequest(http.MethodGet, versionsURL, nil)
	if err != nil {
		return nil, nil, false, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ZenPackageManager")
	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, retryableVersionsError(err), fmt.Errorf("versions request: %w", err)
	}
	if resp.StatusCode == http.StatusNotFound {
		resp.Body.Close()
		return nil, []Release{}, false, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		err := fmt.Errorf("versions request: %w", httpdiag.ResponseError(resp))
		resp.Body.Close()
		return nil, nil, retryableVersionsStatus(resp.StatusCode), err
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, githubResponseLimit+1))
	resp.Body.Close()
	if err != nil {
		return nil, nil, retryableVersionsError(err), fmt.Errorf("versions request: %w", err)
	}
	if len(data) > githubResponseLimit {
		return nil, nil, false, fmt.Errorf("versions response is too large")
	}
	items, err := decodeVersions(data)
	if err != nil {
		return nil, nil, false, err
	}
	return data, items, false, nil
}

func cachedVersions(key string, now time.Time) ([]byte, bool) {
	versionsCache.Lock()
	defer versionsCache.Unlock()
	entry, ok := versionsCache.entries[key]
	if !ok {
		return nil, false
	}
	if !now.Before(entry.expiresAt) {
		delete(versionsCache.entries, key)
		return nil, false
	}
	return append([]byte(nil), entry.data...), true
}

func cacheVersions(key string, data []byte, now time.Time) {
	versionsCache.Lock()
	defer versionsCache.Unlock()

	for cachedKey, entry := range versionsCache.entries {
		if !now.Before(entry.expiresAt) {
			delete(versionsCache.entries, cachedKey)
		}
	}
	if _, exists := versionsCache.entries[key]; !exists && len(versionsCache.entries) >= versionsCacheMaxEntries {
		// ponytail: a tiny reset beats an LRU; use one if release-picker churn becomes measurable.
		clear(versionsCache.entries)
	}
	versionsCache.entries[key] = versionsCacheEntry{
		data:      append([]byte(nil), data...),
		expiresAt: now.Add(versionsCacheTTL),
	}
}

func retryableVersionsStatus(status int) bool {
	return status == http.StatusRequestTimeout || status == http.StatusTooManyRequests || status >= 500 && status <= 599
}

func retryableVersionsError(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && (netErr.Timeout() || netErr.Temporary()) ||
		errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.ErrClosedPipe) ||
		errors.Is(err, net.ErrClosed) || errors.Is(err, syscall.ECONNRESET) ||
		errors.Is(err, syscall.ECONNABORTED) || errors.Is(err, syscall.EPIPE) ||
		errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.EHOSTUNREACH)
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
	items, err := FetchVersions(versionsURL)
	if err != nil {
		return Release{}, ReleaseAsset{}, err
	}
	return FindVersionsAsset(items, tag, asset)
}

// FindVersionsAsset finds an asset in already-fetched versions metadata.
func FindVersionsAsset(items []Release, tag, asset string) (Release, ReleaseAsset, error) {
	tag = strings.TrimSpace(tag)
	asset = strings.TrimSpace(asset)
	if asset == "" {
		return Release{}, ReleaseAsset{}, fmt.Errorf("release asset name is required")
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
