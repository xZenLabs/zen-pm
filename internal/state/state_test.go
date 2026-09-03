package state

import (
	"database/sql"
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

func TestInitRemovesLegacyJournal(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	journalDir := filepath.Join(home, "journal")
	if err := os.MkdirAll(journalDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(journalDir, "install.tsv"), []byte("legacy journal"), 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZENPM_HOME", home)

	if _, err := Init("host"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(journalDir); !os.IsNotExist(err) {
		t.Fatalf("legacy journal directory still exists: %v", err)
	}
}

func TestInitUsesConfiguredZenLabsRepoURL(t *testing.T) {
	previousURL := DefaultZenLabsRepoURL
	DefaultZenLabsRepoURL = "http://localhost:8000"
	t.Cleanup(func() {
		DefaultZenLabsRepoURL = previousURL
	})
	t.Setenv("ZENPM_HOME", t.TempDir())

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	repos, err := st.ReadRepos()
	if err != nil {
		t.Fatal(err)
	}
	if len(repos) != 1 || repos[0].Name != DefaultZenLabsRepoName || repos[0].URL != "http://localhost:8000" {
		t.Fatalf("repos = %#v, want local ZenLabs repo", repos)
	}
}

func TestSQLiteStoreSeedsApplicableDefaultsAndRoundTrips(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(st.SQLiteDB); err != nil {
		t.Fatalf("sqlite db missing: %v", err)
	}
	if data, err := os.ReadFile(st.GitHubTokenFile); err != nil || len(data) != 0 {
		t.Fatalf("GitHub token placeholder = %q, %v", data, err)
	}
	info, err := os.Stat(st.GitHubTokenFile)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("GitHub token permissions = %v", info.Mode().Perm())
	}
	repos, err := st.ReadRepos()
	if err != nil {
		t.Fatal(err)
	}
	if len(repos) != 1 || !hasRepo(repos, DefaultZenLabsRepoName) || hasRepo(repos, DefaultKindleForgeRepoName) {
		t.Fatalf("repos = %#v", repos)
	}
	if err := st.AppendInstalled(InstalledEntry{ID: "pkg", Version: "1.0.0", Repo: "repo", LauncherAddPending: true, UpdateIgnored: true}); err != nil {
		t.Fatal(err)
	}
	ok, version := st.IsInstalled("pkg")
	if !ok || version != "1.0.0" {
		t.Fatalf("IsInstalled = %v, %q", ok, version)
	}
	if err := st.AppendInstalled(InstalledEntry{ID: "pkg", Name: "Package", Version: "1.1.0", Repo: "repo", Asset: "pkg-armv7.zip", AssetArch: "armv7", InstallPath: "/opt/pkg"}); err != nil {
		t.Fatal(err)
	}
	ok, version = st.IsInstalled("pkg")
	if !ok || version != "1.1.0" {
		t.Fatalf("updated IsInstalled = %v, %q", ok, version)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].Asset != "pkg-armv7.zip" || installed[0].AssetArch != "armv7" || installed[0].InstallPath != "/opt/pkg" || !installed[0].LauncherAddPending || !installed[0].UpdateIgnored {
		t.Fatalf("installed = %#v, %v", installed, err)
	}
	if err := st.SetInstalledUpdateIgnored("pkg", false); err != nil {
		t.Fatal(err)
	}
	installed, err = st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].UpdateIgnored {
		t.Fatalf("installed after clearing ignored updates = %#v, %v", installed, err)
	}
	if err := st.SetInstalledUpdateIgnoredVersion("pkg", "1.2.0"); err != nil {
		t.Fatal(err)
	}
	installed, err = st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].UpdateIgnored || installed[0].UpdateIgnoredVersion != "1.2.0" {
		t.Fatalf("installed after ignoring one update version = %#v, %v", installed, err)
	}
	if err := st.AppendInstalledPatchFile(PatchFileEntry{PackageID: "patches", Asset: "patch.lua", Name: "Patch", Version: "1.0.0", Repo: "repo", InstallPath: "/opt/patches/patch.lua"}); err != nil {
		t.Fatal(err)
	}
	patches, err := st.ReadInstalledPatchFiles()
	if err != nil || len(patches) != 1 || patches[0].InstallPath != "/opt/patches/patch.lua" {
		t.Fatalf("patches = %#v, %v", patches, err)
	}
	featuredOrder := 10
	catalog := []CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.1.0", Repo: "repo", Priority: 10,
		Platforms: []string{"host", "koreader"}, IncompatiblePlatforms: []string{"android"}, Deps: []string{"dep"}, Conflicts: []string{"zen-ui"}, Tags: []string{"tag"},
		InstallURL: "https://example.invalid/install.sh", UninstallURL: "https://example.invalid/uninstall.sh",
		Featured: true, FeaturedImage: "featured", FeaturedOrder: &featuredOrder, Category: "utility", Source: "source", SourceAsset: "pkg.zip",
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"}, SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
		SourceType: "release", SourceURL: "https://example.invalid/source.zip", Stars: "42",
		ReadmeURL:          "https://example.invalid/README.md",
		VersionsURL:        "https://example.invalid/versions.json",
		ReleaseNotesURL:    "https://example.invalid/RELEASE_NOTES.md",
		PrereleaseNotesURL: "https://example.invalid/PRERELEASE_NOTES.md",
		PrereleaseVersion:  "1.2.0-rc.1",
		AlphaVersion:       "1.2.0-alpha1",
		PublishedAt:        "2026-07-24T12:00:00Z",
		Assets:             `[{"arch":"arm","asset":"pkg.zip","url":"https://example.invalid/pkg.zip","size":"12"}]`, Constraints: `{"abi":["hf","sf"]}`,
	}}
	if err := st.WriteCatalog(catalog); err != nil {
		t.Fatal(err)
	}
	gotCatalog, err := st.ReadCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if len(gotCatalog) != 1 || gotCatalog[0].ID != "pkg" || gotCatalog[0].Deps[0] != "dep" || len(gotCatalog[0].IncompatiblePlatforms) != 1 || gotCatalog[0].IncompatiblePlatforms[0] != "android" || len(gotCatalog[0].Conflicts) != 1 || gotCatalog[0].Conflicts[0] != "zen-ui" || gotCatalog[0].Tags[0] != "tag" || gotCatalog[0].FeaturedOrder == nil || *gotCatalog[0].FeaturedOrder != featuredOrder || gotCatalog[0].SourceAsset != "pkg.zip" || gotCatalog[0].PluginModule != "zenos" || len(gotCatalog[0].PluginModuleAliases) != 1 || gotCatalog[0].PluginModuleAliases[0] != "zen_ui" || len(gotCatalog[0].SourceAssetAliases) != 1 || gotCatalog[0].SourceAssetAliases[0] != "zen_ui.koplugin.zip" || gotCatalog[0].SourceType != "release" || gotCatalog[0].SourceURL != "https://example.invalid/source.zip" || gotCatalog[0].ReadmeURL != "https://example.invalid/README.md" || gotCatalog[0].VersionsURL != "https://example.invalid/versions.json" || gotCatalog[0].ReleaseNotesURL != "https://example.invalid/RELEASE_NOTES.md" || gotCatalog[0].PrereleaseNotesURL != "https://example.invalid/PRERELEASE_NOTES.md" || gotCatalog[0].PrereleaseVersion != "1.2.0-rc.1" || gotCatalog[0].AlphaVersion != "1.2.0-alpha1" || gotCatalog[0].PublishedAt != "2026-07-24T12:00:00Z" || gotCatalog[0].Stars != "42" || gotCatalog[0].Assets == "" || gotCatalog[0].Constraints == "" {
		t.Fatalf("catalog = %#v", gotCatalog)
	}
}

func TestReconcileDefaultReposDoesNotAddKindleForge(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	st.kindleWAFAllowed = true
	if err := reconcileDefaultRepos(st); err != nil {
		t.Fatal(err)
	}
	repos, err := st.ReadRepos()
	if err != nil || hasRepo(repos, DefaultKindleForgeRepoName) {
		t.Fatalf("supported repos = %#v, %v", repos, err)
	}

	legacy := RepoEntry{
		Name: DefaultKindleForgeRepoName, URL: DefaultKindleForgeRepoURL,
		Priority: 10, Trust: "trusted", Default: true,
	}
	if err := st.WriteRepos(append(repos, legacy)); err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]CatalogEntry{{ID: "kindle-package", Repo: DefaultKindleForgeRepoName}}); err != nil {
		t.Fatal(err)
	}
	if err := reconcileDefaultRepos(st); err != nil {
		t.Fatal(err)
	}
	repos, err = st.ReadRepos()
	if err != nil {
		t.Fatal(err)
	}
	if hasRepo(repos, DefaultKindleForgeRepoName) {
		t.Fatalf("unsupported repos still contain KindleForge: %#v", repos)
	}
	catalog, err := st.ReadCatalog()
	if err != nil || len(catalog) != 0 {
		t.Fatalf("catalog after KindleForge removal = %#v, %v", catalog, err)
	}

	optedIn := RepoEntry{
		Name: DefaultKindleForgeRepoName, URL: DefaultKindleForgeRepoURL,
		Priority: 100, Trust: "trusted",
	}
	if err := st.WriteRepos(append(repos, optedIn)); err != nil {
		t.Fatal(err)
	}
	if err := reconcileDefaultRepos(st); err != nil {
		t.Fatal(err)
	}
	repos, err = st.ReadRepos()
	if err != nil || !hasRepo(repos, DefaultKindleForgeRepoName) {
		t.Fatalf("opted-in repos = %#v, %v", repos, err)
	}

	st.kindleWAFAllowed = false
	if err := reconcileDefaultRepos(st); err != nil {
		t.Fatal(err)
	}
	repos, err = st.ReadRepos()
	if err != nil || hasRepo(repos, DefaultKindleForgeRepoName) {
		t.Fatalf("unsupported repos = %#v, %v", repos, err)
	}
}

func TestSQLiteStoreValueRoundTrip(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if got, err := st.ReadValue("missing"); err != nil || got != "" {
		t.Fatalf("missing value = %q, %v", got, err)
	}
	if err := st.WriteValue("key", "first"); err != nil {
		t.Fatal(err)
	}
	if err := st.WriteValue("key", "second"); err != nil {
		t.Fatal(err)
	}
	if got, err := st.ReadValue("key"); err != nil || got != "second" {
		t.Fatalf("stored value = %q, %v", got, err)
	}
}

func TestSQLiteStoreAddsSourceAssetColumnToExistingCatalogTable(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	stateDir := filepath.Join(home, "state")
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "zenpm.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE catalog_packages (
		id TEXT PRIMARY KEY,
		position INTEGER NOT NULL,
		repo TEXT NOT NULL,
		priority INTEGER NOT NULL,
		name TEXT NOT NULL,
		version TEXT NOT NULL,
		install_url TEXT NOT NULL,
		uninstall_url TEXT NOT NULL,
		size TEXT NOT NULL,
		description TEXT NOT NULL,
		author TEXT NOT NULL,
		icon_url TEXT NOT NULL,
		repo_icon_url TEXT NOT NULL,
		featured INTEGER NOT NULL DEFAULT 0,
		featured_image TEXT NOT NULL,
		category TEXT NOT NULL,
		source TEXT NOT NULL
	)`); err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	t.Setenv("ZENPM_HOME", home)

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "repo",
		InstallURL: "install.sh", SourceAsset: "pkg.zip", SourceType: "release", SourceURL: "https://example.invalid/source.zip", Stars: "42",
	}}); err != nil {
		t.Fatal(err)
	}
	catalog, err := st.ReadCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if len(catalog) != 1 || catalog[0].SourceAsset != "pkg.zip" || catalog[0].SourceType != "release" || catalog[0].SourceURL != "https://example.invalid/source.zip" || catalog[0].Stars != "42" {
		t.Fatalf("catalog = %#v", catalog)
	}
}

func TestSQLiteStoreAddsInstalledPackageColumnsWithSafeDefaults(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	stateDir := filepath.Join(home, "state")
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "zenpm.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE installed_packages (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		version TEXT NOT NULL,
		repo TEXT NOT NULL,
		asset TEXT NOT NULL DEFAULT '',
		asset_arch TEXT NOT NULL DEFAULT '',
		install_path TEXT NOT NULL DEFAULT '',
		installed_at TEXT NOT NULL
	)`); err != nil {
		db.Close()
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO installed_packages(id, name, version, repo, installed_at) VALUES('pkg', 'Package', '1.0.0', 'repo', '2026-07-29T00:00:00Z')`); err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	t.Setenv("ZENPM_HOME", home)
	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetInstalledUpdateIgnoredVersion("pkg", "1.1.0"); err != nil {
		t.Fatal(err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].LauncherAddPending || installed[0].UpdateIgnored || installed[0].UpdateIgnoredVersion != "1.1.0" {
		t.Fatalf("installed = %#v, %v", installed, err)
	}
}

func TestSQLiteStoreMigratesCatalogListTables(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	stateDir := filepath.Join(home, "state")
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "zenpm.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE catalog_packages (
		id TEXT PRIMARY KEY,
		position INTEGER NOT NULL,
		repo TEXT NOT NULL,
		priority INTEGER NOT NULL,
		name TEXT NOT NULL,
		version TEXT NOT NULL,
		install_url TEXT NOT NULL,
		uninstall_url TEXT NOT NULL,
		size TEXT NOT NULL,
		description TEXT NOT NULL,
		author TEXT NOT NULL,
		icon_url TEXT NOT NULL,
		repo_icon_url TEXT NOT NULL,
		featured INTEGER NOT NULL DEFAULT 0,
		featured_image TEXT NOT NULL,
		category TEXT NOT NULL,
		source TEXT NOT NULL
	)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO catalog_packages(id, position, repo, priority, name, version, install_url, uninstall_url, size, description, author, icon_url, repo_icon_url, featured, featured_image, category, source)
		VALUES('pkg', 0, 'repo', 10, 'Package', '1.0.0', 'install.sh', 'uninstall.sh', '', '', '', '', '', 0, '', '', '')`); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"catalog_package_platforms", "catalog_package_deps", "catalog_package_tags", "catalog_package_images"} {
		if _, err := db.Exec(`CREATE TABLE ` + table + ` (
			package_id TEXT NOT NULL,
			position INTEGER NOT NULL,
			value TEXT NOT NULL,
			PRIMARY KEY(package_id, position)
		)`); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO catalog_package_platforms(package_id, position, value) VALUES('pkg', 0, 'kindle'), ('pkg', 1, 'koreader')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO catalog_package_deps(package_id, position, value) VALUES('pkg', 0, 'dep')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO catalog_package_tags(package_id, position, value) VALUES('pkg', 0, 'tag')`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	t.Setenv("ZENPM_HOME", home)

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
	}
	catalog, err := st.ReadCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if len(catalog) != 1 || len(catalog[0].Platforms) != 2 || catalog[0].Platforms[1] != "koreader" || catalog[0].Deps[0] != "dep" || catalog[0].Tags[0] != "tag" || len(catalog[0].Images) != 0 {
		t.Fatalf("catalog = %#v", catalog)
	}
	db, err = sql.Open("sqlite", filepath.Join(stateDir, "zenpm.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var name string
	err = db.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'catalog_package_platforms'`).Scan(&name)
	if err != sql.ErrNoRows {
		t.Fatalf("catalog_package_platforms still exists: name=%q err=%v", name, err)
	}
	err = db.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'catalog_package_images'`).Scan(&name)
	if err != sql.ErrNoRows {
		t.Fatalf("catalog_package_images still exists: name=%q err=%v", name, err)
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
