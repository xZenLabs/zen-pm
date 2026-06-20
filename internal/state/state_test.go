package state

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolvePersistDirUsesExplicitHome(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	got := resolvePersistDir("kindle", home, true)
	want := filepath.Join(home, "state")
	if got != want {
		t.Fatalf("resolvePersistDir() = %q, want %q", got, want)
	}
}

func TestResolvePersistDirUsesPlatformDefaultWithoutExplicitHome(t *testing.T) {
	got := resolvePersistDir("kindle", defaultKindleHome, false)
	if got != kindlePersistDir {
		t.Fatalf("resolvePersistDir() = %q, want %q", got, kindlePersistDir)
	}
}

func TestFlatFileStoreRoundTrip(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_STATE_BACKEND", "flat")

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if st.StateBackend != "flat" {
		t.Fatalf("StateBackend = %q, want flat", st.StateBackend)
	}
	if err := st.AppendInstalled(InstalledEntry{ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "repo"}); err != nil {
		t.Fatal(err)
	}
	installed, err := st.ReadInstalled()
	if err != nil {
		t.Fatal(err)
	}
	if len(installed) != 1 || installed[0].ID != "pkg" || installed[0].Name != "Package" {
		t.Fatalf("installed = %#v", installed)
	}
	catalog := []CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "repo", Priority: 10,
		Platforms: []string{"kindle", "koreader"}, Deps: []string{"dep"}, Tags: []string{"tag"}, Images: []string{"image"},
		InstallURL: "https://example.invalid/install.sh", UninstallURL: "https://example.invalid/uninstall.sh",
		Featured: true, Category: "utility", Source: "https://example.invalid/source",
	}}
	if err := st.WriteCatalog(catalog); err != nil {
		t.Fatal(err)
	}
	gotCatalog, err := st.ReadCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if len(gotCatalog) != 1 || gotCatalog[0].ID != "pkg" || !gotCatalog[0].Featured || len(gotCatalog[0].Platforms) != 2 {
		t.Fatalf("catalog = %#v", gotCatalog)
	}
}

func TestSQLiteStoreSeedsDefaultsAndRoundTrips(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_STATE_BACKEND", "sqlite")

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if st.StateBackend != "sqlite" {
		t.Fatalf("StateBackend = %q, want sqlite", st.StateBackend)
	}
	if _, err := os.Stat(st.SQLiteDB); err != nil {
		t.Fatalf("sqlite db missing: %v", err)
	}
	repos, err := st.ReadRepos()
	if err != nil {
		t.Fatal(err)
	}
	if len(repos) != 2 || !hasRepo(repos, DefaultZenLabsRepoName) || !hasRepo(repos, DefaultKindleForgeRepoName) {
		t.Fatalf("repos = %#v", repos)
	}
	if err := st.AppendInstalled(InstalledEntry{ID: "pkg", Version: "1.0.0", Repo: "repo"}); err != nil {
		t.Fatal(err)
	}
	ok, version := st.IsInstalled("pkg")
	if !ok || version != "1.0.0" {
		t.Fatalf("IsInstalled = %v, %q", ok, version)
	}
	if err := st.AppendInstalled(InstalledEntry{ID: "pkg", Name: "Package", Version: "1.1.0", Repo: "repo"}); err != nil {
		t.Fatal(err)
	}
	ok, version = st.IsInstalled("pkg")
	if !ok || version != "1.1.0" {
		t.Fatalf("updated IsInstalled = %v, %q", ok, version)
	}
	catalog := []CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.1.0", Repo: "repo", Priority: 10,
		Platforms: []string{"host", "koreader"}, Deps: []string{"dep"}, Tags: []string{"tag"}, Images: []string{"image"},
		InstallURL: "https://example.invalid/install.sh", UninstallURL: "https://example.invalid/uninstall.sh",
		Featured: true, FeaturedImage: "featured", Category: "utility", Source: "source",
	}}
	if err := st.WriteCatalog(catalog); err != nil {
		t.Fatal(err)
	}
	gotCatalog, err := st.ReadCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if len(gotCatalog) != 1 || gotCatalog[0].ID != "pkg" || gotCatalog[0].Images[0] != "image" || gotCatalog[0].Deps[0] != "dep" {
		t.Fatalf("catalog = %#v", gotCatalog)
	}
}

func TestSQLiteImportsLegacyFiles(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	stateDir := filepath.Join(home, "state")
	cacheDir := filepath.Join(home, "cache")
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(cacheDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := writeReposFile(filepath.Join(stateDir, "repos.db"), []RepoEntry{{Name: "Legacy", URL: "https://example.invalid", Priority: 100, Trust: "warn-unsigned"}}); err != nil {
		t.Fatal(err)
	}
	if err := writeInstalledFile(filepath.Join(stateDir, "installed.db"), []InstalledEntry{{ID: "legacy-pkg", Name: "Legacy Package", Version: "1.0.0", Repo: "Legacy", InstalledAt: "2026-01-01T00:00:00Z"}}); err != nil {
		t.Fatal(err)
	}
	if err := writeCatalogFile(filepath.Join(cacheDir, "catalog.merged"), []CatalogEntry{{ID: "legacy-pkg", Name: "Legacy Package", Version: "1.0.0", Repo: "Legacy", Priority: 100, Platforms: []string{"kindle"}, InstallURL: "install", UninstallURL: "uninstall"}}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_STATE_BACKEND", "sqlite")

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	repos, err := st.ReadRepos()
	if err != nil {
		t.Fatal(err)
	}
	if !hasRepo(repos, "Legacy") {
		t.Fatalf("legacy repo not imported: %#v", repos)
	}
	installed, err := st.ReadInstalled()
	if err != nil {
		t.Fatal(err)
	}
	if !hasInstalled(installed, "legacy-pkg", "1.0.0") {
		t.Fatalf("legacy installed not imported: %#v", installed)
	}
	catalog, err := st.ReadCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if len(catalog) != 1 || catalog[0].ID != "legacy-pkg" {
		t.Fatalf("legacy catalog not imported: %#v", catalog)
	}
}

func TestSQLiteImportDoesNotOverwriteExistingRows(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_STATE_BACKEND", "sqlite")

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	store := st.store.(*sqliteStore)
	if err := st.WriteRepos([]RepoEntry{{Name: "Shared", URL: "https://db.invalid", Priority: 10, Trust: "trusted"}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(InstalledEntry{ID: "shared-pkg", Name: "DB Package", Version: "2.0.0", Repo: "Shared", InstalledAt: "2026-02-01T00:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]CatalogEntry{{ID: "shared-pkg", Name: "DB Package", Version: "2.0.0", Repo: "Shared", Priority: 10, Platforms: []string{"koreader"}, InstallURL: "db-install"}}); err != nil {
		t.Fatal(err)
	}

	importDir := t.TempDir()
	if err := writeReposFile(filepath.Join(importDir, "repos.db"), []RepoEntry{
		{Name: "Shared", URL: "https://import.invalid", Priority: 100, Trust: "warn-unsigned"},
		{Name: "Imported", URL: "https://new.invalid", Priority: 100, Trust: "warn-unsigned"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := writeInstalledFile(filepath.Join(importDir, "installed.db"), []InstalledEntry{
		{ID: "shared-pkg", Name: "Import Package", Version: "1.0.0", Repo: "Shared", InstalledAt: "2026-01-01T00:00:00Z"},
		{ID: "new-pkg", Name: "New Package", Version: "1.0.0", Repo: "Imported", InstalledAt: "2026-01-01T00:00:00Z"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := writeCatalogFile(filepath.Join(importDir, "catalog.merged"), []CatalogEntry{
		{ID: "shared-pkg", Name: "Import Package", Version: "1.0.0", Repo: "Shared", Priority: 100, Platforms: []string{"kindle"}, InstallURL: "import-install"},
		{ID: "new-pkg", Name: "New Package", Version: "1.0.0", Repo: "Imported", Priority: 100, Platforms: []string{"kindle"}, InstallURL: "new-install"},
	}); err != nil {
		t.Fatal(err)
	}

	if err := store.importLegacyState(filepath.Join(importDir, "repos.db"), filepath.Join(importDir, "installed.db"), filepath.Join(importDir, "catalog.merged")); err != nil {
		t.Fatal(err)
	}
	repos, err := st.ReadRepos()
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range repos {
		if r.Name == "Shared" && r.URL != "https://db.invalid" {
			t.Fatalf("shared repo overwritten: %#v", r)
		}
	}
	if !hasRepo(repos, "Imported") {
		t.Fatalf("new repo not imported: %#v", repos)
	}
	installed, err := st.ReadInstalled()
	if err != nil {
		t.Fatal(err)
	}
	if !hasInstalled(installed, "shared-pkg", "2.0.0") || !hasInstalled(installed, "new-pkg", "1.0.0") {
		t.Fatalf("installed conflict import wrong: %#v", installed)
	}
	catalog, err := st.ReadCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if !hasCatalog(catalog, "shared-pkg", "2.0.0") || !hasCatalog(catalog, "new-pkg", "1.0.0") {
		t.Fatalf("catalog conflict import wrong: %#v", catalog)
	}
}

func hasRepo(repos []RepoEntry, name string) bool {
	for _, r := range repos {
		if r.Name == name {
			return true
		}
	}
	return false
}

func hasInstalled(entries []InstalledEntry, id, version string) bool {
	for _, e := range entries {
		if e.ID == id && e.Version == version {
			return true
		}
	}
	return false
}

func hasCatalog(entries []CatalogEntry, id, version string) bool {
	for _, e := range entries {
		if e.ID == id && e.Version == version {
			return true
		}
	}
	return false
}
