package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
)

func TestRunPackageListPrintsPackageNamesAndVersions(t *testing.T) {
	st := newCLIState(t)
	if err := st.WriteCatalog([]state.CatalogEntry{
		{ID: "reader", Name: "Reader", Version: "1.0.0", Platforms: []string{"host"}},
		{ID: "kindle-only", Name: "Kindle Only", Version: "2.0.0", Platforms: []string{"kindle"}},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{ID: "reader", Version: "1.0.0", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}

	output := captureStdout(t, func() {
		runPackage(st, repo.New(st), nil, "host", []string{"list"})
	})
	if output != "reader | Reader | 1.0.0\n" {
		t.Fatalf("zenpm list output = %q, want id, name, and version", output)
	}
}

func TestRunPackageListInstalledPrintsPackageNamesAndVersions(t *testing.T) {
	st := newCLIState(t)
	for _, entry := range []state.InstalledEntry{
		{ID: "reader", Name: "Reader", Version: "1.0.0", Repo: "ZenLabs"},
		{ID: "plugin", Version: "2.0.0", Repo: "ZenLabs"},
	} {
		if err := st.AppendInstalled(entry); err != nil {
			t.Fatal(err)
		}
	}

	output := captureStdout(t, func() {
		runPackage(st, repo.New(st), nil, "host", []string{"list", "installed"})
	})
	if output != "reader | Reader | 1.0.0\nplugin | plugin | 2.0.0\n" {
		t.Fatalf("zenpm list installed output = %q, want id, name, and version", output)
	}
}

func TestRunPackageListRefreshesEmptyCatalog(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/manifest.json" {
			http.NotFound(w, r)
			return
		}
		_, _ = io.WriteString(w, `{"packages":[{"id":"reader","name":"Reader","version":"1.0.0","platforms":["host"]}]}`)
	}))
	defer srv.Close()

	st := newCLIState(t)
	if err := st.WriteRepos([]state.RepoEntry{{Name: "test", URL: srv.URL, Priority: 10, Trust: "trusted"}}); err != nil {
		t.Fatal(err)
	}

	output := captureStdout(t, func() {
		runPackage(st, repo.New(st), nil, "host", []string{"list"})
	})
	if output != "reader | Reader | 1.0.0\n" {
		t.Fatalf("zenpm list output = %q, want refreshed package", output)
	}
}

func newCLIState(t *testing.T) *state.State {
	t.Helper()
	t.Setenv("ZENPM_HOME", t.TempDir())
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	return st
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	previous := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = writer
	defer func() {
		os.Stdout = previous
		reader.Close()
	}()

	fn()
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	return string(output)
}
