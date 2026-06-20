package server

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"ZPM/internal/pkg"
	"ZPM/internal/repo"
	"ZPM/internal/state"
)

func TestInitialCatalogStateRefreshesEmptySQLiteCatalog(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_STATE_BACKEND", "sqlite")

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
	t.Setenv("ZENPM_STATE_BACKEND", "sqlite")

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

func TestInitialCatalogStateRefreshesStaleCatalog(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_STATE_BACKEND", "sqlite")

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
