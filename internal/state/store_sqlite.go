package state

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

type sqliteStore struct {
	s  *State
	db *sql.DB
}

func newSQLiteStore(s *State, platform string) (*sqliteStore, error) {
	db, err := sql.Open("sqlite", s.SQLiteDB)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	store := &sqliteStore{s: s, db: db}
	if _, err := db.Exec("PRAGMA foreign_keys = ON"); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.Exec("PRAGMA busy_timeout = 5000"); err != nil {
		db.Close()
		return nil, err
	}
	if err := store.migrate(); err != nil {
		db.Close()
		return nil, err
	}
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
			installed_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS catalog_packages (
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
		)`,
		`CREATE TABLE IF NOT EXISTS catalog_package_platforms (
			package_id TEXT NOT NULL,
			position INTEGER NOT NULL,
			value TEXT NOT NULL,
			PRIMARY KEY(package_id, position),
			FOREIGN KEY(package_id) REFERENCES catalog_packages(id) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS catalog_package_deps (
			package_id TEXT NOT NULL,
			position INTEGER NOT NULL,
			value TEXT NOT NULL,
			PRIMARY KEY(package_id, position),
			FOREIGN KEY(package_id) REFERENCES catalog_packages(id) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS catalog_package_tags (
			package_id TEXT NOT NULL,
			position INTEGER NOT NULL,
			value TEXT NOT NULL,
			PRIMARY KEY(package_id, position),
			FOREIGN KEY(package_id) REFERENCES catalog_packages(id) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS catalog_package_images (
			package_id TEXT NOT NULL,
			position INTEGER NOT NULL,
			value TEXT NOT NULL,
			PRIMARY KEY(package_id, position),
			FOREIGN KEY(package_id) REFERENCES catalog_packages(id) ON DELETE CASCADE
		)`,
		`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.Exec(stmt); err != nil {
			return err
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
	rows, err := s.db.Query(`SELECT id, name, version, repo, installed_at FROM installed_packages ORDER BY name, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var entries []InstalledEntry
	for rows.Next() {
		var e InstalledEntry
		if err := rows.Scan(&e.ID, &e.Name, &e.Version, &e.Repo, &e.InstalledAt); err != nil {
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
		`INSERT OR REPLACE INTO installed_packages(id, name, version, repo, installed_at) VALUES(?, ?, ?, ?, ?)`,
		e.ID, e.Name, e.Version, e.Repo, e.InstalledAt,
	)
	return err
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

func (s *sqliteStore) ReadCatalog() ([]CatalogEntry, error) {
	rows, err := s.db.Query(`SELECT id, repo, priority, name, version, install_url, uninstall_url, size, description, author, icon_url, repo_icon_url, featured, featured_image, category, source FROM catalog_packages ORDER BY position`)
	if err != nil {
		return nil, err
	}
	var entries []CatalogEntry
	for rows.Next() {
		var e CatalogEntry
		var featured int
		if err := rows.Scan(&e.ID, &e.Repo, &e.Priority, &e.Name, &e.Version, &e.InstallURL, &e.UninstallURL, &e.Size, &e.Description, &e.Author, &e.IconURL, &e.RepoIconURL, &featured, &e.FeaturedImage, &e.Category, &e.Source); err != nil {
			return nil, err
		}
		e.Featured = featured != 0
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	for i := range entries {
		if entries[i].Platforms, err = s.catalogValues("catalog_package_platforms", entries[i].ID); err != nil {
			return nil, err
		}
		if entries[i].Deps, err = s.catalogValues("catalog_package_deps", entries[i].ID); err != nil {
			return nil, err
		}
		if entries[i].Tags, err = s.catalogValues("catalog_package_tags", entries[i].ID); err != nil {
			return nil, err
		}
		if entries[i].Images, err = s.catalogValues("catalog_package_images", entries[i].ID); err != nil {
			return nil, err
		}
	}
	return entries, nil
}

func (s *sqliteStore) WriteCatalog(entries []CatalogEntry) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	for _, table := range []string{
		"catalog_package_platforms",
		"catalog_package_deps",
		"catalog_package_tags",
		"catalog_package_images",
		"catalog_packages",
	} {
		if _, err := tx.Exec("DELETE FROM " + table); err != nil {
			tx.Rollback()
			return err
		}
	}
	for i, e := range entries {
		if _, err := tx.Exec(
			`INSERT INTO catalog_packages(id, position, repo, priority, name, version, install_url, uninstall_url, size, description, author, icon_url, repo_icon_url, featured, featured_image, category, source)
			VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			e.ID, i, e.Repo, e.Priority, e.Name, e.Version, e.InstallURL, e.UninstallURL, e.Size, e.Description, e.Author, e.IconURL, e.RepoIconURL, boolInt(e.Featured), e.FeaturedImage, e.Category, e.Source,
		); err != nil {
			tx.Rollback()
			return err
		}
		if err := insertCatalogValues(tx, "catalog_package_platforms", e.ID, e.Platforms); err != nil {
			tx.Rollback()
			return err
		}
		if err := insertCatalogValues(tx, "catalog_package_deps", e.ID, e.Deps); err != nil {
			tx.Rollback()
			return err
		}
		if err := insertCatalogValues(tx, "catalog_package_tags", e.ID, e.Tags); err != nil {
			tx.Rollback()
			return err
		}
		if err := insertCatalogValues(tx, "catalog_package_images", e.ID, e.Images); err != nil {
			tx.Rollback()
			return err
		}
	}
	return tx.Commit()
}

func (s *sqliteStore) importLegacyState(reposPath, installedPath, catalogPath string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	if repos, err := readReposFile(reposPath); err == nil {
		for _, r := range repos {
			if err := insertRepo(tx, r, true); err != nil {
				tx.Rollback()
				return err
			}
		}
	} else if !os.IsNotExist(err) {
		tx.Rollback()
		return err
	}
	if installed, err := readInstalledFile(installedPath); err == nil {
		for _, e := range installed {
			if e.Name == "" {
				e.Name = e.ID
			}
			if _, err := tx.Exec(
				`INSERT OR IGNORE INTO installed_packages(id, name, version, repo, installed_at) VALUES(?, ?, ?, ?, ?)`,
				e.ID, e.Name, e.Version, e.Repo, e.InstalledAt,
			); err != nil {
				tx.Rollback()
				return err
			}
		}
	} else if !os.IsNotExist(err) {
		tx.Rollback()
		return err
	}
	if catalog, err := readCatalogFile(catalogPath); err == nil {
		if err := s.importCatalog(tx, catalog); err != nil {
			tx.Rollback()
			return err
		}
	} else if !os.IsNotExist(err) {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

func (s *sqliteStore) importStartupState(platform string) error {
	if err := s.importLegacyState(s.s.ReposDB, s.s.InstalledDB, filepath.Join(s.s.CacheDir, "catalog.merged")); err != nil {
		return err
	}
	if platform != "kindle" {
		return nil
	}
	if err := s.importLegacyState(
		filepath.Join(kindlePersistDir, "repos.db"),
		filepath.Join(kindlePersistDir, "installed.db"),
		filepath.Join(defaultKindleHome, "cache", "catalog.merged"),
	); err != nil {
		return err
	}
	return s.setKV("imported_standalone_kindle_at", time.Now().UTC().Format("2006-01-02T15:04:05Z"))
}

func (s *sqliteStore) importCatalog(tx *sql.Tx, entries []CatalogEntry) error {
	var count int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM catalog_packages`).Scan(&count); err != nil {
		return err
	}
	position := count
	for _, e := range entries {
		var exists int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM catalog_packages WHERE id = ?`, e.ID).Scan(&exists); err != nil {
			return err
		}
		if exists > 0 {
			continue
		}
		if _, err := tx.Exec(
			`INSERT INTO catalog_packages(id, position, repo, priority, name, version, install_url, uninstall_url, size, description, author, icon_url, repo_icon_url, featured, featured_image, category, source)
			VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			e.ID, position, e.Repo, e.Priority, e.Name, e.Version, e.InstallURL, e.UninstallURL, e.Size, e.Description, e.Author, e.IconURL, e.RepoIconURL, boolInt(e.Featured), e.FeaturedImage, e.Category, e.Source,
		); err != nil {
			return err
		}
		position++
		if err := insertCatalogValues(tx, "catalog_package_platforms", e.ID, e.Platforms); err != nil {
			return err
		}
		if err := insertCatalogValues(tx, "catalog_package_deps", e.ID, e.Deps); err != nil {
			return err
		}
		if err := insertCatalogValues(tx, "catalog_package_tags", e.ID, e.Tags); err != nil {
			return err
		}
		if err := insertCatalogValues(tx, "catalog_package_images", e.ID, e.Images); err != nil {
			return err
		}
	}
	return nil
}

func (s *sqliteStore) catalogValues(table, packageID string) ([]string, error) {
	rows, err := s.db.Query(fmt.Sprintf("SELECT value FROM %s WHERE package_id = ? ORDER BY position", table), packageID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var values []string
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			return nil, err
		}
		values = append(values, value)
	}
	return values, rows.Err()
}

func (s *sqliteStore) setKV(key, value string) error {
	_, err := s.db.Exec(`INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)`, key, value)
	return err
}

func insertRepo(tx *sql.Tx, r RepoEntry, ignore bool) error {
	stmt := `INSERT OR REPLACE INTO repos(name, url, priority, trust, is_default) VALUES(?, ?, ?, ?, ?)`
	if ignore {
		stmt = `INSERT OR IGNORE INTO repos(name, url, priority, trust, is_default) VALUES(?, ?, ?, ?, ?)`
	}
	_, err := tx.Exec(stmt, r.Name, r.URL, r.Priority, r.Trust, boolInt(r.Default))
	return err
}

func insertCatalogValues(tx *sql.Tx, table, packageID string, values []string) error {
	for i, value := range values {
		if _, err := tx.Exec(
			fmt.Sprintf("INSERT INTO %s(package_id, position, value) VALUES(?, ?, ?)", table),
			packageID, i, value,
		); err != nil {
			return err
		}
	}
	return nil
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
