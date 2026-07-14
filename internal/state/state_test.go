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

func TestSQLiteStoreSeedsDefaultsAndRoundTrips(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := Init("host")
	if err != nil {
		t.Fatal(err)
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
	featuredOrder := 10
	catalog := []CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "1.1.0", Repo: "repo", Priority: 10,
		Platforms: []string{"host", "koreader"}, Deps: []string{"dep"}, Tags: []string{"tag"},
		InstallURL: "https://example.invalid/install.sh", UninstallURL: "https://example.invalid/uninstall.sh",
		Featured: true, FeaturedImage: "featured", FeaturedOrder: &featuredOrder, Category: "utility", Source: "source", SourceAsset: "pkg.zip",
		SourceType: "release", SourceURL: "https://example.invalid/source.zip", Stars: "42",
		Assets: `[{"arch":"arm","asset":"pkg.zip","url":"https://example.invalid/pkg.zip","size":"12"}]`, Constraints: `{"abi":["hf","sf"]}`,
	}}
	if err := st.WriteCatalog(catalog); err != nil {
		t.Fatal(err)
	}
	gotCatalog, err := st.ReadCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if len(gotCatalog) != 1 || gotCatalog[0].ID != "pkg" || gotCatalog[0].Deps[0] != "dep" || gotCatalog[0].Tags[0] != "tag" || gotCatalog[0].FeaturedOrder == nil || *gotCatalog[0].FeaturedOrder != featuredOrder || gotCatalog[0].SourceAsset != "pkg.zip" || gotCatalog[0].SourceType != "release" || gotCatalog[0].SourceURL != "https://example.invalid/source.zip" || gotCatalog[0].Stars != "42" || gotCatalog[0].Assets == "" || gotCatalog[0].Constraints == "" {
		t.Fatalf("catalog = %#v", gotCatalog)
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
