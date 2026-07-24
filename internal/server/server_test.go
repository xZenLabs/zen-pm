package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xZenLabs/zen-pm/internal/pkg"
	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
)

func TestInitialCatalogStateRefreshesEmptySQLiteCatalog(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)

	catalog, needsRefresh := srv.initialCatalogState()
	if !needsRefresh {
		t.Fatal("empty sqlite catalog did not request initial refresh")
	}
	if catalog != nil {
		t.Fatalf("catalog = %#v, want nil", catalog)
	}
}

func TestInitialCatalogStateUsesExistingCatalog(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:         "pkg",
		Name:       "Package",
		Version:    "1.0.0",
		Repo:       "ZenLabs",
		InstallURL: "install.sh",
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)

	catalog, needsRefresh := srv.initialCatalogState()
	if needsRefresh {
		t.Fatal("existing catalog requested initial refresh")
	}
	if len(catalog) != 1 || catalog[0].ID != "pkg" {
		t.Fatalf("catalog = %#v", catalog)
	}
}

func TestHandlePackageUpdateStartsAllInstalledUpdates(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	rec := httptest.NewRecorder()

	srv.handlePackageUpdate(rec, httptest.NewRequest(http.MethodPost, "/packages/update", nil))

	if rec.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want %d; body=%s", rec.Code, http.StatusAccepted, rec.Body.String())
	}
	var response struct {
		OK      bool `json:"ok"`
		Started bool `json:"started"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || !response.Started {
		t.Fatalf("response = %#v, want started update", response)
	}
}

func TestKindleMaintenanceEndpointsRejectOtherPlatforms(t *testing.T) {
	t.Setenv("ZENPM_PLATFORM", "host")
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)

	for _, path := range []string{"/update", "/uninstall"} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, path, nil)
		if path == "/update" {
			srv.handleUpdate(rec, req)
		} else {
			srv.handleUninstall(rec, req)
		}
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s status = %d, want %d", path, rec.Code, http.StatusBadRequest)
		}
	}
}

func TestPackageListIncludesFeaturedOrder(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	featuredOrder := 10
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "ZenLabs", InstallURL: "install.sh",
		Platforms: []string{"host"}, Featured: true, FeaturedOrder: &featuredOrder,
		ReadmeURL: "https://repo.zen-labs.org/packages/host/pkg/README.md",
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	req := httptest.NewRequest(http.MethodGet, "/packages?platform=host", nil)
	rec := httptest.NewRecorder()
	srv.handlePackageList(rec, req)

	var packages []pkgJSON
	if err := json.Unmarshal(rec.Body.Bytes(), &packages); err != nil {
		t.Fatal(err)
	}
	if len(packages) != 1 || packages[0].FeaturedOrder == nil || *packages[0].FeaturedOrder != featuredOrder {
		t.Fatalf("packages = %#v", packages)
	}
	if packages[0].ReadmeURL != "https://repo.zen-labs.org/packages/host/pkg/README.md" {
		t.Fatalf("ReadmeURL = %q", packages[0].ReadmeURL)
	}
}

func TestPackageListIncludesInstalledAsset(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.1.0", Repo: "ZenLabs", InstallURL: "install.sh", Platforms: []string{"host"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "ZenLabs", Asset: "pkg-armv7.zip", InstalledAt: "2026-07-24T12:00:00Z",
	}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	req := httptest.NewRequest(http.MethodGet, "/packages?platform=host", nil)
	rec := httptest.NewRecorder()
	srv.handlePackageList(rec, req)

	var packages []pkgJSON
	if err := json.Unmarshal(rec.Body.Bytes(), &packages); err != nil {
		t.Fatal(err)
	}
	if len(packages) != 1 || packages[0].InstalledAsset != "pkg-armv7.zip" || packages[0].InstalledAt != "2026-07-24T12:00:00Z" {
		t.Fatalf("packages = %#v", packages)
	}
}

func TestPackageListIncludesConflicts(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "patch", Name: "Patch", Version: "1.0.0", Repo: "ZenLabs", InstallURL: "install.sh", Platforms: []string{"host"}, IncompatiblePlatforms: []string{"android"}, Conflicts: []string{"zen-ui"},
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	req := httptest.NewRequest(http.MethodGet, "/packages?platform=host", nil)
	rec := httptest.NewRecorder()
	srv.handlePackageList(rec, req)

	var packages []pkgJSON
	if err := json.Unmarshal(rec.Body.Bytes(), &packages); err != nil {
		t.Fatal(err)
	}
	if len(packages) != 1 || len(packages[0].IncompatiblePlatforms) != 1 || packages[0].IncompatiblePlatforms[0] != "android" || len(packages[0].Conflicts) != 1 || packages[0].Conflicts[0] != "zen-ui" {
		t.Fatalf("packages = %#v", packages)
	}
}

func TestApplyUpdateInfoRequiresKnownInstalledVersion(t *testing.T) {
	for _, installedVersion := range []string{"", "0.0.0", "v0.0.0"} {
		item := pkgJSON{Version: "1.2.0", InstalledVer: installedVersion}
		applyUpdateInfo(&item, false)
		if item.UpdateAvail {
			t.Errorf("installed version %q marked update available", installedVersion)
		}
	}

	item := pkgJSON{Version: "1.2.0", InstalledVer: "1.1.0"}
	applyUpdateInfo(&item, false)
	if !item.UpdateAvail {
		t.Fatal("known older installed version was not marked update available")
	}
}

func TestPackageListIncludesUnmanagedKOReaderPatch(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	root := filepath.Join(t.TempDir(), "koreader")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_DIR", root)
	if err := os.MkdirAll(filepath.Join(root, "patches"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "patches", "legacy.lua.disabled"), nil, 0644); err != nil {
		t.Fatal(err)
	}

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "ZenLabs", InstallURL: "install.sh", Platforms: []string{"koreader"},
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	req := httptest.NewRequest(http.MethodGet, "/packages?platform=koreader", nil)
	rec := httptest.NewRecorder()
	srv.handlePackageList(rec, req)

	var packages []pkgJSON
	if err := json.Unmarshal(rec.Body.Bytes(), &packages); err != nil {
		t.Fatal(err)
	}
	for _, item := range packages {
		if item.UnmanagedPatch {
			if item.ID != "local-patch:legacy.lua" || item.Name != "legacy.lua" || len(item.InstalledAssets) != 1 || item.InstalledAssets[0] != "legacy.lua" {
				t.Fatalf("unmanaged patch item = %#v", item)
			}
			return
		}
	}
	t.Fatalf("unmanaged patch missing from %#v", packages)
}

func TestKOReaderPluginScanEndpoint(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	if err := os.MkdirAll(filepath.Join(plugins, "reader.koplugin"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(plugins, "reader.koplugin", "_meta.lua"), []byte(`return { version = "1.2.3" }`), 0644); err != nil {
		t.Fatal(err)
	}

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "reader", Name: "Reader", Version: "9.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "reader",
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	req := httptest.NewRequest(http.MethodPost, "/koreader/plugins/scan", nil)
	rec := httptest.NewRecorder()
	srv.handleKOReaderPluginScan(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response struct {
		OK      bool `json:"ok"`
		Scanned int  `json:"scanned"`
		Matched int  `json:"matched"`
		Added   int  `json:"added"`
		Updated int  `json:"updated"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || response.Scanned != 1 || response.Matched != 1 || response.Added != 1 || response.Updated != 0 {
		t.Fatalf("response = %+v", response)
	}
}

func TestInitialCatalogStateRefreshesStaleCatalog(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "ZenLabs", InstallURL: "install.sh",
	}}); err != nil {
		t.Fatal(err)
	}
	// Stamp a refresh marker dated well past the staleness window.
	marker := filepath.Join(st.CacheDir, "catalog.refreshed")
	if err := os.WriteFile(marker, []byte("old"), 0644); err != nil {
		t.Fatal(err)
	}
	stale := time.Now().Add(-catalogMaxAge - time.Hour)
	if err := os.Chtimes(marker, stale, stale); err != nil {
		t.Fatal(err)
	}

	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)

	catalog, needsRefresh := srv.initialCatalogState()
	if !needsRefresh {
		t.Fatal("stale catalog did not request refresh")
	}
	if len(catalog) != 1 {
		t.Fatalf("catalog = %#v, want existing entry returned alongside refresh", catalog)
	}
}

func TestHandlePackageActionReturnsPreflightInstallErrors(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:         "reader",
		Name:       "Reader",
		Version:    "1.0.0",
		Repo:       "ZenLabs",
		Deps:       []string{"missing"},
		InstallURL: "install.sh",
	}}); err != nil {
		t.Fatal(err)
	}

	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)

	req := httptest.NewRequest(http.MethodPost, "/packages/reader/install", nil)
	rec := httptest.NewRecorder()
	srv.handlePackageAction(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want %d; body=%s", rec.Code, http.StatusConflict, rec.Body.String())
	}
	if body := rec.Body.String(); !strings.Contains(body, "unknown dependency") {
		t.Fatalf("body = %q, want dependency error", body)
	}
}

func TestPackageGitHubSourceUsesCatalogMetadata(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{
		{ID: "reader", Name: "Reader", Repo: "ZenLabs", Source: "https://github.com/owner/reader"},
		{ID: "other", Name: "Other", Repo: "ZenLabs", Source: "https://example.com/other"},
	}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)

	source, err := srv.packageGitHubSource("reader")
	if err != nil {
		t.Fatal(err)
	}
	if source != "https://github.com/owner/reader" {
		t.Fatalf("source = %q", source)
	}
	if _, err := srv.packageGitHubSource("other"); err == nil {
		t.Fatal("non-GitHub package returned no error")
	}
}

func TestPackageReadmeURLPrefersHostedCatalogMetadata(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "reader", Name: "Reader", Repo: "ZenLabs", Source: "https://github.com/owner/reader",
		ReadmeURL: "https://repo.zen-labs.org/packages/koreader/reader/README.md",
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)

	readmeURL, imageBaseURL, err := srv.packageReadmeMetadata("reader")
	if err != nil {
		t.Fatal(err)
	}
	if readmeURL != "https://repo.zen-labs.org/packages/koreader/reader/README.md" || imageBaseURL != "https://github.com/owner/reader/raw/HEAD/" {
		t.Fatalf("packageReadmeMetadata() = %q, %q", readmeURL, imageBaseURL)
	}
}

func TestPackageReadmeURLRequiresHostedMetadata(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "reader", Name: "Reader", Repo: "ZenLabs", Source: "https://github.com/owner/reader",
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	if _, _, err := srv.packageReadmeMetadata("reader"); err == nil || !strings.Contains(err.Error(), "no README URL") {
		t.Fatalf("packageReadmeMetadata() error = %v", err)
	}
}

func TestHandlePackageReadmeReturnsMarkdownAndBaseURL(t *testing.T) {
	readmeServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/README.md" {
			http.Redirect(w, r, "/docs/README.md", http.StatusFound)
			return
		}
		if r.URL.Path != "/docs/README.md" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte("# Reader\n\n![Logo](logo.png)"))
	}))
	defer readmeServer.Close()

	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "reader", Name: "Reader", Repo: "ZenLabs", Source: "https://github.com/owner/reader", ReadmeURL: readmeServer.URL + "/README.md",
	}}); err != nil {
		t.Fatal(err)
	}
	srv := New(st, repo.New(st), pkg.New(st, repo.New(st), "host"), 0)
	rec := httptest.NewRecorder()
	srv.handlePackageReadme(rec, httptest.NewRequest(http.MethodGet, "/packages/reader/readme", nil), "reader")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response struct {
		Readme        string `json:"readme"`
		ReadmeBaseURL string `json:"readme_base_url"`
		ImageBaseURL  string `json:"readme_image_base_url"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Readme != "# Reader\n\n![Logo](logo.png)" || response.ReadmeBaseURL != readmeServer.URL+"/docs/" || response.ImageBaseURL != "https://github.com/owner/reader/raw/HEAD/" {
		t.Fatalf("response = %#v", response)
	}
}

func TestShouldLogAccessSkipsRoutineSuccessfulPolling(t *testing.T) {
	tests := []struct {
		method string
		target string
		status int
		want   bool
	}{
		{http.MethodGet, "/health", http.StatusOK, false},
		{http.MethodGet, "/packages?platform=kindle", http.StatusOK, false},
		{http.MethodGet, "/log?tail=500", http.StatusOK, false},
		{http.MethodGet, "/repos", http.StatusOK, false},
		{http.MethodGet, "/packages?platform=kindle", http.StatusInternalServerError, true},
		{http.MethodPost, "/packages/reader/uninstall", http.StatusAccepted, true},
		{http.MethodGet, "/packages/reader/assets", http.StatusOK, true},
	}

	for _, tt := range tests {
		req := httptest.NewRequest(tt.method, tt.target, nil)
		if got := shouldLogAccess(req, tt.status); got != tt.want {
			t.Fatalf("shouldLogAccess(%s %s, %d) = %v, want %v", tt.method, tt.target, tt.status, got, tt.want)
		}
	}
}

func TestShouldLogClientMessageKeepsImportantWAFLogs(t *testing.T) {
	tests := map[string]bool{
		"[home] script loaded":                                   false,
		"[package-card] id=reader imageSrc=icon.svg":             false,
		"[waf] package action request: POST /packages/a/install": true,
		"[details] uninstall started for reader":                 true,
		"[sources.js] JS ERROR: boom":                            true,
		"[installed] Daemon unreachable after 5 retries":         true,
	}

	for message, want := range tests {
		if got := shouldLogClientMessage(message); got != want {
			t.Fatalf("shouldLogClientMessage(%q) = %v, want %v", message, got, want)
		}
	}
}
