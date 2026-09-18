package releases

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
)

func resetVersionsCacheForTest(t *testing.T) {
	t.Helper()
	clear := func() {
		versionsCache.Lock()
		versionsCache.entries = make(map[string]versionsCacheEntry)
		versionsCache.Unlock()
	}
	clear()
	t.Cleanup(clear)
}

func TestFetchVersionsParsesRepositoryFormat(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{
			"releases": [{
				"tag_name": "v1.39.4",
				"name": "v1.39.4",
				"assets": [{
					"name": "rakuyomi-kindlehf.zip",
					"url": "https://github.com/tachibana-shin/rakuyomi/releases/download/v1.39.4/rakuyomi-kindlehf.zip",
					"size": 13555927,
					"digest": "sha256:9fe424cd22cba0f427c62a2711e34eb5598767dbc5909cc68014adcdc6948716"
				}]
			}]
		}`)
	}))
	defer srv.Close()

	items, err := FetchVersions(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].TagName != "v1.39.4" || len(items[0].Assets) != 1 {
		t.Fatalf("releases = %#v", items)
	}
	asset := items[0].Assets[0]
	if asset.Name != "rakuyomi-kindlehf.zip" || asset.Size != 13555927 || asset.Digest == "" {
		t.Fatalf("asset = %#v", asset)
	}
}

func TestFetchVersionsCachesSuccessfulResponse(t *testing.T) {
	resetVersionsCacheForTest(t)
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		fmt.Fprint(w, `{
			"releases": [{
				"tag_name": "v1.0.0",
				"assets": [{"name": "plugin.zip", "url": "https://example.test/plugin.zip"}]
			}]
		}`)
	}))
	defer srv.Close()

	items, err := FetchVersions(srv.URL + "/versions.json")
	if err != nil {
		t.Fatal(err)
	}
	items[0].Assets[0].Name = "mutated.zip"

	_, asset, err := ResolveVersionsAsset(srv.URL+"/versions.json", "v1.0.0", "plugin.zip")
	if err != nil {
		t.Fatal(err)
	}
	if asset.URL != "https://example.test/plugin.zip" {
		t.Fatalf("asset = %#v", asset)
	}
	if got := requests.Load(); got != 1 {
		t.Fatalf("requests = %d, want 1", got)
	}
}

func TestFetchVersionsRetriesTransientHTTPFailure(t *testing.T) {
	resetVersionsCacheForTest(t)
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			http.Error(w, "try again", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprint(w, `{"releases":[{"tag_name":"v2.0.0","assets":[]}]}`)
	}))
	defer srv.Close()

	items, err := FetchVersions(srv.URL + "/versions.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].TagName != "v2.0.0" {
		t.Fatalf("releases = %#v", items)
	}
	if got := requests.Load(); got != 2 {
		t.Fatalf("requests = %d, want 2", got)
	}
}

func TestFetchVersionsRetriesTruncatedBody(t *testing.T) {
	resetVersionsCacheForTest(t)
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			w.Header().Set("Content-Length", "100")
			fmt.Fprint(w, `{"releases":`)
			return
		}
		fmt.Fprint(w, `{"releases":[{"tag_name":"v3.0.0","assets":[]}]}`)
	}))
	defer srv.Close()

	items, err := FetchVersions(srv.URL + "/versions.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].TagName != "v3.0.0" {
		t.Fatalf("releases = %#v", items)
	}
	if got := requests.Load(); got != 2 {
		t.Fatalf("requests = %d, want 2", got)
	}
}

func TestFetchVersionsDoesNotRetryInvalidResponse(t *testing.T) {
	resetVersionsCacheForTest(t)
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		fmt.Fprint(w, `{"releases":`)
	}))
	defer srv.Close()

	_, err := FetchVersions(srv.URL + "/versions.json")
	if err == nil || !strings.Contains(err.Error(), "decode versions response") {
		t.Fatalf("FetchVersions() error = %v", err)
	}
	if got := requests.Load(); got != 1 {
		t.Fatalf("requests = %d, want 1", got)
	}
}

func TestRetryableVersionsStatus(t *testing.T) {
	for _, status := range []int{http.StatusRequestTimeout, http.StatusTooManyRequests, 500, 503, 599} {
		if !retryableVersionsStatus(status) {
			t.Errorf("status %d was not retryable", status)
		}
	}
	for _, status := range []int{200, 400, 404, 409, 499, 600} {
		if retryableVersionsStatus(status) {
			t.Errorf("status %d was retryable", status)
		}
	}
}

func TestRetryableVersionsErrorIncludesDisconnectedNetwork(t *testing.T) {
	for _, err := range []error{io.ErrUnexpectedEOF, syscall.ECONNRESET, syscall.ENETUNREACH, syscall.EHOSTUNREACH} {
		if !retryableVersionsError(fmt.Errorf("request failed: %w", err)) {
			t.Errorf("retryableVersionsError(%v) = false", err)
		}
	}
}

func TestResolveVersionsAssetMatchesNormalizedTag(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{
			"releases": [{
				"tag_name": "v1.39.4",
				"assets": [{"name": "rakuyomi-kindlehf.zip", "url": "https://example.test/rakuyomi.zip"}]
			}]
		}`)
	}))
	defer srv.Close()

	release, asset, err := ResolveVersionsAsset(
		srv.URL,
		"1.39.4",
		"rakuyomi-kindlehf.zip",
	)
	if err != nil {
		t.Fatal(err)
	}
	if release.TagName != "v1.39.4" || asset.URL != "https://example.test/rakuyomi.zip" {
		t.Fatalf("release = %#v, asset = %#v", release, asset)
	}
}

func TestResolveVersionsAssetMatchesBetaAssetIgnoringVersionAndABIName(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{
			"releases": [{
				"tag_name": "1.2.0-pre",
				"assets": [{"name": "filebrowserplus.koplugin-v1.2.0-pre-linux-armhf.zip", "url": "https://example.test/filebrowserplus.zip"}]
			}]
		}`)
	}))
	defer srv.Close()

	_, asset, err := ResolveVersionsAsset(
		srv.URL,
		"1.2.0-pre",
		"filebrowserplus.koplugin-v1.1.0-linux-armv7.zip",
	)
	if err != nil {
		t.Fatal(err)
	}
	if asset.Name != "filebrowserplus.koplugin-v1.2.0-pre-linux-armhf.zip" {
		t.Fatalf("asset = %#v", asset)
	}
}

func TestMatchReleaseAssetSingleFallbackRejectsIncompatibleBuilds(t *testing.T) {
	for _, tc := range []struct {
		name      string
		wanted    string
		candidate string
		wantOK    bool
	}{
		{"safe renamed arm build", "filebrowserplus-v1.1.0-linux-armv7.zip", "filebrowserplus-beta-kindle-armv7.zip", true},
		{"android for arm device", "filebrowserplus-v1.1.0-linux-armv7.zip", "filebrowserplus-android-armv7.zip", false},
		{"desktop for arm device", "filebrowserplus-v1.1.0-linux-armv7.zip", "filebrowserplus-desktop-x86_64.zip", false},
		{"arm64 for armv7 device", "filebrowserplus-v1.1.0-linux-armv7.zip", "filebrowserplus-linux-arm64.zip", false},
		{"archive for Lua patch", "filebrowserplus.lua", "filebrowserplus.zip", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, ok := matchReleaseAsset([]ReleaseAsset{{Name: tc.candidate}}, tc.wanted)
			if ok != tc.wantOK {
				t.Fatalf("matchReleaseAsset(%q, %q) ok = %t, want %t", tc.candidate, tc.wanted, ok, tc.wantOK)
			}
		})
	}
}

func TestFetchVersionsTreatsMissingOrBlankFileAsEmpty(t *testing.T) {
	for _, status := range []int{http.StatusOK, http.StatusNotFound} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(status)
			}))
			defer srv.Close()

			items, err := FetchVersions(srv.URL)
			if err != nil {
				t.Fatal(err)
			}
			if len(items) != 0 {
				t.Fatalf("releases = %#v", items)
			}
		})
	}
}

func TestFetchVersionsIncludesHTTPFailureDiagnostics(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Server", "test-edge")
		w.Header().Set("X-Request-ID", "req-123")
		w.WriteHeader(http.StatusTooManyRequests)
		fmt.Fprintln(w, "rate limit exhausted")
	}))
	defer srv.Close()

	_, err := FetchVersions(srv.URL + "/versions.json")
	if err == nil {
		t.Fatal("FetchVersions succeeded")
	}
	for _, detail := range []string{
		"HTTP GET " + srv.URL + "/versions.json",
		"429 Too Many Requests",
		`protocol="HTTP/1.1"`,
		`server="test-edge"`,
		`request_id="req-123"`,
		`content_type="text/plain"`,
		`body="rate limit exhausted"`,
	} {
		if !strings.Contains(err.Error(), detail) {
			t.Fatalf("FetchVersions() error = %q, want %q", err, detail)
		}
	}
}
