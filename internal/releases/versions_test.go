package releases

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

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
