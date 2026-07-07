package releases

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGitHubRepository(t *testing.T) {
	tests := map[string]string{
		"https://github.com/owner/repo":      "owner/repo",
		"https://github.com/owner/repo.git/": "owner/repo",
		"ftp://github.com/owner/repo":        "",
		"https://example.com/owner/repo":     "",
		"https://github.com/owner":           "",
	}
	for source, want := range tests {
		got, ok := GitHubRepository(source)
		if got != want || ok != (want != "") {
			t.Fatalf("GitHubRepository(%q) = %q, %v; want %q, %v", source, got, ok, want, want != "")
		}
	}
}

func TestFetchGitHubMetadata(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.RequestURI() {
		case "/repos/owner/repo/readme":
			if got := r.Header.Get("Accept"); got != "application/vnd.github.raw+json" {
				t.Fatalf("README Accept = %q", got)
			}
			fmt.Fprint(w, "# Reader\n\nHello.")
		case "/repos/owner/repo/releases?per_page=2&page=1":
			fmt.Fprint(w, `[
				{"tag_name":"v2.0","name":"Two","draft":false,"assets":[
					{"name":"plugin.zip","browser_download_url":"https://example.test/plugin.zip"},
					{"name":"notes.txt","browser_download_url":"https://example.test/notes.txt"}
				]},
				{"tag_name":"v1.0","name":"One","draft":true,"assets":[
					{"name":"old.zip","browser_download_url":"https://example.test/old.zip"}
				]}
			]`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	oldBase := githubAPIBaseURL
	githubAPIBaseURL = srv.URL
	t.Cleanup(func() { githubAPIBaseURL = oldBase })

	readme, err := FetchGitHubReadme("https://github.com/owner/repo")
	if err != nil {
		t.Fatal(err)
	}
	if readme != "# Reader\n\nHello." {
		t.Fatalf("README = %q", readme)
	}

	got, hasMore, err := FetchGitHubReleases("https://github.com/owner/repo", 1, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].TagName != "v2.0" || len(got[0].Assets) != 1 || got[0].Assets[0].Name != "plugin.zip" {
		t.Fatalf("releases = %#v", got)
	}
	if !hasMore {
		t.Fatalf("hasMore = false, want true (2 items returned for per_page=2)")
	}
}

func TestGitHubReleaseURL(t *testing.T) {
	got, err := GitHubReleaseURL("https://github.com/owner/repo", "v1.2.0")
	if err != nil {
		t.Fatal(err)
	}
	if got != "https://github.com/owner/repo/releases/tag/v1.2.0" {
		t.Fatalf("release URL = %q", got)
	}
}
