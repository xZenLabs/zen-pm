package pkg

import (
	"archive/zip"
	"bytes"
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
		ID:           "zen-mtp-koplugin",
		Name:         "ZenMTP",
		Version:      "1.7",
		Repo:         "ZenLabs",
		InstallURL:   srv.URL,
		UninstallURL: srv.URL,
		Source:       "https://github.com/xZenLabs/ZenMTP",
		SourceAsset:  "zen_mtp.koplugin.zip",
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
	if _, err := os.Stat(st.CachedUninstallScriptPath("zen-mtp-koplugin")); err != nil {
		t.Fatalf("cached plugin uninstall script missing: %v", err)
	}
}

func TestInstallGenericPluginNatively(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	koRoot := filepath.Join(t.TempDir(), "koreader")
	if err := os.MkdirAll(filepath.Join(koRoot, "plugins"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(koRoot, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZENPM_KOREADER_DIR", koRoot)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/plugin.koplugin.zip":
			w.Write(zipContents(t, map[string]string{"plugin.koplugin/_meta.lua": "return {}\n"}))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:         "plugin",
		Name:       "Plugin",
		Version:    "1.0.0",
		Repo:       "ZenLabs",
		Platforms:  []string{"koreader"},
		InstallURL: srv.URL + "/install-plugin.sh",
		Source:     "https://github.com/owner/plugin",
		Assets:     `[{"arch":"any","asset":"plugin.koplugin.zip","url":"` + srv.URL + `/plugin.koplugin.zip"}]`,
	}}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	if err := manager.Install("plugin"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, "plugins", "plugin.koplugin", "_meta.lua")); err != nil {
		t.Fatalf("native plugin was not installed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, ".zenpm-plugins", "plugin.koplugin")); err != nil {
		t.Fatalf("plugin tracking file was not written: %v", err)
	}
	if err := manager.Uninstall("plugin", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, "plugins", "plugin.koplugin")); !os.IsNotExist(err) {
		t.Fatalf("native plugin was not removed: %v", err)
	}
}

func TestInstallGenericPatchNatively(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	koRoot := filepath.Join(t.TempDir(), "koreader")
	if err := os.MkdirAll(koRoot, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(koRoot, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZENPM_KOREADER_DIR", koRoot)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/patch.lua" {
			http.NotFound(w, r)
			return
		}
		io.WriteString(w, "return {}\n")
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:         "patch",
		Name:       "Patch",
		Version:    "1.0.0",
		Repo:       "ZenLabs",
		Category:   "patches",
		Platforms:  []string{"koreader"},
		InstallURL: srv.URL + "/install-patch.sh",
		Source:     "https://github.com/owner/patches",
		SourceType: "source",
		Assets:     `[{"arch":"any","asset":"patch.lua","url":"` + srv.URL + `/patch.lua"}]`,
	}}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Install("patch"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, "patches", "patch.lua")); err != nil {
		t.Fatalf("native patch was not installed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, ".zenpm-patches", "patch.lua")); err != nil {
		t.Fatalf("patch tracking file was not written: %v", err)
	}
}

func TestNativeKOReaderInstallerClaimsGenericScripts(t *testing.T) {
	manager := &Manager{plat: "host"}
	patch := &repo.CatalogEntry{
		Platforms:  []string{"koreader"},
		InstallURL: "https://example.invalid/install-patch.sh",
		Source:     "https://github.com/owner/patches",
		SourceType: "source",
		Assets:     `[{"asset":"patch.lua"}]`,
	}
	if got := manager.nativeKOReaderInstaller(patch, "patch.lua"); got != genericPatchInstaller {
		t.Fatalf("native patch installer = %q, want %q", got, genericPatchInstaller)
	}

	plugin := &repo.CatalogEntry{
		Platforms:  []string{"koreader"},
		InstallURL: "https://example.invalid/install-plugin.sh",
	}
	if got := manager.nativeKOReaderInstaller(plugin, ""); got != genericPluginInstaller {
		t.Fatalf("native plugin installer = %q, want %q", got, genericPluginInstaller)
	}
}

func zipContents(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var out bytes.Buffer
	archive := zip.NewWriter(&out)
	for name, contents := range files {
		entry, err := archive.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(entry, contents); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func TestPatchInstallUninstallTracksPerFileState(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	out := filepath.Join(t.TempDir(), "asset.out")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_ENV_OUT", out)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "#!/bin/sh\n")
		io.WriteString(w, "printf '%s\\n' \"$ZENPM_PACKAGE_SOURCE_ASSET\" >> \"$ZENPM_ENV_OUT\"\n")
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:           "koreader-11",
		Name:         "Koreader",
		Version:      "0.0.0-source",
		Repo:         "ZenLabs",
		Category:     "patches",
		Platforms:    []string{"koreader"},
		InstallURL:   srv.URL,
		UninstallURL: srv.URL,
		Assets:       `[{"arch":"any","asset":"2-menu-size.lua"},{"arch":"any","asset":"2-ui-font.lua"}]`,
	}}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")

	if err := manager.InstallAsset("koreader-11", "2-menu-size.lua"); err != nil {
		t.Fatal(err)
	}
	if err := manager.InstallAsset("koreader-11", "2-ui-font.lua"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(st.CachedUninstallScriptPath("koreader-11")); err != nil {
		t.Fatalf("cached patch uninstall script missing: %v", err)
	}

	// Patch files must NOT collapse into installed_packages.
	if installed, _ := st.ReadInstalled(); len(installed) != 0 {
		t.Fatalf("installed_packages = %#v, want empty", installed)
	}
	files, err := st.ReadInstalledPatchFiles()
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 {
		t.Fatalf("patch files after install = %#v, want 2", files)
	}

	if err := manager.Uninstall("koreader-11", "2-menu-size.lua"); err != nil {
		t.Fatal(err)
	}
	files, _ = st.ReadInstalledPatchFiles()
	if len(files) != 1 || files[0].Asset != "2-ui-font.lua" {
		t.Fatalf("patch files after uninstall = %#v, want only 2-ui-font.lua", files)
	}

	// Uninstalling a not-installed file must error.
	if err := manager.Uninstall("koreader-11", "2-menu-size.lua"); err == nil {
		t.Fatal("expected error uninstalling already-removed patch file")
	}
}

func TestUninstallGenericPatchRemovesDisabledFile(t *testing.T) {
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
	disabled := filepath.Join(root, "patches", "patch.lua.disabled")
	if err := os.WriteFile(disabled, []byte("return {}\n"), 0644); err != nil {
		t.Fatal(err)
	}

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "#!/bin/sh\n")
	}))
	defer srv.Close()
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "patch", Name: "Patch", Repo: "ZenLabs", Category: "patches", Platforms: []string{"koreader"},
		InstallURL: srv.URL + "/install-patch.sh", UninstallURL: srv.URL + "/uninstall-patch.sh",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalledPatchFile(state.PatchFileEntry{PackageID: "patch", Asset: "patch.lua", Name: "Patch", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Uninstall("patch", "patch.lua"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(disabled); !os.IsNotExist(err) {
		t.Fatalf("disabled patch remains after uninstall: %v", err)
	}
}

func TestPatchInstallScriptURLWithQueryTracksPerFileState(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	koRoot := filepath.Join(t.TempDir(), "koreader")
	if err := os.MkdirAll(koRoot, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(koRoot, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZENPM_KOREADER_DIR", koRoot)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/2---stretched-covers.lua" {
			http.NotFound(w, r)
			return
		}
		io.WriteString(w, "return {}\n")
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:           "koreader-5",
		Name:         "Koreader",
		Version:      "0.0.0-source",
		Repo:         "ZenLabs",
		Platforms:    []string{"koreader"},
		InstallURL:   srv.URL + "/install-patch.sh?ref=main",
		UninstallURL: srv.URL + "/install-patch.sh?ref=main",
		Assets:       `[{"arch":"any","asset":"2---stretched-covers.lua","url":"` + srv.URL + `/2---stretched-covers.lua"}]`,
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{ID: "koreader-5", Name: "Koreader", Version: "0.0.0-source", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	if err := manager.InstallAsset("koreader-5", "2---stretched-covers.lua"); err != nil {
		t.Fatal(err)
	}

	if installed, _ := st.ReadInstalled(); len(installed) != 0 {
		t.Fatalf("installed_packages = %#v, want empty", installed)
	}
	files, err := st.ReadInstalledPatchFiles()
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].PackageID != "koreader-5" || files[0].Asset != "2---stretched-covers.lua" {
		t.Fatalf("installed patch files = %#v, want koreader-5 / 2---stretched-covers.lua", files)
	}
}

func TestSourcePatchRepoTracksPerFileStateWithoutPatchCategory(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "#!/bin/sh\n")
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:           "koreader-5",
		Name:         "Koreader",
		Version:      "0.0.0-source",
		Repo:         "ZenLabs",
		Platforms:    []string{"koreader"},
		InstallURL:   srv.URL + "/install.sh",
		UninstallURL: srv.URL + "/uninstall.sh",
		Source:       "https://github.com/SeriousHornet/KOReader.patches",
		Assets:       `[{"arch":"any","asset":"2---stretched-covers.lua","url":"https://raw.githubusercontent.com/SeriousHornet/KOReader.patches/HEAD/2---stretched-covers.lua"}]`,
	}}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	if err := manager.InstallAsset("koreader-5", "2---stretched-covers.lua"); err != nil {
		t.Fatal(err)
	}

	if installed, _ := st.ReadInstalled(); len(installed) != 0 {
		t.Fatalf("installed_packages = %#v, want empty", installed)
	}
	files, err := st.ReadInstalledPatchFiles()
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].PackageID != "koreader-5" || files[0].Asset != "2---stretched-covers.lua" {
		t.Fatalf("installed patch files = %#v, want koreader-5 / 2---stretched-covers.lua", files)
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
	if err := manager.Uninstall("zen-koreader", ""); err != nil {
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

func TestInstallEnvUsesSourceArchiveForSourcePatchAsset(t *testing.T) {
	m := &Manager{plat: "host"}
	env := m.installEnv(&repo.CatalogEntry{
		ID:         "koreader-11",
		Source:     "https://github.com/sebdelsol/KOReader.patches",
		SourceType: "source",
		SourceURL:  "https://codeload.github.com/sebdelsol/KOReader.patches/zip/refs/heads/master",
		Assets:     `[{"arch":"any","asset":"2--ui-font.lua","size":"3473"}]`,
	}, "2--ui-font.lua")

	if got := env["ZENPM_PACKAGE_SOURCE"]; got != "https://codeload.github.com/sebdelsol/KOReader.patches/zip/refs/heads/master" {
		t.Fatalf("ZENPM_PACKAGE_SOURCE = %q", got)
	}
	if got := env["ZENPM_PACKAGE_SOURCE_ASSET"]; got != "2--ui-font.lua" {
		t.Fatalf("ZENPM_PACKAGE_SOURCE_ASSET = %q", got)
	}
	if got := env["ZENPM_PACKAGE_ASSET_URL"]; got != "" {
		t.Fatalf("ZENPM_PACKAGE_ASSET_URL = %q, want empty for source archive asset", got)
	}
	if got := env["ZENPM_PACKAGE_ASSET_SIZE"]; got != "3473" {
		t.Fatalf("ZENPM_PACKAGE_ASSET_SIZE = %q", got)
	}
	if got := env["ZENPM_PACKAGE_ASSET_ARCH"]; got != "any" {
		t.Fatalf("ZENPM_PACKAGE_ASSET_ARCH = %q", got)
	}
}

func TestInstallEnvUsesDirectSourceAssetURLForSourcePatchAsset(t *testing.T) {
	m := &Manager{plat: "host"}
	env := m.installEnv(&repo.CatalogEntry{
		ID:         "koreader-11",
		Source:     "https://github.com/sebdelsol/KOReader.patches",
		SourceType: "source",
		Assets:     `[{"arch":"any","asset":"2--ui-font.lua","url":"https://raw.githubusercontent.com/sebdelsol/KOReader.patches/main/2--ui-font.lua","size":"4185"}]`,
	}, "2--ui-font.lua")

	if got := env["ZENPM_PACKAGE_SOURCE"]; got != "https://raw.githubusercontent.com/sebdelsol/KOReader.patches/main/2--ui-font.lua" {
		t.Fatalf("ZENPM_PACKAGE_SOURCE = %q", got)
	}
	if got := env["ZENPM_PACKAGE_SOURCE_ASSET"]; got != "2--ui-font.lua" {
		t.Fatalf("ZENPM_PACKAGE_SOURCE_ASSET = %q", got)
	}
	if got := env["ZENPM_PACKAGE_ASSET_URL"]; got != "" {
		t.Fatalf("ZENPM_PACKAGE_ASSET_URL = %q, want empty for source asset", got)
	}
	if got := env["ZENPM_PACKAGE_ASSET_SIZE"]; got != "4185" {
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

func TestKOReaderRootUsesPluginDirectoryEnvironment(t *testing.T) {
	root := filepath.Join(t.TempDir(), "koreader")
	plugins := filepath.Join(root, "plugins")
	if err := os.MkdirAll(plugins, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)

	got, err := (&Manager{plat: "host"}).koreaderRoot()
	if err != nil {
		t.Fatal(err)
	}
	if got != root {
		t.Fatalf("koreaderRoot() = %q, want %q", got, root)
	}
}

func TestKOReaderRootUsesExplicitAndroidPluginDirectory(t *testing.T) {
	root := filepath.Join(t.TempDir(), "koreader")
	if err := os.MkdirAll(filepath.Join(root, "plugins"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZENPM_KOREADER_ROOT", root)

	got, err := (&Manager{plat: "host"}).koreaderRoot()
	if err != nil {
		t.Fatal(err)
	}
	if got != root {
		t.Fatalf("koreaderRoot() = %q, want %q", got, root)
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
