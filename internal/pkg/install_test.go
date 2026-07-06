package pkg

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ZPM/internal/repo"
	"ZPM/internal/state"
)

func TestInstallPassesPackageSourceEnv(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	out := filepath.Join(t.TempDir(), "env.out")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_ENV_OUT", out)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "#!/bin/sh\n")
		io.WriteString(w, "printf '%s|%s|%s\\n' \"$ZENPM_PACKAGE_ID\" \"$ZENPM_PACKAGE_SOURCE\" \"$ZENPM_PACKAGE_SOURCE_ASSET\" > \"$ZENPM_ENV_OUT\"\n")
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:          "zen-mtp-koplugin",
		Name:        "ZenMTP",
		Version:     "1.7",
		Repo:        "ZenLabs",
		InstallURL:  srv.URL,
		Source:      "https://github.com/xZenLabs/ZenMTP",
		SourceAsset: "zen_mtp.koplugin.zip",
	}}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	if err := manager.Install("zen-mtp-koplugin"); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.TrimSpace(string(data))
	want := "zen-mtp-koplugin|https://github.com/xZenLabs/ZenMTP|zen_mtp.koplugin.zip"
	if got != want {
		t.Fatalf("env output = %q, want %q", got, want)
	}
}

func TestInstallReleasePassesSpecificGitHubReleaseAndRecordsVersion(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	out := filepath.Join(t.TempDir(), "env.out")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_ENV_OUT", out)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "#!/bin/sh\n")
		io.WriteString(w, "printf '%s|%s\\n' \"$ZENPM_PACKAGE_SOURCE\" \"$ZENPM_PACKAGE_SOURCE_ASSET\" > \"$ZENPM_ENV_OUT\"\n")
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:          "reader",
		Name:        "Reader",
		Version:     "2.0.0",
		Repo:        "ZenLabs",
		InstallURL:  srv.URL,
		Source:      "https://github.com/owner/reader",
		SourceAsset: "reader-v2.0.0.zip",
	}}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	if err := manager.InstallRelease("reader", "v1.5.0", "reader-v1.5.0.zip"); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	want := "https://github.com/owner/reader/releases/tag/v1.5.0|reader-v1.5.0.zip"
	if got := strings.TrimSpace(string(data)); got != want {
		t.Fatalf("env output = %q, want %q", got, want)
	}
	installed, err := st.ReadInstalled()
	if err != nil {
		t.Fatal(err)
	}
	if len(installed) != 1 || installed[0].Version != "v1.5.0" {
		t.Fatalf("installed = %#v", installed)
	}
}

func TestUninstallRefreshesCatalogWhenUninstallURLMissing(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	out := filepath.Join(t.TempDir(), "uninstall.out")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/manifest.json":
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"packages":[{"id":"zen-koreader","name":"Zen KOReader","version":"1.0.5","platforms":["kindle"],"install_url":"install.sh","uninstall_url":"uninstall.sh"}]}`)
		case "/uninstall.sh":
			io.WriteString(w, "#!/bin/sh\nset -eu\necho \"$ZENPM_PACKAGE_ID\" > "+out+"\n")
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	if err := st.WriteRepos([]state.RepoEntry{{Name: "ZenLabs", URL: srv.URL, Priority: 10, Trust: "trusted"}}); err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:         "zen-koreader",
		Name:       "Zen KOReader",
		Version:    "1.0.5",
		Repo:       "ZenLabs",
		Platforms:  []string{"kindle"},
		InstallURL: "install.sh",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{ID: "zen-koreader", Name: "Zen KOReader", Version: "1.0.5", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	if err := manager.Uninstall("zen-koreader"); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(data)); got != "zen-koreader" {
		t.Fatalf("uninstall script output = %q, want package id", got)
	}
	if ok, _ := st.IsInstalled("zen-koreader"); ok {
		t.Fatal("package still installed after uninstall")
	}
}

func TestInstallEnvFallsBackToKopluginAssetPattern(t *testing.T) {
	m := &Manager{plat: "host"}
	env := m.installEnv(&repo.CatalogEntry{
		ID:         "zen-mtp-koplugin",
		InstallURL: "https://xzenlabs.github.io/repo/packages/koreader/install-plugin.sh",
		Platforms:  []string{"koreader", "kindle"},
		Source:     "https://github.com/xZenLabs/ZenMTP",
	}, "")

	got := env["ZENPM_PACKAGE_SOURCE_ASSET"]
	if got != ".koplugin.zip" {
		t.Fatalf("ZENPM_PACKAGE_SOURCE_ASSET = %q, want %q", got, ".koplugin.zip")
	}
}

func TestInstallEnvPassesKOReaderPathCandidates(t *testing.T) {
	m := &Manager{plat: "kindle"}
	env := m.installEnv(&repo.CatalogEntry{ID: "patch"}, "")

	paths := strings.Split(env["ZENPM_KOREADER_PATHS"], ":")
	wantFirst := "/mnt/us/kmc/kpm/packages/koreader/koreader"
	if len(paths) == 0 || paths[0] != wantFirst {
		t.Fatalf("ZENPM_KOREADER_PATHS = %q, want first path %q", env["ZENPM_KOREADER_PATHS"], wantFirst)
	}
}

func TestInstallEnvPassesSelectedAssetMetadata(t *testing.T) {
	m := &Manager{plat: "host"}
	env := m.installEnv(&repo.CatalogEntry{
		ID:        "koreader-2",
		SourceURL: "https://example.invalid/source.zip",
		Assets:    `[{"arch":"any","asset":"2-custom-pan-rate.lua","url":"https://example.invalid/2-custom-pan-rate.lua","size":"3473"}]`,
	}, "2-custom-pan-rate.lua")

	if got := env["ZENPM_PACKAGE_SOURCE_ASSET"]; got != "2-custom-pan-rate.lua" {
		t.Fatalf("ZENPM_PACKAGE_SOURCE_ASSET = %q", got)
	}
	if got := env["ZENPM_PACKAGE_SOURCE_URL"]; got != "https://example.invalid/source.zip" {
		t.Fatalf("ZENPM_PACKAGE_SOURCE_URL = %q", got)
	}
	if got := env["ZENPM_PACKAGE_ASSET_URL"]; got != "https://example.invalid/2-custom-pan-rate.lua" {
		t.Fatalf("ZENPM_PACKAGE_ASSET_URL = %q", got)
	}
	if got := env["ZENPM_PACKAGE_ASSET_SIZE"]; got != "3473" {
		t.Fatalf("ZENPM_PACKAGE_ASSET_SIZE = %q", got)
	}
	if got := env["ZENPM_PACKAGE_ASSET_ARCH"]; got != "any" {
		t.Fatalf("ZENPM_PACKAGE_ASSET_ARCH = %q", got)
	}
}

func TestSelectAssetNeedsChoiceForPatchPackages(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:         "koreader-2",
		Name:       "Koreader",
		Version:    "0.0.0-source",
		Repo:       "ZenLabs",
		Category:   "patches",
		Platforms:  []string{"koreader"},
		InstallURL: "packages/koreader/install-patch.sh",
		Assets:     `[{"arch":"any","asset":"2-a.lua"},{"arch":"any","asset":"2-b.lua"}]`,
	}}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	result, err := manager.SelectAsset("koreader-2")
	if err != nil {
		t.Fatal(err)
	}
	if !result.NeedsChoice || len(result.Candidates) != 2 {
		t.Fatalf("SelectAsset = %+v, want two patch candidates", result)
	}
}

func TestInstallAndUninstallEnvResolveKOReaderOverride(t *testing.T) {
	root := filepath.Join(t.TempDir(), "koreader")
	t.Setenv("ZENPM_KOREADER_DIR", root)

	m := &Manager{plat: "kindle"}
	installEnv := m.installEnv(&repo.CatalogEntry{ID: "patch"}, "")
	uninstallEnv := m.uninstallEnv("patch")

	for name, env := range map[string]map[string]string{"install": installEnv, "uninstall": uninstallEnv} {
		if got := env["ZENPM_KOREADER_DIR"]; got != root {
			t.Fatalf("%s ZENPM_KOREADER_DIR = %q, want %q", name, got, root)
		}
		if got := env["ZENPM_KOREADER_PLUGIN_DIR"]; got != filepath.Join(root, "plugins") {
			t.Fatalf("%s ZENPM_KOREADER_PLUGIN_DIR = %q, want %q", name, got, filepath.Join(root, "plugins"))
		}
	}
}

func TestDisplayVersionDoesNotDoublePrefix(t *testing.T) {
	tests := map[string]string{
		"1.7":  "v1.7",
		"v1.7": "v1.7",
		"V1.7": "V1.7",
	}
	for input, want := range tests {
		if got := displayVersion(input); got != want {
			t.Fatalf("displayVersion(%q) = %q, want %q", input, got, want)
		}
	}
}
