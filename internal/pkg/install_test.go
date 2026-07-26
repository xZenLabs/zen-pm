package pkg

import (
	"archive/zip"
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/xZenLabs/zen-pm/internal/platform"
	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
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
	koHome := t.TempDir()
	t.Setenv("HOME", koHome)
	koRoot := filepath.Join(koHome, ".config", "koreader")
	if err := os.MkdirAll(filepath.Join(koRoot, "plugins"), 0755); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	metadata := `return { version = "1.2.3" }`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/plugin.koplugin.zip":
			w.Write(zipContents(t, map[string]string{"plugin.koplugin/_meta.lua": metadata}))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:        "plugin",
		Name:      "Plugin",
		Version:   "1.0.0",
		Repo:      "ZenLabs",
		Platforms: []string{"koreader"},
		Source:    "https://github.com/owner/plugin",
		Assets:    `[{"arch":"any","asset":"plugin.koplugin.zip","url":"` + srv.URL + `/plugin.koplugin.zip"}]`,
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
	if _, err := os.Stat(filepath.Join(koRoot, ".zenpm-plugins")); !os.IsNotExist(err) {
		t.Fatalf("plugin tracking directory exists after install: %v", err)
	}
	if _, version := st.IsInstalled("plugin"); version != "1.2.3" {
		t.Fatalf("installed version = %q, want 1.2.3", version)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].Asset != "plugin.koplugin.zip" || installed[0].AssetArch != "any" {
		t.Fatalf("installed = %#v, %v", installed, err)
	}
	if err := manager.Uninstall("plugin", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, "plugins", "plugin.koplugin")); !os.IsNotExist(err) {
		t.Fatalf("native plugin was not removed: %v", err)
	}

	metadata = "return {}"
	if err := manager.Install("plugin"); err != nil {
		t.Fatal(err)
	}
	if _, version := st.IsInstalled("plugin"); version != "" {
		t.Fatalf("installed version = %q, want empty", version)
	}
}

func TestRemoveKOReaderPluginResolvesRelativePluginDirectory(t *testing.T) {
	root := t.TempDir()
	plugin := filepath.Join(root, "plugins", "storefront.koplugin")
	if err := os.MkdirAll(plugin, 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", "plugins")

	if err := removeKOReaderPlugin(root, "storefront.koplugin"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(plugin); !os.IsNotExist(err) {
		t.Fatalf("native plugin was not removed: %v", err)
	}
}

func TestInstallGenericFontNatively(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	koHome := t.TempDir()
	t.Setenv("HOME", koHome)
	koRoot := filepath.Join(koHome, ".config", "koreader")
	if err := os.MkdirAll(filepath.Join(koRoot, "plugins"), 0755); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/font-cartisse.zip" {
			http.NotFound(w, r)
			return
		}
		w.Write(zipContents(t, map[string]string{
			"Cartisse/Cartisse-Regular.ttf": "regular",
			"Cartisse/Cartisse-Bold.otf":    "bold",
			"Cartisse/LICENSE":              "license",
		}))
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "font-cartisse", Name: "Cartisse", Version: "4.1", Repo: "ZenLabs",
		Category: "fonts", Platforms: []string{"koreader"},
		Assets: `[{
			"arch":"any","asset":"font-cartisse.zip","url":"` + srv.URL + `/font-cartisse.zip"
		}]`,
	}}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	if err := manager.InstallRelease("font-cartisse", "v999.0", "font-cartisse.zip"); err != nil {
		t.Fatal(err)
	}
	if installed, version := st.IsInstalled("font-cartisse"); !installed || version != "4.1" {
		t.Fatalf("installed font = %t %q, want true 4.1", installed, version)
	}
	for _, name := range []string{"Cartisse-Regular.ttf", "Cartisse-Bold.otf"} {
		if _, err := os.Stat(filepath.Join(koRoot, "fonts", "Cartisse", name)); err != nil {
			t.Fatalf("font %s was not installed: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(koRoot, "fonts", "Cartisse", "LICENSE")); err != nil {
		t.Fatalf("font package contents were not preserved: %v", err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].InstallPath != filepath.Join(koRoot, "fonts", "Cartisse") {
		t.Fatalf("installed fonts = %#v, %v", installed, err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, ".zenpm-fonts")); !os.IsNotExist(err) {
		t.Fatalf("font tracking directory exists after install: %v", err)
	}

	if err := manager.Uninstall("font-cartisse", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, "fonts", "Cartisse")); !os.IsNotExist(err) {
		t.Fatalf("font directory remains after uninstall: %v", err)
	}
}

func TestDownloadInstallAssetRequiresVersionsMetadataForRequestedRelease(t *testing.T) {
	entry := &repo.CatalogEntry{
		ID:     "plugin",
		Source: "https://github.com/owner/plugin",
		Assets: `[{
			"asset":"plugin.koplugin.zip",
			"url":"://catalog-release.zip"
		}]`,
	}

	_, _, _, err := (&Manager{}).downloadInstallAsset(entry, "plugin.koplugin.zip", "v1.4.3")
	if err == nil || !strings.Contains(err.Error(), "has no versions metadata") {
		t.Fatalf("download error = %v, want missing versions metadata error", err)
	}
}

func TestDownloadInstallAssetUsesVersionsURL(t *testing.T) {
	assetServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("zip contents"))
	}))
	defer assetServer.Close()
	versionsServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{
			"releases": [{
				"tag_name": "v1.40.0-pre",
				"assets": [{
					"name": "rakuyomi-kindlehf-v1.40.0-pre.zip",
					"url": "` + assetServer.URL + `",
					"size": 12,
					"digest": "sha256:test"
				}]
			}]
		}`))
	}))
	defer versionsServer.Close()
	entry := &repo.CatalogEntry{
		Source:      "https://github.com/tachibana-shin/rakuyomi",
		VersionsURL: versionsServer.URL,
	}

	name, gotURL, data, err := (&Manager{}).downloadInstallAsset(entry, "rakuyomi-kindlehf-v1.39.4.zip", "v1.40.0-pre")
	if err != nil {
		t.Fatal(err)
	}
	if name != "rakuyomi-kindlehf-v1.40.0-pre.zip" || gotURL != assetServer.URL || string(data) != "zip contents" {
		t.Fatalf("download = %q, %q, %q", name, gotURL, data)
	}
}

func TestDownloadInstallAssetRequiresExplicitFontURL(t *testing.T) {
	entry := &repo.CatalogEntry{
		ID:       "font-cartisse",
		Category: "fonts",
		Source:   "https://github.com/example/cartisse-fonts",
		Assets:   `[{"asset":"font-cartisse.zip"}]`,
	}

	_, _, _, err := (&Manager{}).downloadInstallAsset(entry, "font-cartisse.zip", "v4.1")
	if err == nil || !strings.Contains(err.Error(), "requires an explicit ZIP asset URL") {
		t.Fatalf("download error = %v, want explicit font ZIP URL error", err)
	}
}

func TestInstallGenericPatchNatively(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	koHome := t.TempDir()
	t.Setenv("HOME", koHome)
	koRoot := filepath.Join(koHome, ".config", "koreader")
	if err := os.MkdirAll(filepath.Join(koRoot, "plugins"), 0755); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/patch.zip" {
			http.NotFound(w, r)
			return
		}
		w.Write(zipContents(t, map[string]string{"patch/patch.lua": "return {}\n"}))
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
		Assets:     `[{"arch":"any","asset":"patch.zip","url":"` + srv.URL + `/patch.zip"}]`,
	}}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Install("patch"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, "patches", "patch", "patch.lua")); err != nil {
		t.Fatalf("native patch was not installed: %v", err)
	}
	patches, err := st.ReadInstalledPatchFiles()
	if err != nil || len(patches) != 1 || patches[0].InstallPath != filepath.Join(koRoot, "patches", "patch") {
		t.Fatalf("installed patch files = %#v, %v", patches, err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, ".zenpm-patches")); !os.IsNotExist(err) {
		t.Fatalf("patch tracking directory exists after install: %v", err)
	}
}

func TestNativeKOReaderInstallerClassifiesPackagesWithoutScripts(t *testing.T) {
	manager := &Manager{plat: "host"}
	patch := &repo.CatalogEntry{
		Platforms:  []string{"koreader"},
		Source:     "https://github.com/owner/patches",
		SourceType: "source",
		Assets:     `[{"asset":"patch.lua"}]`,
	}
	if got := manager.nativeKOReaderInstaller(patch, "patch.lua"); got != genericPatchInstaller {
		t.Fatalf("native patch installer = %q, want %q", got, genericPatchInstaller)
	}

	plugin := &repo.CatalogEntry{
		Platforms: []string{"koreader"},
	}
	if got := manager.nativeKOReaderInstaller(plugin, ""); got != genericPluginInstaller {
		t.Fatalf("native plugin installer = %q, want %q", got, genericPluginInstaller)
	}

	kindle := &repo.CatalogEntry{
		Platforms:  []string{"kindle"},
		InstallURL: "https://example.invalid/install.sh",
	}
	if got := manager.nativeKOReaderInstaller(kindle, ""); got != "" {
		t.Fatalf("native Kindle installer = %q, want empty", got)
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
	t.Setenv("ZENPM_HOME", home)
	koRoot := filepath.Join(t.TempDir(), "koreader")
	if err := os.MkdirAll(filepath.Join(koRoot, "patches"), 0755); err != nil {
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
		case "/2-menu-size.lua", "/2-ui-font.lua":
			io.WriteString(w, "return {}\n")
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:        "koreader-11",
		Name:      "Koreader",
		Version:   "0.0.0-source",
		Repo:      "ZenLabs",
		Category:  "patches",
		Platforms: []string{"koreader"},
		Assets:    `[{"arch":"any","asset":"2-menu-size.lua","url":"` + srv.URL + `/2-menu-size.lua"},{"arch":"any","asset":"2-ui-font.lua","url":"` + srv.URL + `/2-ui-font.lua"}]`,
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
	for _, file := range files {
		if file.InstallPath != filepath.Join(koRoot, "patches", file.Asset) {
			t.Fatalf("patch install path = %q, want %q", file.InstallPath, filepath.Join(koRoot, "patches", file.Asset))
		}
	}
	if _, err := os.Stat(filepath.Join(koRoot, ".zenpm-patches")); !os.IsNotExist(err) {
		t.Fatalf("patch tracking directory exists after install: %v", err)
	}

	if err := manager.Uninstall("koreader-11", "2-menu-size.lua"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(koRoot, "patches", "2-menu-size.lua")); !os.IsNotExist(err) {
		t.Fatalf("patch file remains after uninstall: %v", err)
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

func TestLegacyKOReaderTrackingMigratesToDatabase(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	root := filepath.Join(t.TempDir(), "koreader")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_DIR", root)
	if err := os.MkdirAll(filepath.Join(root, "plugins"), 0755); err != nil {
		t.Fatal(err)
	}
	fontPath := filepath.Join(root, "fonts", "Cartisse")
	patchPath := filepath.Join(root, "patches", "patch.lua")
	if err := os.MkdirAll(fontPath, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(patchPath), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(patchPath, []byte("return {}\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".zenpm-fonts"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".zenpm-fonts", "font-cartisse"), []byte("font_dir="+fontPath+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".zenpm-patches"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".zenpm-patches", "patch.lua"), []byte("patch_file="+patchPath+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".zenpm-plugins"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".zenpm-plugins", "legacy.koplugin"), nil, 0644); err != nil {
		t.Fatal(err)
	}

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{ID: "font-cartisse", Name: "Cartisse", Version: "4.1", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalledPatchFile(state.PatchFileEntry{PackageID: "patch", Asset: "patch.lua", Name: "Patch", Version: "1.0.0", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}

	New(st, repo.New(st), "host")

	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].InstallPath != fontPath {
		t.Fatalf("installed fonts after migration = %#v, %v", installed, err)
	}
	patches, err := st.ReadInstalledPatchFiles()
	if err != nil || len(patches) != 1 || patches[0].InstallPath != patchPath {
		t.Fatalf("installed patches after migration = %#v, %v", patches, err)
	}
	for _, directory := range []string{".zenpm-fonts", ".zenpm-patches", ".zenpm-plugins"} {
		if _, err := os.Stat(filepath.Join(root, directory)); !os.IsNotExist(err) {
			t.Fatalf("legacy tracking directory %s remains after migration: %v", directory, err)
		}
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
	koRoot := filepath.Join(t.TempDir(), "koreader")
	if err := os.MkdirAll(filepath.Join(koRoot, "patches"), 0755); err != nil {
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
		ID:        "koreader-5",
		Name:      "Koreader",
		Version:   "0.0.0-source",
		Repo:      "ZenLabs",
		Platforms: []string{"koreader"},
		Source:    "https://github.com/SeriousHornet/KOReader.patches",
		Assets:    `[{"arch":"any","asset":"2---stretched-covers.lua","url":"` + srv.URL + `/2---stretched-covers.lua"}]`,
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

func TestReinstallUninstallsBeforeInstalling(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	out := filepath.Join(t.TempDir(), "reinstall.out")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_REINSTALL_OUT", out)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/install.sh":
			io.WriteString(w, "#!/bin/sh\nprintf 'install\\n' >> \"$ZENPM_REINSTALL_OUT\"\n")
		case "/uninstall.sh":
			io.WriteString(w, "#!/bin/sh\nprintf 'uninstall\\n' >> \"$ZENPM_REINSTALL_OUT\"\n")
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "reader", Name: "Reader", Version: "1.0.0", Repo: "ZenLabs",
		InstallURL: srv.URL + "/install.sh", UninstallURL: srv.URL + "/uninstall.sh",
		Source: "https://github.com/owner/reader",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{ID: "reader", Name: "Reader", Version: "1.0.0", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Reinstall("reader", "", "v0.9.0"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(data); got != "uninstall\ninstall\n" {
		t.Fatalf("operation order = %q, want uninstall followed by install", got)
	}
	if installed, version := st.IsInstalled("reader"); !installed || version != "v0.9.0" {
		t.Fatalf("installed package = %t %q, want true v0.9.0", installed, version)
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
		case "/packages/kindle/zen-koreader/scripts/uninstall.sh":
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

func TestSelectAssetUsesAndroidDeviceForAndroidKOReaderCapabilities(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "reader", Name: "Reader", Version: "1.0.0", Repo: "ZenLabs", InstallURL: "install.sh",
		Assets: `[{"asset":"reader-android.zip"},{"asset":"reader-kindle.zip"}]`,
	}}); err != nil {
		t.Fatal(err)
	}

	result, err := New(st, repo.New(st), platform.AndroidKOReader).SelectAsset("reader")
	if err != nil {
		t.Fatal(err)
	}
	if result.NeedsChoice || result.Auto != "reader-android.zip" {
		t.Fatalf("SelectAsset = %+v, want Android asset", result)
	}
}

func TestManagerDeviceIncludesHostOS(t *testing.T) {
	if got := (&Manager{plat: "host"}).device().OS; got != runtime.GOOS {
		t.Fatalf("device OS = %q, want %q", got, runtime.GOOS)
	}
}

func TestSelectAssetReusesInstalledAssetWhenAmbiguous(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "localsend", Name: "LocalSend", Version: "1.4.1", Repo: "ZenLabs",
		Platforms: []string{"koreader"}, InstallURL: "packages/koreader/install-plugin.sh",
		Assets: `[{"arch":"arm","asset":"localsend-koplugin-v1.4.1-arm-legacy.zip"},{"arch":"armv7","asset":"localsend-koplugin-v1.4.1-armv7.zip"}]`,
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "localsend", Name: "LocalSend", Version: "1.4.0", Repo: "ZenLabs", Asset: "localsend-koplugin-v1.4.0-armv7.zip", AssetArch: "armv7",
	}); err != nil {
		t.Fatal(err)
	}

	result, err := New(st, repo.New(st), "host").SelectAsset("localsend")
	if err != nil {
		t.Fatal(err)
	}
	if result.NeedsChoice || result.Auto != "localsend-koplugin-v1.4.1-armv7.zip" {
		t.Fatalf("SelectAsset = %+v, want remembered armv7 asset", result)
	}
}

func TestAssetNamesMatchIgnoringVersion(t *testing.T) {
	if !assetNamesMatchIgnoringVersion("localsend-koplugin-v1.4.1-armv7.zip", "localsend-koplugin-v1.4.0-armv7.zip") {
		t.Fatal("versioned armv7 assets did not match")
	}
	if assetNamesMatchIgnoringVersion("localsend-koplugin-v1.4.1-armv7.zip", "localsend-koplugin-v1.4.0-arm64.zip") {
		t.Fatal("different architectures matched")
	}
}

func TestInstallAndUninstallEnvResolveKOReaderOverride(t *testing.T) {
	root := filepath.Join(t.TempDir(), "koreader")
	plugins := filepath.Join(root, "external", "plugins")
	patches := filepath.Join(root, "external", "patches")
	t.Setenv("ZENPM_KOREADER_DIR", root)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	t.Setenv("ZENPM_KOREADER_PATCH_DIR", patches)

	m := &Manager{plat: "kindle"}
	installEnv := m.installEnv(&repo.CatalogEntry{ID: "patch"}, "")
	uninstallEnv := m.uninstallEnv("patch")

	for name, env := range map[string]map[string]string{"install": installEnv, "uninstall": uninstallEnv} {
		if got := env["ZENPM_KOREADER_DIR"]; got != root {
			t.Fatalf("%s ZENPM_KOREADER_DIR = %q, want %q", name, got, root)
		}
		if got := env["ZENPM_KOREADER_PLUGIN_DIR"]; got != plugins {
			t.Fatalf("%s ZENPM_KOREADER_PLUGIN_DIR = %q, want %q", name, got, plugins)
		}
		if got := env["ZENPM_KOREADER_PATCH_DIR"]; got != patches {
			t.Fatalf("%s ZENPM_KOREADER_PATCH_DIR = %q, want %q", name, got, patches)
		}
	}
}

func TestKOReaderDirectoriesUseExplicitEnvironment(t *testing.T) {
	root := filepath.Join(t.TempDir(), "koreader")
	plugins := filepath.Join(root, "external", "plugins")
	patches := filepath.Join(root, "external", "patches")
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	t.Setenv("ZENPM_KOREADER_PATCH_DIR", patches)

	if got := koreaderPluginDir(root); got != plugins {
		t.Fatalf("koreaderPluginDir() = %q, want %q", got, plugins)
	}
	if got := koreaderPatchDir(root); got != patches {
		t.Fatalf("koreaderPatchDir() = %q, want %q", got, patches)
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
