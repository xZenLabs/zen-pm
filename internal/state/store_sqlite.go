package state

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

type sqliteStore struct {
	s  *State
	db *sql.DB
}

func newSQLiteStore(s *State) (*sqliteStore, error) {
	StartupTrace("SQLite initialization: opening database.")
	db, err := sql.Open(sqliteDriver, s.SQLiteDB)
	if err != nil {
		return nil, err
	}
	StartupTrace("SQLite initialization: database opened.")
	db.SetMaxOpenConns(1)
	store := &sqliteStore{s: s, db: db}
	if _, err := db.Exec("PRAGMA foreign_keys = ON"); err != nil {
		db.Close()
		return nil, err
	}
	StartupTrace("SQLite initialization: foreign keys enabled.")
	if _, err := db.Exec("PRAGMA busy_timeout = 5000"); err != nil {
		db.Close()
		return nil, err
	}
	StartupTrace("SQLite initialization: busy timeout set.")
	StartupTrace("SQLite initialization: migration starting.")
	if err := store.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	StartupTrace("SQLite initialization: migration complete.")
	return store, nil
}

func (s *sqliteStore) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS schema_migrations (
			version INTEGER PRIMARY KEY,
			applied_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS kv (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS repos (
			name TEXT PRIMARY KEY,
			url TEXT NOT NULL,
			priority INTEGER NOT NULL,
			trust TEXT NOT NULL,
			is_default INTEGER NOT NULL DEFAULT 0
		)`,
		`CREATE TABLE IF NOT EXISTS installed_packages (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			version TEXT NOT NULL,
			repo TEXT NOT NULL,
			asset TEXT NOT NULL DEFAULT '',
			asset_arch TEXT NOT NULL DEFAULT '',
			install_path TEXT NOT NULL DEFAULT '',
			update_ignored INTEGER NOT NULL DEFAULT 0,
			installed_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS installed_patch_files (
			package_id TEXT NOT NULL,
			asset TEXT NOT NULL,
			name TEXT NOT NULL,
			version TEXT NOT NULL,
			repo TEXT NOT NULL,
			install_path TEXT NOT NULL DEFAULT '',
			installed_at TEXT NOT NULL,
			PRIMARY KEY(package_id, asset)
		)`,
		`CREATE TABLE IF NOT EXISTS catalog_packages (
			id TEXT PRIMARY KEY,
			position INTEGER NOT NULL,
			repo TEXT NOT NULL,
			priority INTEGER NOT NULL,
			name TEXT NOT NULL,
			version TEXT NOT NULL,
			platforms TEXT NOT NULL DEFAULT '',
			incompatible_platforms TEXT NOT NULL DEFAULT '',
			deps TEXT NOT NULL DEFAULT '',
			conflicts TEXT NOT NULL DEFAULT '',
			install_url TEXT NOT NULL,
			uninstall_url TEXT NOT NULL,
			size TEXT NOT NULL,
			description TEXT NOT NULL,
			author TEXT NOT NULL,
			tags TEXT NOT NULL DEFAULT '',
			icon_url TEXT NOT NULL,
			repo_icon_url TEXT NOT NULL,
			featured INTEGER NOT NULL DEFAULT 0,
			featured_image TEXT NOT NULL,
			featured_order INTEGER,
			category TEXT NOT NULL,
			source TEXT NOT NULL,
			source_asset TEXT NOT NULL DEFAULT '',
			source_type TEXT NOT NULL DEFAULT '',
			source_url TEXT NOT NULL DEFAULT '',
			stars TEXT NOT NULL DEFAULT '',
			assets TEXT NOT NULL DEFAULT '',
			constraints TEXT NOT NULL DEFAULT '',
			plugin_module TEXT NOT NULL DEFAULT '',
			readme_url TEXT NOT NULL DEFAULT '',
			versions_url TEXT NOT NULL DEFAULT '',
			published_at TEXT NOT NULL DEFAULT '',
			release_notes_url TEXT NOT NULL DEFAULT '',
			prerelease_notes_url TEXT NOT NULL DEFAULT '',
			prerelease_version TEXT NOT NULL DEFAULT ''
		)`,
		`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))`,
	}
	for i, stmt := range stmts {
		StartupTrace(fmt.Sprintf("SQLite migration: statement %d.", i+1))
		if _, err := s.db.Exec(stmt); err != nil {
			return err
		}
	}
	if err := s.ensureColumn("catalog_packages", "source_asset", "source_asset TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("installed_packages", "asset", "asset TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("installed_packages", "asset_arch", "asset_arch TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("installed_packages", "install_path", "install_path TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("installed_packages", "update_ignored", "update_ignored INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumn("installed_patch_files", "install_path", "install_path TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "source_type", "source_type TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "source_url", "source_url TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "stars", "stars TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "assets", "assets TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "constraints", "constraints TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "conflicts", "conflicts TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "incompatible_platforms", "incompatible_platforms TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "plugin_module", "plugin_module TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "readme_url", "readme_url TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	versionsURLExists, err := s.columnExists("catalog_packages", "versions_url")
	if err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "versions_url", "versions_url TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	publishedAtExists, err := s.columnExists("catalog_packages", "published_at")
	if err != nil {
		return err
	}
	releaseNotesExists, err := s.columnExists("catalog_packages", "release_notes_url")
	if err != nil {
		return err
	}
	prereleaseNotesExists, err := s.columnExists("catalog_packages", "prerelease_notes_url")
	if err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "published_at", "published_at TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "release_notes_url", "release_notes_url TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "prerelease_notes_url", "prerelease_notes_url TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("catalog_packages", "prerelease_version", "prerelease_version TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if !versionsURLExists || !publishedAtExists || !releaseNotesExists || !prereleaseNotesExists {
		if _, err := s.db.Exec(`INSERT INTO kv(key, value) VALUES(?, '1') ON CONFLICT(key) DO UPDATE SET value = excluded.value`, CatalogPublishedAtRefreshKey); err != nil {
			return err
		}
	}
	if err := s.ensureColumn("catalog_packages", "featured_order", "featured_order INTEGER"); err != nil {
		return err
	}
	for _, column := range []string{"platforms", "deps", "tags"} {
		if err := s.ensureColumn("catalog_packages", column, column+" TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	if err := s.migrateCatalogListTables(); err != nil {
		return err
	}
	if err := s.dropColumnIfExists("catalog_packages", "images"); err != nil {
		return err
	}
	for _, table := range []string{
		"catalog_package_platforms",
		"catalog_package_deps",
		"catalog_package_tags",
		"catalog_package_images",
	} {
		if _, err := s.db.Exec("DROP TABLE IF EXISTS " + table); err != nil {
			return err
		}
	}
	return nil
}

func (s *sqliteStore) columnExists(table, column string) (bool, error) {
	rows, err := s.db.Query("PRAGMA table_info(" + table + ")")
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull, pk int
		var dfltValue interface{}
		if err := rows.Scan(&cid, &name, &typ, &notNull, &dfltValue, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

func (s *sqliteStore) ensureColumn(table, column, definition string) error {
	exists, err := s.columnExists(table, column)
	if err != nil {
		return err
	}
	if exists {
		return nil
	}
	_, err = s.db.Exec("ALTER TABLE " + table + " ADD COLUMN " + definition)
	return err
}

func (s *sqliteStore) dropColumnIfExists(table, column string) error {
	exists, err := s.columnExists(table, column)
	if err != nil || !exists {
		return err
	}
	_, err = s.db.Exec("ALTER TABLE " + table + " DROP COLUMN " + column)
	return err
}

func (s *sqliteStore) tableExists(table string) (bool, error) {
	var name string
	err := s.db.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&name)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func (s *sqliteStore) migrateCatalogListTables() error {
	mappings := []struct {
		column string
		table  string
	}{
		{"platforms", "catalog_package_platforms"},
		{"deps", "catalog_package_deps"},
		{"tags", "catalog_package_tags"},
	}
	for _, m := range mappings {
		exists, err := s.tableExists(m.table)
		if err != nil {
			return err
		}
		if !exists {
			continue
		}
		values, err := s.catalogListValues(m.table)
		if err != nil {
			return err
		}
		for packageID, list := range values {
			if _, err := s.db.Exec("UPDATE catalog_packages SET "+m.column+" = ? WHERE id = ? AND "+m.column+" = ''", strings.Join(list, ","), packageID); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *sqliteStore) ReadRepos() ([]RepoEntry, error) {
	rows, err := s.db.Query(`SELECT name, url, priority, trust, is_default FROM repos ORDER BY priority, name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var repos []RepoEntry
	for rows.Next() {
		var e RepoEntry
		var isDefault int
		if err := rows.Scan(&e.Name, &e.URL, &e.Priority, &e.Trust, &isDefault); err != nil {
			return nil, err
		}
		e.Default = isDefault != 0
		repos = append(repos, e)
	}
	return repos, rows.Err()
}

func (s *sqliteStore) WriteRepos(repos []RepoEntry) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM repos`); err != nil {
		tx.Rollback()
		return err
	}
	for _, r := range repos {
		if err := insertRepo(tx, r, false); err != nil {
			tx.Rollback()
			return err
		}
	}
	return tx.Commit()
}

func (s *sqliteStore) ReadInstalled() ([]InstalledEntry, error) {
	rows, err := s.db.Query(`SELECT id, name, version, repo, asset, asset_arch, install_path, update_ignored, installed_at FROM installed_packages ORDER BY name, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var entries []InstalledEntry
	for rows.Next() {
		var e InstalledEntry
		if err := rows.Scan(&e.ID, &e.Name, &e.Version, &e.Repo, &e.Asset, &e.AssetArch, &e.InstallPath, &e.UpdateIgnored, &e.InstalledAt); err != nil {
			return nil, err
		}
		if e.Name == "" {
			e.Name = e.ID
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

func (s *sqliteStore) AppendInstalled(e InstalledEntry) error {
	if e.InstalledAt == "" {
		e.InstalledAt = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	}
	if e.Name == "" {
		e.Name = e.ID
	}
	_, err := s.db.Exec(
		`INSERT INTO installed_packages(id, name, version, repo, asset, asset_arch, install_path, update_ignored, installed_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		 name = excluded.name, version = excluded.version, repo = excluded.repo, asset = excluded.asset,
		 asset_arch = excluded.asset_arch, install_path = excluded.install_path, installed_at = excluded.installed_at`,
		e.ID, e.Name, e.Version, e.Repo, e.Asset, e.AssetArch, e.InstallPath, e.UpdateIgnored, e.InstalledAt,
	)
	return err
}

func (s *sqliteStore) SetInstalledUpdateIgnored(id string, ignored bool) error {
	result, err := s.db.Exec(`UPDATE installed_packages SET update_ignored = ? WHERE id = ?`, ignored, id)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return fmt.Errorf("installed package %q not found", id)
	}
	return nil
}

func (s *sqliteStore) RemoveInstalled(id string) error {
	_, err := s.db.Exec(`DELETE FROM installed_packages WHERE id = ?`, id)
	return err
}

func (s *sqliteStore) IsInstalled(id string) (bool, string) {
	var version string
	err := s.db.QueryRow(`SELECT version FROM installed_packages WHERE id = ?`, id).Scan(&version)
	if err == sql.ErrNoRows {
		return false, ""
	}
	if err != nil {
		return false, ""
	}
	return true, version
}

func (s *sqliteStore) ReadInstalledPatchFiles() ([]PatchFileEntry, error) {
	rows, err := s.db.Query(`SELECT package_id, asset, name, version, repo, install_path, installed_at FROM installed_patch_files ORDER BY package_id, asset`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var entries []PatchFileEntry
	for rows.Next() {
		var e PatchFileEntry
		if err := rows.Scan(&e.PackageID, &e.Asset, &e.Name, &e.Version, &e.Repo, &e.InstallPath, &e.InstalledAt); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

func (s *sqliteStore) AppendInstalledPatchFile(e PatchFileEntry) error {
	if e.InstalledAt == "" {
		e.InstalledAt = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	}
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO installed_patch_files(package_id, asset, name, version, repo, install_path, installed_at) VALUES(?, ?, ?, ?, ?, ?, ?)`,
		e.PackageID, e.Asset, e.Name, e.Version, e.Repo, e.InstallPath, e.InstalledAt,
	)
	return err
}

func (s *sqliteStore) RemoveInstalledPatchFile(packageID, asset string) error {
	_, err := s.db.Exec(`DELETE FROM installed_patch_files WHERE package_id = ? AND asset = ?`, packageID, asset)
	return err
}

func (s *sqliteStore) ReadValue(key string) (string, error) {
	var value string
	err := s.db.QueryRow(`SELECT value FROM kv WHERE key = ?`, key).Scan(&value)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return value, err
}

func (s *sqliteStore) WriteValue(key, value string) error {
	_, err := s.db.Exec(
		`INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		key, value,
	)
	return err
}

func (s *sqliteStore) ReadCatalog() ([]CatalogEntry, error) {
	rows, err := s.db.Query(`SELECT id, repo, priority, name, version, platforms, incompatible_platforms, deps, conflicts, install_url, uninstall_url, size, description, author, tags, icon_url, repo_icon_url, featured, featured_image, featured_order, category, source, source_asset, source_type, source_url, stars, assets, constraints, plugin_module, readme_url, versions_url, published_at, release_notes_url, prerelease_notes_url, prerelease_version FROM catalog_packages ORDER BY position`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var entries []CatalogEntry
	for rows.Next() {
		var e CatalogEntry
		var featured int
		var featuredOrder sql.NullInt64
		var platforms, incompatiblePlatforms, deps, conflicts, tags string
		if err := rows.Scan(&e.ID, &e.Repo, &e.Priority, &e.Name, &e.Version, &platforms, &incompatiblePlatforms, &deps, &conflicts, &e.InstallURL, &e.UninstallURL, &e.Size, &e.Description, &e.Author, &tags, &e.IconURL, &e.RepoIconURL, &featured, &e.FeaturedImage, &featuredOrder, &e.Category, &e.Source, &e.SourceAsset, &e.SourceType, &e.SourceURL, &e.Stars, &e.Assets, &e.Constraints, &e.PluginModule, &e.ReadmeURL, &e.VersionsURL, &e.PublishedAt, &e.ReleaseNotesURL, &e.PrereleaseNotesURL, &e.PrereleaseVersion); err != nil {
			return nil, err
		}
		e.Platforms = splitCatalogList(platforms)
		e.IncompatiblePlatforms = splitCatalogList(incompatiblePlatforms)
		e.Deps = splitCatalogList(deps)
		e.Conflicts = splitCatalogList(conflicts)
		e.Tags = splitCatalogList(tags)
		e.Featured = featured != 0
		if featuredOrder.Valid {
			value := int(featuredOrder.Int64)
			e.FeaturedOrder = &value
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

func (s *sqliteStore) WriteCatalog(entries []CatalogEntry) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM catalog_packages`); err != nil {
		tx.Rollback()
		return err
	}
	for i, e := range entries {
		if _, err := tx.Exec(
			`INSERT INTO catalog_packages(id, position, repo, priority, name, version, platforms, incompatible_platforms, deps, conflicts, install_url, uninstall_url, size, description, author, tags, icon_url, repo_icon_url, featured, featured_image, featured_order, category, source, source_asset, source_type, source_url, stars, assets, constraints, plugin_module, readme_url, versions_url, published_at, release_notes_url, prerelease_notes_url, prerelease_version)
			VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			e.ID, i, e.Repo, e.Priority, e.Name, e.Version, strings.Join(e.Platforms, ","), strings.Join(e.IncompatiblePlatforms, ","), strings.Join(e.Deps, ","), strings.Join(e.Conflicts, ","), e.InstallURL, e.UninstallURL, e.Size, e.Description, e.Author, strings.Join(e.Tags, ","), e.IconURL, e.RepoIconURL, boolInt(e.Featured), e.FeaturedImage, e.FeaturedOrder, e.Category, e.Source, e.SourceAsset, e.SourceType, e.SourceURL, e.Stars, e.Assets, e.Constraints, e.PluginModule, e.ReadmeURL, e.VersionsURL, e.PublishedAt, e.ReleaseNotesURL, e.PrereleaseNotesURL, e.PrereleaseVersion,
		); err != nil {
			tx.Rollback()
			return err
		}
	}
	return tx.Commit()
}

func (s *sqliteStore) catalogListValues(table string) (map[string][]string, error) {
	rows, err := s.db.Query("SELECT package_id, value FROM " + table + " ORDER BY package_id, position")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := make(map[string][]string)
	for rows.Next() {
		var packageID, value string
		if err := rows.Scan(&packageID, &value); err != nil {
			return nil, err
		}
		values[packageID] = append(values[packageID], value)
	}
	return values, rows.Err()
}

func insertRepo(tx *sql.Tx, r RepoEntry, ignore bool) error {
	stmt := `INSERT OR REPLACE INTO repos(name, url, priority, trust, is_default) VALUES(?, ?, ?, ?, ?)`
	if ignore {
		stmt = `INSERT OR IGNORE INTO repos(name, url, priority, trust, is_default) VALUES(?, ?, ?, ?, ?)`
	}
	_, err := tx.Exec(stmt, r.Name, r.URL, r.Priority, r.Trust, boolInt(r.Default))
	return err
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func splitCatalogList(value string) []string {
	if value == "" {
		return nil
	}
	return strings.Split(value, ",")
}
