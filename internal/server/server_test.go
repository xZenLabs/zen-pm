package server

import (
	"bufio"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xZenLabs/zen-pm/internal/log"
	"github.com/xZenLabs/zen-pm/internal/pkg"
	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
)

type fakeReadmeImagePreparer struct {
	refs     map[string]string
	markdown string
	baseURL  string
	started  chan struct{}
	release  chan struct{}
	finished chan struct{}
}

func (f *fakeReadmeImagePreparer) References(markdown, baseURL string) map[string]string {
	f.markdown = markdown
	f.baseURL = baseURL
	return f.refs
}

func (f *fakeReadmeImagePreparer) Prepare(refs map[string]string) error {
	close(f.started)
	<-f.release
	close(f.finished)
	return nil
}

func TestListenUnixBindsSocket(t *testing.T) {
	path := filepath.Join(t.TempDir(), "zenpm.sock")
	srv := &Server{}
	ln, err := srv.listenUnix(path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
}

func TestListenAndServeUnixServesHealth(t *testing.T) {
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
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	socketFile, err := os.CreateTemp("", "zenpm-*.sock")
	if err != nil {
		t.Fatal(err)
	}
	path := socketFile.Name()
	if err := socketFile.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.ListenAndServeUnix(path) }()

	var conn net.Conn
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		conn, err = net.DialTimeout("unix", path, 50*time.Millisecond)
		if err == nil {
			break
		}
	}
	if conn == nil {
		t.Fatalf("dial Unix socket: %v", err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n")); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodGet})
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusOK)
	}
	response.Body.Close()

	if err := srv.Close(); err != nil {
		t.Fatal(err)
	}
	if err := <-serveErr; err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("socket remains after shutdown: %v", err)
	}
}

func TestServerStopsWhenIdle(t *testing.T) {
	srv := New(nil, nil, nil, 0)
	srv.IdleTimeout = 25 * time.Millisecond
	srv.touch()
	go srv.stopWhenIdle()

	select {
	case <-srv.done:
	case <-time.After(time.Second):
		t.Fatal("idle server did not stop")
	}
}

func TestServerIdleTimeoutWaitsForBackgroundWork(t *testing.T) {
	srv := New(nil, nil, nil, 0)
	srv.IdleTimeout = 25 * time.Millisecond
	srv.touch()
	srv.backgroundJobs.Add(1)
	go srv.stopWhenIdle()

	select {
	case <-srv.done:
		t.Fatal("server stopped while background work was active")
	case <-time.After(100 * time.Millisecond):
	}

	srv.backgroundJobs.Add(-1)
	srv.touch()
	select {
	case <-srv.done:
	case <-time.After(time.Second):
		t.Fatal("server did not stop after background work completed")
	}
}

func TestWrapAllowsUnixSocketRequest(t *testing.T) {
	srv := &Server{unixSocket: true}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.RemoteAddr = "@"

	srv.wrap(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusNoContent)
	}
}

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

func TestInitialCatalogStateRefreshesCatalogMissingPublicationDates(t *testing.T) {
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
	if err := st.WriteValue(state.CatalogPublishedAtRefreshKey, "1"); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)

	catalog, needsRefresh := srv.initialCatalogState()
	if !needsRefresh || len(catalog) != 1 {
		t.Fatalf("catalog = %#v, needsRefresh = %t", catalog, needsRefresh)
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
		ReadmeURL: "https://repo.zen-labs.org/packages/host/pkg/README.md", VersionsURL: "https://repo.zen-labs.org/packages/host/pkg/versions.json", ReleaseNotesURL: "https://repo.zen-labs.org/packages/host/pkg/RELEASE_NOTES.md",
		PrereleaseNotesURL: "https://repo.zen-labs.org/packages/host/pkg/PRERELEASE_NOTES.md", PrereleaseVersion: "1.1.0-rc.1", PublishedAt: "2026-07-24T12:00:00Z",
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
	if packages[0].VersionsURL != "https://repo.zen-labs.org/packages/host/pkg/versions.json" {
		t.Fatalf("VersionsURL = %q", packages[0].VersionsURL)
	}
	if packages[0].ReleaseNotesURL != "https://repo.zen-labs.org/packages/host/pkg/RELEASE_NOTES.md" || packages[0].PrereleaseNotesURL != "https://repo.zen-labs.org/packages/host/pkg/PRERELEASE_NOTES.md" || packages[0].PrereleaseVersion != "1.1.0-rc.1" {
		t.Fatalf("release notes metadata = %#v", packages[0])
	}
	if packages[0].PublishedAt != "2026-07-24T12:00:00Z" {
		t.Fatalf("PublishedAt = %q", packages[0].PublishedAt)
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
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "ZenLabs", Asset: "pkg-armv7.zip", UpdateIgnored: true, InstalledAt: "2026-07-24T12:00:00Z",
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
	if len(packages) != 1 || packages[0].InstalledAsset != "pkg-armv7.zip" || packages[0].InstalledAt != "2026-07-24T12:00:00Z" || !packages[0].UpdateIgnored || !packages[0].UpdateAvail || packages[0].LatestVersion != "1.1.0" {
		t.Fatalf("packages = %#v", packages)
	}
}

func TestPackageUpdateIgnoredStoresInstalledPackagePreference(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}
	srv := New(st, nil, nil, 0)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/packages/pkg/update-ignored", strings.NewReader(`{"update_ignored":true}`))
	srv.handlePackageAction(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || !installed[0].UpdateIgnored {
		t.Fatalf("installed = %#v, %v", installed, err)
	}
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/packages/pkg/update-ignored", strings.NewReader(`{"update_ignored":false,"update_ignored_version":"1.1.0"}`))
	srv.handlePackageAction(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	installed, err = st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].UpdateIgnored || installed[0].UpdateIgnoredVersion != "1.1.0" {
		t.Fatalf("installed after version preference = %#v, %v", installed, err)
	}
}

func TestPackageListIgnoresOnlySelectedUpdateVersion(t *testing.T) {
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
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "ZenLabs", UpdateIgnoredVersion: "1.1.0",
	}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	list := func() pkgJSON {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/packages?platform=host", nil)
		srv.handlePackageList(rec, req)
		var packages []pkgJSON
		if err := json.Unmarshal(rec.Body.Bytes(), &packages); err != nil {
			t.Fatal(err)
		}
		if len(packages) != 1 {
			t.Fatalf("packages = %#v", packages)
		}
		return packages[0]
	}
	if item := list(); !item.UpdateAvail || !item.UpdateIgnored || item.LatestVersion != "1.1.0" {
		t.Fatalf("ignored version item = %#v", item)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.2.0", Repo: "ZenLabs", InstallURL: "install.sh", Platforms: []string{"host"},
	}}); err != nil {
		t.Fatal(err)
	}
	if item := list(); !item.UpdateAvail || item.UpdateIgnored || item.LatestVersion != "1.2.0" {
		t.Fatalf("next version item = %#v", item)
	}
}

func TestPackageListIncludesInstalledPackageMissingFromCatalog(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "catalog-plugin", Name: "Catalog Plugin", Version: "1.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "local-plugin", Name: "local-plugin", Version: "2.3.4",
	}); err != nil {
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
		if item.ID == "local-plugin" {
			if !item.Installed || item.Name != "local-plugin" || item.InstalledVer != "2.3.4" ||
				len(item.Platforms) != 1 || item.Platforms[0] != "koreader" {
				t.Fatalf("unmatched installed plugin = %#v", item)
			}
			return
		}
	}
	t.Fatalf("unmatched installed plugin missing from %#v", packages)
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
	if !item.UpdateAvail || item.LatestRelease != "1.2.0" {
		t.Fatalf("update info = %#v", item)
	}
}

func TestApplyUpdateInfoIgnoresTagCommitSuffixForSameRelease(t *testing.T) {
	item := pkgJSON{
		Version:      "v1.0.41-7779138817115c22c74fe1c0630436b1f0fb63ff",
		InstalledVer: "1.0.41",
	}
	applyUpdateInfo(&item, false)
	if item.UpdateAvail || item.LatestRelease != "" {
		t.Fatalf("update info = %#v", item)
	}
}

func TestApplyUpdateInfoOffersNewerPrerelease(t *testing.T) {
	for _, versions := range [][2]string{
		{"1.0.0-alpha2", "1.0.0-alpha1"},
		{"1.0.0-beta2", "1.0.0-beta1"},
		{"1.0.0-rc2", "1.0.0-rc1"},
	} {
		item := pkgJSON{Version: versions[0], InstalledVer: versions[1]}
		applyUpdateInfo(&item, false)
		if !item.UpdateAvail || item.LatestRelease != versions[0] {
			t.Errorf("latest %q, installed %q: update info = %#v", versions[0], versions[1], item)
		}
	}
}

func TestApplyUpdateInfoDoesNotOfferSameVersionPrereleaseToStableInstall(t *testing.T) {
	item := pkgJSON{Version: "2.5.4-beta2", InstalledVer: "2.5.4"}
	applyUpdateInfo(&item, true)
	if item.UpdateAvail {
		t.Fatalf("update info = %#v, want no update", item)
	}
}

func TestApplyUpdateInfoUsesNewerCatalogPrerelease(t *testing.T) {
	item := pkgJSON{Version: "1.2.0", PrereleaseVersion: "1.3.0-beta.1", InstalledVer: "1.2.0"}
	applyUpdateInfo(&item, true)
	if !item.UpdateAvail || item.LatestVersion != "1.3.0-beta.1" || item.LatestRelease != "1.3.0-beta.1" {
		t.Fatalf("update info = %#v", item)
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

func TestHandlePackageReleasesWithoutVersionsURLReturnsEmpty(t *testing.T) {
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

	rec := httptest.NewRecorder()
	srv.handlePackageReleases(rec, httptest.NewRequest(http.MethodGet, "/packages/reader/releases", nil), "reader")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response struct {
		Releases []json.RawMessage `json:"releases"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Releases) != 0 {
		t.Fatalf("response = %#v", response)
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

func TestHandlePackageReleasesUsesVersionsURL(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	versionsServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{
			"releases": [{
				"tag_name": "v1.39.4",
				"assets": [{
					"name": "rakuyomi-kindlehf.zip",
					"url": "https://github.com/tachibana-shin/rakuyomi/releases/download/v1.39.4/rakuyomi-kindlehf.zip",
					"size": 13555927,
					"digest": "sha256:9fe424cd22cba0f427c62a2711e34eb5598767dbc5909cc68014adcdc6948716"
				}]
			}]
		}`))
	}))
	defer versionsServer.Close()

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:          "rakuyomi",
		Name:        "Rakuyomi",
		Repo:        "ZenLabs",
		Source:      "https://github.com/tachibana-shin/rakuyomi",
		VersionsURL: versionsServer.URL,
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	rec := httptest.NewRecorder()
	srv.handlePackageReleases(rec, httptest.NewRequest(http.MethodGet, "/packages/rakuyomi/releases", nil), "rakuyomi")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response struct {
		Releases []struct {
			TagName string `json:"tag_name"`
			Assets  []struct {
				Name string `json:"name"`
			} `json:"assets"`
		} `json:"releases"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Releases) != 1 || response.Releases[0].TagName != "v1.39.4" || len(response.Releases[0].Assets) != 1 || response.Releases[0].Assets[0].Name != "rakuyomi-kindlehf.zip" {
		t.Fatalf("response = %#v", response)
	}
}

func TestHandlePackageReleasesUsesSourceAssetsFromVersionsURL(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	versionsServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"releases":[
			{"tag_name":"v0.2.3","name":"v0.2.3","assets":[{"name":"source-code.zip","url":"https://api.github.com/repos/Ko-Insight/KoInsight/zipball/v0.2.3"}]},
			{"tag_name":"v0.2.2","name":"v0.2.2","assets":[]}
		]}`))
	}))
	defer versionsServer.Close()

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "koinsight", Name: "KoInsight", Repo: "ZenLabs",
		SourceType: "source", SourceURL: "https://codeload.github.com/Ko-Insight/KoInsight/zip/refs/heads/master",
		VersionsURL: versionsServer.URL,
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	rec := httptest.NewRecorder()
	srv.handlePackageReleases(rec, httptest.NewRequest(http.MethodGet, "/packages/koinsight/releases", nil), "koinsight")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response struct {
		Releases []struct {
			TagName string `json:"tag_name"`
			Assets  []struct {
				Name string `json:"name"`
				URL  string `json:"url"`
			} `json:"assets"`
		} `json:"releases"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Releases) != 1 || response.Releases[0].TagName != "v0.2.3" || len(response.Releases[0].Assets) != 1 {
		t.Fatalf("response = %#v", response)
	}
	asset := response.Releases[0].Assets[0]
	if asset.Name != "source-code.zip" || asset.URL != "https://api.github.com/repos/Ko-Insight/KoInsight/zipball/v0.2.3" {
		t.Fatalf("source asset = %#v", asset)
	}
}

func TestHandlePackageReleasesHidesCompatibilityAssetBesideCanonicalAsset(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	versionsServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"releases":[
			{"tag_name":"v3.0.0","assets":[
				{"name":"zenos.koplugin.zip","url":"https://example.com/zenos.zip"},
				{"name":"zen_ui.koplugin.zip","url":"https://example.com/zen-ui.zip"}
			]},
			{"tag_name":"v2.5.4","assets":[
				{"name":"zen_ui.koplugin.zip","url":"https://example.com/zen-ui-old.zip"}
			]}
		]}`))
	}))
	defer versionsServer.Close()

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", VersionsURL: versionsServer.URL,
		SourceType: "release", SourceAsset: "zenos.koplugin.zip",
		SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	repos := repo.New(st)
	srv := New(st, repos, pkg.New(st, repos, "host"), 0)
	rec := httptest.NewRecorder()
	srv.handlePackageReleases(rec, httptest.NewRequest(http.MethodGet, "/packages/zen-ui/releases", nil), "zen-ui")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response struct {
		Releases []struct {
			Assets []struct {
				Name string `json:"name"`
			} `json:"assets"`
		} `json:"releases"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Releases) != 2 || len(response.Releases[0].Assets) != 1 || response.Releases[0].Assets[0].Name != "zenos.koplugin.zip" {
		t.Fatalf("canonical release assets = %#v", response.Releases)
	}
	if len(response.Releases[1].Assets) != 1 || response.Releases[1].Assets[0].Name != "zen_ui.koplugin.zip" {
		t.Fatalf("legacy-only release assets = %#v", response.Releases)
	}

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", VersionsURL: versionsServer.URL,
		SourceType: "release", SourceAsset: "zen_ui.koplugin.zip",
		SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	rec = httptest.NewRecorder()
	srv.handlePackageReleases(rec, httptest.NewRequest(http.MethodGet, "/packages/zen-ui/releases", nil), "zen-ui")
	if rec.Code != http.StatusOK {
		t.Fatalf("legacy source status = %d, body = %s", rec.Code, rec.Body.String())
	}
	response.Releases = nil
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Releases) != 2 || len(response.Releases[1].Assets) != 1 || response.Releases[1].Assets[0].Name != "zen_ui.koplugin.zip" {
		t.Fatalf("current legacy source asset was hidden = %#v", response.Releases)
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
	imageURL := "https://github.com/owner/reader/raw/HEAD/logo.png"
	imageRef := filepath.Join(st.CacheDir, "readme-images", "logo.ref")
	preparer := &fakeReadmeImagePreparer{
		refs:     map[string]string{imageURL: imageRef},
		started:  make(chan struct{}),
		release:  make(chan struct{}),
		finished: make(chan struct{}),
	}
	srv.readmeImages = preparer
	rec := httptest.NewRecorder()
	srv.handlePackageReadme(rec, httptest.NewRequest(http.MethodGet, "/packages/reader/readme", nil), "reader")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response struct {
		Readme        string            `json:"readme"`
		ReadmeBaseURL string            `json:"readme_base_url"`
		ImageBaseURL  string            `json:"readme_image_base_url"`
		ImageRefs     map[string]string `json:"readme_image_refs"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Readme != "# Reader\n\n![Logo](logo.png)" || response.ReadmeBaseURL != readmeServer.URL+"/docs/" || response.ImageBaseURL != "https://github.com/owner/reader/raw/HEAD/" {
		t.Fatalf("response = %#v", response)
	}
	if response.ImageRefs[imageURL] != imageRef || preparer.markdown != response.Readme || preparer.baseURL != response.ImageBaseURL {
		t.Fatalf("image preparation metadata = %#v / %#v", response.ImageRefs, preparer)
	}
	select {
	case <-preparer.started:
	case <-time.After(time.Second):
		t.Fatal("README image preparation did not start")
	}
	close(preparer.release)
	select {
	case <-preparer.finished:
	case <-time.After(time.Second):
		t.Fatal("README image preparation did not finish")
	}
}

func TestHandlePackageReleaseNotesSelectsPrereleaseDocument(t *testing.T) {
	notesServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/RELEASE_NOTES.md":
			_, _ = w.Write([]byte("# Stable"))
		case "/PRERELEASE_NOTES.md":
			_, _ = w.Write([]byte("# Preview"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer notesServer.Close()

	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "reader", Name: "Reader", Version: "1.0.0", Repo: "ZenLabs", Source: "https://github.com/owner/reader",
		ReleaseNotesURL: notesServer.URL + "/RELEASE_NOTES.md", PrereleaseNotesURL: notesServer.URL + "/PRERELEASE_NOTES.md",
		PrereleaseVersion: "1.1.0-rc.1",
	}}); err != nil {
		t.Fatal(err)
	}
	srv := New(st, repo.New(st), pkg.New(st, repo.New(st), "host"), 0)
	stableURL, _, stableVersion, err := srv.packageReleaseNotesMetadata("reader", false)
	if err != nil {
		t.Fatal(err)
	}
	if stableURL != notesServer.URL+"/RELEASE_NOTES.md" || stableVersion != "1.0.0" {
		t.Fatalf("stable metadata = %q / %q", stableURL, stableVersion)
	}
	rec := httptest.NewRecorder()
	srv.handlePackageReleaseNotes(rec, httptest.NewRequest(http.MethodGet, "/packages/reader/release-notes?prerelease=1", nil), "reader")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response struct {
		ReleaseNotes string `json:"release_notes"`
		Version      string `json:"version"`
		BaseURL      string `json:"release_notes_base_url"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.ReleaseNotes != "# Preview" || response.Version != "1.1.0-rc.1" || response.BaseURL != notesServer.URL+"/" {
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

func TestWrapLogsHTTPErrorDetail(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "zenpm.log")
	log.Init(logPath)
	t.Cleanup(func() { log.Init("") })

	srv := &Server{unixSocket: true}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/packages/reader/releases", nil)
	responseDetail := "versions request: upstream returned HTTP 429 Too Many Requests"
	srv.wrap(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, responseDetail, http.StatusBadGateway)
	})(rec, req)
	if rec.Body.String() != responseDetail+"\n" {
		t.Fatalf("response body = %q, want complete handler error", rec.Body.String())
	}

	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	line := string(data)
	for _, detail := range []string{
		"WARN",
		"GET /packages/reader/releases",
		"502 Bad Gateway",
		`error="versions request: upstream returned HTTP 429 Too Many Requests"`,
	} {
		if !strings.Contains(line, detail) {
			t.Fatalf("access log = %q, want %q", line, detail)
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
