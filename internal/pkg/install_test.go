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
	"syscall"
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

func TestKindleScriptEnvUsesRSACABundle(t *testing.T) {
	st := &state.State{CABundle: "/tmp/cacert.pem", RSACABundle: "/tmp/cacert-rsa.pem"}
	env := (&Manager{st: st, plat: platform.Kindle}).baseScriptEnv("package")
	if got := env["CURL_CA_BUNDLE"]; got != st.RSACABundle {
		t.Fatalf("CURL_CA_BUNDLE = %q, want %q", got, st.RSACABundle)
	}
	if got := env["SSL_CERT_FILE"]; got != st.RSACABundle {
		t.Fatalf("SSL_CERT_FILE = %q, want %q", got, st.RSACABundle)
	}
	if got := env["ZENPM_USE_GO_CURL"]; got != "1" {
		t.Fatalf("ZENPM_USE_GO_CURL = %q, want 1", got)
	}
}

func TestNonKindleScriptEnvUsesFullCABundle(t *testing.T) {
	st := &state.State{CABundle: "/tmp/cacert.pem", RSACABundle: "/tmp/cacert-rsa.pem"}
	env := (&Manager{st: st, plat: platform.Kobo}).baseScriptEnv("package")
	if got := env["CURL_CA_BUNDLE"]; got != st.CABundle {
		t.Fatalf("CURL_CA_BUNDLE = %q, want %q", got, st.CABundle)
	}
	if got := env["ZENPM_USE_GO_CURL"]; got != "" {
		t.Fatalf("ZENPM_USE_GO_CURL = %q, want empty", got)
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

func TestInstallKOReaderPluginUnwrapsPluginsDirectory(t *testing.T) {
	t.Setenv("ZENPM_HOME", filepath.Join(t.TempDir(), "ZenPM"))
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	plugins := filepath.Join(root, "plugins")
	if err := os.MkdirAll(plugins, 0755); err != nil {
		t.Fatal(err)
	}

	data := zipContents(t, map[string]string{
		"plugins/zlibrary.koplugin/_meta.lua": `return { version = "1.0.41" }`,
		"plugins/zlibrary.koplugin/main.lua":  "return {}\n",
	})
	version, path, err := (&Manager{st: st}).installKOReaderPlugin(&repo.CatalogEntry{
		ID: "zlibrary-2", PluginModule: "zlibrary",
	}, root, "zlibrary_plugin_v1.0.41.zip", data)
	if err != nil {
		t.Fatal(err)
	}
	if version != "1.0.41" {
		t.Fatalf("installed version = %q, want 1.0.41", version)
	}
	destination := filepath.Join(plugins, "zlibrary.koplugin")
	if path != destination {
		t.Fatalf("installed path = %q, want %q", path, destination)
	}
	if _, err := os.Stat(filepath.Join(destination, "_meta.lua")); err != nil {
		t.Fatalf("plugin metadata missing at destination: %v", err)
	}
	if _, err := os.Stat(filepath.Join(destination, "zlibrary.koplugin")); !os.IsNotExist(err) {
		t.Fatalf("nested plugin directory exists or could not be checked: %v", err)
	}
}

func TestReplaceTreeStagesBeforeRemovingExistingPlugin(t *testing.T) {
	root := t.TempDir()
	destination := filepath.Join(root, "plugins", "zen_ui.koplugin")
	font := filepath.Join(destination, "fonts", "ZenUI.ttf")
	if err := os.MkdirAll(filepath.Dir(font), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(font, []byte("installed font"), 0644); err != nil {
		t.Fatal(err)
	}

	err := replaceTree(filepath.Join(root, "missing-update"), destination)
	if err == nil {
		t.Fatal("replaceTree succeeded with a missing update tree")
	}
	if data, readErr := os.ReadFile(font); readErr != nil || string(data) != "installed font" {
		t.Fatalf("installed plugin changed before the replacement was ready: %q, %v", data, readErr)
	}

	update := filepath.Join(root, "update")
	if err := os.MkdirAll(update, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(update, "main.lua"), []byte("return {}\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := replaceTree(update, destination); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(destination, "main.lua")); err != nil {
		t.Fatalf("updated plugin missing: %v", err)
	}
	if _, err := os.Stat(font); !os.IsNotExist(err) {
		t.Fatalf("old non-empty font tree remains after update: %v", err)
	}
}

func TestReplaceTreeContinuesWhenStageChmodIsNotPermitted(t *testing.T) {
	root := t.TempDir()
	update := filepath.Join(root, "update")
	destination := filepath.Join(root, "plugins", "reader.koplugin")
	if err := os.MkdirAll(filepath.Dir(destination), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(update, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(update, "main.lua"), []byte("return {}\n"), 0644); err != nil {
		t.Fatal(err)
	}

	originalChmodInstallStage := chmodInstallStage
	chmodInstallStage = func(string, os.FileMode) error { return syscall.EPERM }
	defer func() { chmodInstallStage = originalChmodInstallStage }()

	if err := replaceTree(update, destination); err != nil {
		t.Fatalf("replaceTree failed when chmod was not permitted: %v", err)
	}
	if _, err := os.Stat(filepath.Join(destination, "main.lua")); err != nil {
		t.Fatalf("installed plugin missing: %v", err)
	}
}

func TestInstallGenericPluginReplacesConflictingPluginRecord(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	koHome := t.TempDir()
	t.Setenv("HOME", koHome)
	koRoot := filepath.Join(koHome, ".config", "koreader")
	plugins := filepath.Join(koRoot, "plugins")
	if err := os.MkdirAll(plugins, 0755); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	archive := zipContents(t, map[string]string{
		"plugins/zlibrary.koplugin/_meta.lua": `return { version = "1.0.41" }`,
	})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/zlibrary.zip" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(archive)
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{
		{ID: "zlibrary", Name: "Old Zlibrary", Version: "1.1.0", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "zlibrary"},
		{ID: "zlibrary-2", Name: "ZlibraryKO", Version: "1.0.41", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "zlibrary", Assets: `[{"arch":"any","asset":"zlibrary_plugin_v1.0.41.zip","url":"` + srv.URL + `/zlibrary.zip"}]`},
	}); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(plugins, "zlibrary.koplugin")
	if err := st.AppendInstalled(state.InstalledEntry{ID: "zlibrary", Name: "Old Zlibrary", Version: "1.1.0", Repo: "ZenLabs", InstallPath: destination}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Install("zlibrary-2"); err != nil {
		t.Fatal(err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].ID != "zlibrary-2" || installed[0].InstallPath != destination {
		t.Fatalf("installed packages = %#v, %v", installed, err)
	}
}

func TestInstallGenericPluginReplacesUntrackedPluginRecordWithSameAsset(t *testing.T) {
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

	archive := zipContents(t, map[string]string{
		"zlibrary.koplugin/_meta.lua": `return { version = "1.0.41" }`,
	})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/zlibrary.zip" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(archive)
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zlibrary-2", Name: "ZlibraryKO", Version: "1.0.41", Repo: "ZenLabs",
		Platforms: []string{"koreader"}, PluginModule: "zlibrary",
		Assets: "[{\"arch\":\"any\",\"asset\":\"zlibrary_plugin_v1.0.41.zip\",\"url\":\"" + srv.URL + "/zlibrary.zip\"}]",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "local-plugin:zlibrary", Name: "zlibrary", Version: "1.0.0", Asset: "zlibrary.koplugin",
	}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Install("zlibrary-2"); err != nil {
		t.Fatal(err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].ID != "zlibrary-2" {
		t.Fatalf("installed packages = %#v, %v", installed, err)
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

func TestDownloadInstallAssetUsesVersionsAssetForRequestedSourceRelease(t *testing.T) {
	assetServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/release.zip" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte("release source zip contents"))
	}))
	defer assetServer.Close()
	versionsServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"releases":[{"tag_name":"v0.2.3","assets":[{"name":"source-code.zip","url":"` + assetServer.URL + `/release.zip"}]}]}`))
	}))
	defer versionsServer.Close()
	entry := &repo.CatalogEntry{
		ID:          "koinsight",
		Platforms:   []string{"koreader"},
		Source:      "https://github.com/Ko-Insight/KoInsight",
		SourceType:  "source",
		SourceURL:   assetServer.URL + "/branch.zip",
		VersionsURL: versionsServer.URL,
	}

	name, gotURL, data, err := (&Manager{}).downloadInstallAsset(entry, "source-code.zip", "v0.2.3")
	if err != nil {
		t.Fatal(err)
	}
	if name != "source-code.zip" || gotURL != assetServer.URL+"/release.zip" || string(data) != "release source zip contents" {
		t.Fatalf("download = %q, %q, %q", name, gotURL, data)
	}
}

func TestDownloadInstallAssetUsesSourceURLWithoutSourceReleases(t *testing.T) {
	assetServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("current source zip contents"))
	}))
	defer assetServer.Close()
	entry := &repo.CatalogEntry{
		ID:         "koinsight",
		Platforms:  []string{"koreader"},
		Source:     "https://github.com/Ko-Insight/KoInsight",
		SourceType: "source",
		SourceURL:  assetServer.URL,
	}

	name, gotURL, data, err := (&Manager{}).downloadInstallAsset(entry, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if name != ".koplugin.zip" || gotURL != assetServer.URL || string(data) != "current source zip contents" {
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

func transitionalZenOSCatalogEntry(version, versionsURL string) state.CatalogEntry {
	return state.CatalogEntry{
		ID: "zen-ui", Name: "ZenOS", Version: version, Repo: "ZenLabs", Platforms: []string{"koreader"},
		SourceType: "release", SourceAsset: "zen_ui.koplugin.zip", VersionsURL: versionsURL,
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"}, SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}
}

func TestTransitionalManifestUpdatesExistingLegacyRootInPlace(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	legacyPath := filepath.Join(plugins, "zen_ui.koplugin")
	if err := os.MkdirAll(legacyPath, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacyPath, "_meta.lua"), []byte(`return { version = "2.5.4" }`), 0644); err != nil {
		t.Fatal(err)
	}
	compatZIP := zipContents(t, map[string]string{
		"zen_ui.koplugin/_meta.lua": `return { version = "3.0.0" }`,
	})
	var releasesServer *httptest.Server
	releasesServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/versions.json":
			_, _ = io.WriteString(w, `{"releases":[{"tag_name":"v3.0.0","assets":[`+
				`{"name":"zen_ui.koplugin.zip","url":"`+releasesServer.URL+`/zen_ui.koplugin.zip"}]}]}`)
		case "/zen_ui.koplugin.zip":
			_, _ = w.Write(compatZIP)
		default:
			http.NotFound(w, r)
		}
	}))
	defer releasesServer.Close()

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{
		transitionalZenOSCatalogEntry("3.0.0", releasesServer.URL+"/versions.json"),
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "ZenOS", Version: "2.5.4", Repo: "ZenLabs",
		Asset: "zen_ui.koplugin.zip", InstallPath: legacyPath,
	}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Update("zen-ui"); err != nil {
		t.Fatal(err)
	}
	if version, err := koreaderPluginVersion(legacyPath); err != nil || version != "3.0.0" {
		t.Fatalf("legacy root version = %q, %v", version, err)
	}
	if _, err := os.Lstat(filepath.Join(plugins, "zenos.koplugin")); !os.IsNotExist(err) {
		t.Fatalf("transitional update created canonical root: %v", err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].Asset != "zen_ui.koplugin.zip" || installed[0].InstallPath != legacyPath {
		t.Fatalf("transitional installed record = %#v, %v", installed, err)
	}
}

func TestTransitionalManifestCanonicalUpdateRefusesWithoutCanonicalAsset(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	canonicalPath := filepath.Join(plugins, "zenos.koplugin")
	if err := os.MkdirAll(canonicalPath, 0755); err != nil {
		t.Fatal(err)
	}
	metaPath := filepath.Join(canonicalPath, "_meta.lua")
	if err := os.WriteFile(metaPath, []byte(`return { version = "2.5.4" }`), 0644); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(canonicalPath, "keep.txt")
	if err := os.WriteFile(marker, []byte("unchanged"), 0644); err != nil {
		t.Fatal(err)
	}
	compatZIP := zipContents(t, map[string]string{
		"zen_ui.koplugin/_meta.lua": `return { version = "3.0.0" }`,
	})
	var releasesServer *httptest.Server
	releasesServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/versions.json":
			_, _ = io.WriteString(w, `{"releases":[{"tag_name":"v3.0.0","assets":[`+
				`{"name":"zen_ui.koplugin.zip","url":"`+releasesServer.URL+`/zen_ui.koplugin.zip"}]}]}`)
		case "/zen_ui.koplugin.zip":
			_, _ = w.Write(compatZIP)
		default:
			http.NotFound(w, r)
		}
	}))
	defer releasesServer.Close()

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{
		transitionalZenOSCatalogEntry("3.0.0", releasesServer.URL+"/versions.json"),
	}); err != nil {
		t.Fatal(err)
	}
	want := state.InstalledEntry{
		ID: "zen-ui", Name: "ZenOS", Version: "2.5.4", Repo: "ZenLabs",
		Asset: "zenos.koplugin.zip", InstallPath: canonicalPath,
	}
	if err := st.AppendInstalled(want); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Update("zen-ui"); err == nil {
		t.Fatal("canonical update unexpectedly succeeded without a canonical asset")
	}
	if version, err := koreaderPluginVersion(canonicalPath); err != nil || version != "2.5.4" {
		t.Fatalf("canonical root version changed = %q, %v", version, err)
	}
	if data, err := os.ReadFile(marker); err != nil || string(data) != "unchanged" {
		t.Fatalf("canonical root changed after rejected update: %q, %v", data, err)
	}
	if _, err := os.Lstat(filepath.Join(plugins, "zen_ui.koplugin")); !os.IsNotExist(err) {
		t.Fatalf("rejected canonical update created legacy root: %v", err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].Name != want.Name || installed[0].Version != want.Version ||
		installed[0].Asset != want.Asset || installed[0].InstallPath != want.InstallPath {
		t.Fatalf("installed record changed after rejected canonical update: %#v, %v", installed, err)
	}
}

func TestTransitionalManifestUninstallsCanonicalRootOnly(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	canonicalPath := filepath.Join(plugins, "zenos.koplugin")
	otherPath := filepath.Join(plugins, "other.koplugin")
	for _, path := range []string{canonicalPath, otherPath} {
		if err := os.MkdirAll(path, 0755); err != nil {
			t.Fatal(err)
		}
	}
	otherMarker := filepath.Join(otherPath, "keep.txt")
	if err := os.WriteFile(otherMarker, []byte("keep"), 0644); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{
		transitionalZenOSCatalogEntry("3.0.0", ""),
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "ZenOS", Version: "3.0.0", Repo: "ZenLabs",
		Asset: "zenos.koplugin.zip", InstallPath: canonicalPath,
	}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Uninstall("zen-ui", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(canonicalPath); !os.IsNotExist(err) {
		t.Fatalf("canonical root remains after uninstall: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(plugins, "zen_ui.koplugin")); !os.IsNotExist(err) {
		t.Fatalf("canonical uninstall changed legacy root state: %v", err)
	}
	if data, err := os.ReadFile(otherMarker); err != nil || string(data) != "keep" {
		t.Fatalf("canonical uninstall changed unrelated plugin: %q, %v", data, err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 0 {
		t.Fatalf("installed record remains after canonical uninstall: %#v, %v", installed, err)
	}
}

func TestUpdateGenericPluginStaysOnExistingAliasRoot(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	legacyPath := filepath.Join(plugins, "zen_ui.koplugin")
	if err := os.MkdirAll(legacyPath, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacyPath, "_meta.lua"), []byte(`return { version = "2.5.4" }`), 0644); err != nil {
		t.Fatal(err)
	}

	canonicalZIP := zipContents(t, map[string]string{
		"zenos.koplugin/_meta.lua": `return { version = "3.0.0" }`,
	})
	compatZIP := zipContents(t, map[string]string{
		"zen_ui.koplugin/_meta.lua": `return { version = "3.0.0" }`,
	})
	var releasesServer *httptest.Server
	releasesServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/versions.json":
			_, _ = io.WriteString(w, `{"releases":[{"tag_name":"v3.0.0","assets":[`+
				`{"name":"zenos.koplugin.zip","url":"`+releasesServer.URL+`/zenos.koplugin.zip"},`+
				`{"name":"zen_ui.koplugin.zip","url":"`+releasesServer.URL+`/zen_ui.koplugin.zip"}]}]}`)
		case "/zenos.koplugin.zip":
			_, _ = w.Write(canonicalZIP)
		case "/zen_ui.koplugin.zip":
			_, _ = w.Write(compatZIP)
		default:
			http.NotFound(w, r)
		}
	}))
	defer releasesServer.Close()

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Version: "3.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"},
		SourceType: "release", SourceAsset: "zenos.koplugin.zip", VersionsURL: releasesServer.URL + "/versions.json",
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"}, SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "Zen UI", Version: "2.5.4", Repo: "ZenLabs",
		Asset: "zen_ui.koplugin.zip", InstallPath: legacyPath,
	}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Update("zen-ui"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(plugins, "zenos.koplugin")); !os.IsNotExist(err) {
		t.Fatalf("update created a side-by-side canonical root: %v", err)
	}
	if version, err := koreaderPluginVersion(legacyPath); err != nil || version != "3.0.0" {
		t.Fatalf("legacy compatibility root version = %q, %v", version, err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].Name != "ZenOS" ||
		installed[0].Asset != "zen_ui.koplugin.zip" || installed[0].InstallPath != legacyPath {
		t.Fatalf("updated installed record = %#v, %v", installed, err)
	}
}

func TestReinstallGenericPluginAllowsHistoricLegacyAssetAfterCanonicalRemoval(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	canonicalPath := filepath.Join(plugins, "zenos.koplugin")
	if err := os.MkdirAll(canonicalPath, 0755); err != nil {
		t.Fatal(err)
	}
	legacyZIP := zipContents(t, map[string]string{
		"zen_ui.koplugin/_meta.lua": `return { version = "2.5.4" }`,
	})
	var releasesServer *httptest.Server
	releasesServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/versions.json":
			_, _ = io.WriteString(w, `{"releases":[{"tag_name":"v2.5.4","assets":[`+
				`{"name":"zen_ui.koplugin.zip","url":"`+releasesServer.URL+`/zen_ui.koplugin.zip"}]}]}`)
		case "/zen_ui.koplugin.zip":
			_, _ = w.Write(legacyZIP)
		default:
			http.NotFound(w, r)
		}
	}))
	defer releasesServer.Close()

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Version: "3.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"},
		Source: "https://github.com/owner/zen_ui.koplugin", SourceType: "release",
		SourceAsset: "zenos.koplugin.zip", VersionsURL: releasesServer.URL + "/versions.json",
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"}, SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "ZenOS", Version: "3.0.0", Repo: "ZenLabs",
		Asset: "zenos.koplugin.zip", InstallPath: canonicalPath,
	}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Reinstall("zen-ui", "zen_ui.koplugin.zip", "v2.5.4"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(canonicalPath); !os.IsNotExist(err) {
		t.Fatalf("canonical root remains after historic downgrade: %v", err)
	}
	legacyPath := filepath.Join(plugins, "zen_ui.koplugin")
	if version, err := koreaderPluginVersion(legacyPath); err != nil || version != "2.5.4" {
		t.Fatalf("historic legacy root version = %q, %v", version, err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].Asset != "zen_ui.koplugin.zip" || installed[0].InstallPath != legacyPath {
		t.Fatalf("historic installed record = %#v, %v", installed, err)
	}
}

func TestInstallGenericPluginRejectsCanonicalAndAliasRoots(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	for _, module := range []string{"zenos", "zen_ui"} {
		path := filepath.Join(plugins, module+".koplugin")
		if err := os.MkdirAll(path, 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "keep.txt"), []byte(module), 0644); err != nil {
			t.Fatal(err)
		}
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Version: "3.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"},
		SourceAsset: "zenos.koplugin.zip", PluginModule: "zenos",
		PluginModuleAliases: []string{"zen_ui"}, SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{ID: "zen-ui", Name: "ZenOS", Version: "3.0.0", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}

	err = New(st, repo.New(st), "host").Install("zen-ui")
	if err == nil || !strings.Contains(err.Error(), "multiple plugin roots") {
		t.Fatalf("Install() error = %v", err)
	}
	for _, module := range []string{"zenos", "zen_ui"} {
		data, readErr := os.ReadFile(filepath.Join(plugins, module+".koplugin", "keep.txt"))
		if readErr != nil || string(data) != module {
			t.Fatalf("%s root changed after rejected install: %q, %v", module, data, readErr)
		}
	}
	installed, readErr := st.ReadInstalled()
	if readErr != nil || len(installed) != 1 || installed[0].Name != "ZenOS" || installed[0].InstallPath != "" {
		t.Fatalf("installed record changed after rejected install: %#v, %v", installed, readErr)
	}
}

func TestNewReconcilesInstalledPluginAliasRecord(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	canonicalPath := filepath.Join(plugins, "zenos.koplugin")
	if err := os.MkdirAll(canonicalPath, 0755); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Platforms: []string{"koreader"},
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zenos.koplugin.zip", SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "Zen UI", Version: "3.0.0", Repo: "ZenLabs",
		Asset: "zen_ui.koplugin.zip", InstallPath: filepath.Join(plugins, "zen_ui.koplugin"),
	}); err != nil {
		t.Fatal(err)
	}

	New(st, repo.New(st), "host")
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 {
		t.Fatalf("installed = %#v, %v", installed, err)
	}
	if installed[0].Name != "ZenOS" || installed[0].Asset != "zenos.koplugin.zip" || installed[0].InstallPath != canonicalPath {
		t.Fatalf("reconciled installed record = %#v", installed[0])
	}
}

func TestNewRefusesAliasRecordOutsidePluginDirs(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	canonicalPath := filepath.Join(plugins, "zenos.koplugin")
	if err := os.MkdirAll(canonicalPath, 0755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(canonicalPath, "keep.txt")
	if err := os.WriteFile(marker, []byte("unchanged"), 0644); err != nil {
		t.Fatal(err)
	}
	outsidePath := filepath.Join(t.TempDir(), "zen_ui.koplugin")
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Platforms: []string{"koreader"},
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zenos.koplugin.zip", SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "Zen UI", Version: "3.0.0", Repo: "ZenLabs",
		Asset: "zen_ui.koplugin.zip", InstallPath: outsidePath,
	}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 {
		t.Fatalf("installed = %#v, %v", installed, err)
	}
	if installed[0].Name != "Zen UI" || installed[0].Asset != "zen_ui.koplugin.zip" || installed[0].InstallPath != outsidePath {
		t.Fatalf("outside tracked record was reconciled: %#v", installed[0])
	}
	err = manager.Install("zen-ui")
	if err == nil || !strings.Contains(err.Error(), "outside configured plugin identity roots") {
		t.Fatalf("Install() error = %v", err)
	}
	if data, readErr := os.ReadFile(marker); readErr != nil || string(data) != "unchanged" {
		t.Fatalf("canonical root changed after rejected install: %q, %v", data, readErr)
	}
}

func TestUninstallGenericPluginRemovesTrackedAliasRoot(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	legacyPath := filepath.Join(plugins, "zen_ui.koplugin")
	if err := os.MkdirAll(legacyPath, 0755); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Platforms: []string{"koreader"},
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zenos.koplugin.zip", SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "Zen UI", Version: "2.5.4", Repo: "ZenLabs",
		Asset: "zen_ui.koplugin.zip", InstallPath: legacyPath,
	}); err != nil {
		t.Fatal(err)
	}

	manager := &Manager{st: st, repos: repo.New(st), plat: "host"}
	if err := manager.Uninstall("zen-ui", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("tracked legacy plugin root remains after uninstall: %v", err)
	}
}

func TestUninstallGenericPluginResolvesRelativeAliasPluginDir(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	root := filepath.Join(t.TempDir(), "koreader")
	pluginsOverride := filepath.Join("external", "plugins")
	plugins := filepath.Join(root, pluginsOverride)
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_DIR", root)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", pluginsOverride)
	if err := os.MkdirAll(plugins, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	legacyPath := filepath.Join(plugins, "zen_ui.koplugin")
	if err := os.MkdirAll(legacyPath, 0755); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Platforms: []string{"koreader"},
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zenos.koplugin.zip", SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "Zen UI", Version: "2.5.4", Repo: "ZenLabs",
		Asset: "zen_ui.koplugin.zip", InstallPath: legacyPath,
	}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "test").Uninstall("zen-ui", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("relative alias plugin root remains after uninstall: %v", err)
	}
}

func TestInstallKOReaderPluginRejectsAliasArchiveRootMismatch(t *testing.T) {
	t.Setenv("ZENPM_HOME", filepath.Join(t.TempDir(), "ZenPM"))
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	canonicalPath := filepath.Join(plugins, "zenos.koplugin")
	if err := os.MkdirAll(canonicalPath, 0755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(canonicalPath, "keep.txt")
	if err := os.WriteFile(marker, []byte("unchanged"), 0644); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	data := zipContents(t, map[string]string{
		"zen_ui.koplugin/_meta.lua": `return { version = "3.0.0" }`,
	})
	_, _, err = (&Manager{st: st, plat: "host"}).installKOReaderPlugin(&repo.CatalogEntry{
		ID: "zen-ui", PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zenos.koplugin.zip", SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}, filepath.Dir(plugins), "zenos.koplugin.zip", data)
	if err == nil || !strings.Contains(err.Error(), "does not match selected asset root") {
		t.Fatalf("installKOReaderPlugin() error = %v", err)
	}
	if data, readErr := os.ReadFile(marker); readErr != nil || string(data) != "unchanged" {
		t.Fatalf("existing canonical root changed after archive mismatch: %q, %v", data, readErr)
	}
}

func TestInstallKOReaderPluginKeepsAliasInAlternateConfiguredDir(t *testing.T) {
	t.Setenv("ZENPM_HOME", filepath.Join(t.TempDir(), "ZenPM"))
	primaryRoot := filepath.Join(t.TempDir(), "primary")
	secondaryRoot := filepath.Join(t.TempDir(), "secondary")
	t.Setenv("ZENPM_KOREADER_DIR", primaryRoot)
	t.Setenv("KOREADER_DIR", secondaryRoot)
	if err := os.MkdirAll(primaryRoot, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(primaryRoot, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	legacyPath := filepath.Join(secondaryRoot, "plugins", "zen_ui.koplugin")
	if err := os.MkdirAll(legacyPath, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(secondaryRoot, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	data := zipContents(t, map[string]string{
		"zen_ui.koplugin/_meta.lua": `return { version = "3.0.0" }`,
	})
	_, installedPath, err := (&Manager{st: st, plat: "host"}).installKOReaderPlugin(&repo.CatalogEntry{
		ID: "zen-ui", PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zenos.koplugin.zip", SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}, primaryRoot, "zen_ui.koplugin.zip", data)
	if err != nil {
		t.Fatal(err)
	}
	if installedPath != legacyPath {
		t.Fatalf("installed path = %q, want %q", installedPath, legacyPath)
	}
	if _, err := os.Stat(filepath.Join(primaryRoot, "plugins")); !os.IsNotExist(err) {
		t.Fatalf("install created primary plugins directory: %v", err)
	}
}

func TestUninstallGenericPluginUnlinksAliasSymlinkOnly(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink semantics differ on Windows")
	}
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	if err := os.MkdirAll(plugins, 0755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "outside-target")
	if err := os.MkdirAll(target, 0755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(target, "keep.txt")
	if err := os.WriteFile(marker, []byte("keep"), 0644); err != nil {
		t.Fatal(err)
	}
	legacyPath := filepath.Join(plugins, "zen_ui.koplugin")
	if err := os.Symlink(target, legacyPath); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Platforms: []string{"koreader"},
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zenos.koplugin.zip", SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Asset: "zen_ui.koplugin.zip", InstallPath: legacyPath,
	}); err != nil {
		t.Fatal(err)
	}
	manager := &Manager{st: st, repos: repo.New(st), plat: "host"}
	if err := manager.Uninstall("zen-ui", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(legacyPath); !os.IsNotExist(err) {
		t.Fatalf("legacy symlink remains after uninstall: %v", err)
	}
	if data, err := os.ReadFile(marker); err != nil || string(data) != "keep" {
		t.Fatalf("symlink target changed during uninstall: %q, %v", data, err)
	}
}

func TestUninstallGenericPluginRejectsTrackedPathOutsidePluginDirs(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	legacyPath := filepath.Join(plugins, "zen_ui.koplugin")
	outsidePath := filepath.Join(t.TempDir(), "zen_ui.koplugin")
	for _, path := range []string{legacyPath, outsidePath} {
		if err := os.MkdirAll(path, 0755); err != nil {
			t.Fatal(err)
		}
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Platforms: []string{"koreader"},
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zenos.koplugin.zip", SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Asset: "zen_ui.koplugin.zip", InstallPath: outsidePath,
	}); err != nil {
		t.Fatal(err)
	}
	manager := &Manager{st: st, repos: repo.New(st), plat: "host"}
	err = manager.Uninstall("zen-ui", "")
	if err == nil || !strings.Contains(err.Error(), "outside configured plugin identity roots") {
		t.Fatalf("Uninstall() error = %v", err)
	}
	for _, path := range []string{legacyPath, outsidePath} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("plugin path %s changed after rejected uninstall: %v", path, err)
		}
	}
}

func TestUninstallGenericPluginRejectsConflictingIdentityPath(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	legacyPath := filepath.Join(plugins, "zen_ui.koplugin")
	if err := os.MkdirAll(legacyPath, 0755); err != nil {
		t.Fatal(err)
	}
	canonicalPath := filepath.Join(plugins, "zenos.koplugin")
	if err := os.WriteFile(canonicalPath, []byte("conflict"), 0644); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Platforms: []string{"koreader"},
		PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zenos.koplugin.zip", SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Asset: "zenos.koplugin.zip", InstallPath: canonicalPath,
	}); err != nil {
		t.Fatal(err)
	}
	manager := &Manager{st: st, repos: repo.New(st), plat: "host"}
	err = manager.Uninstall("zen-ui", "")
	if err == nil || !strings.Contains(err.Error(), "path conflict") {
		t.Fatalf("Uninstall() error = %v", err)
	}
	if _, err := os.Stat(legacyPath); err != nil {
		t.Fatalf("legacy root changed after path conflict: %v", err)
	}
	if data, err := os.ReadFile(canonicalPath); err != nil || string(data) != "conflict" {
		t.Fatalf("conflicting path changed after rejected uninstall: %q, %v", data, err)
	}
}

func TestKOReaderPluginAssetForModuleSupportsLegacySourceAsset(t *testing.T) {
	entry := &repo.CatalogEntry{
		ID: "zen-ui", PluginModule: "zenos", PluginModuleAliases: []string{"zen_ui"},
		SourceAsset: "zen_ui.koplugin.zip",
	}
	if got := koreaderPluginAssetForModule(entry, "zen_ui"); got != "zen_ui.koplugin.zip" {
		t.Fatalf("legacy module asset = %q", got)
	}
	if module, ok := koreaderPluginModuleForAsset(entry, "zen_ui.koplugin.zip"); !ok || module != "zen_ui" {
		t.Fatalf("legacy source asset module = %q, %t", module, ok)
	}
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

func TestInstallEnvUsesStandardKindleKOReaderPath(t *testing.T) {
	t.Setenv("ZENPM_KOREADER_DIR", "")
	t.Setenv("ZENPM_KOREADER_ROOT", "")
	t.Setenv("KOREADER_DIR", "")
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", "")
	m := &Manager{plat: "kindle"}
	env := m.installEnv(&repo.CatalogEntry{ID: "patch"}, "")

	want := "/mnt/us/koreader"
	if got := env["ZENPM_KOREADER_PATHS"]; got != want {
		t.Fatalf("ZENPM_KOREADER_PATHS = %q, want %q", got, want)
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

func TestSelectAssetKeepsLegacyCandidateForPreAliasInstalledRecord(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Platforms: []string{"koreader"},
		SourceAsset: "zenos.koplugin.zip", PluginModule: "zenos",
		Assets: `[{"arch":"any","asset":"zenos.koplugin.zip"},{"arch":"any","asset":"zen_ui.koplugin.zip"}]`,
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "Zen UI", Version: "2.5.4", Repo: "ZenLabs", Asset: "zen_ui.koplugin.zip",
	}); err != nil {
		t.Fatal(err)
	}

	result, err := New(st, repo.New(st), "host").SelectAsset("zen-ui")
	if err != nil {
		t.Fatal(err)
	}
	if result.NeedsChoice || result.Auto != "zen_ui.koplugin.zip" {
		t.Fatalf("SelectAsset = %+v, want recorded legacy candidate", result)
	}
}

func TestSelectAssetUsesPluginIdentityRoot(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	if err := os.MkdirAll(plugins, 0755); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "zen-ui", Name: "ZenOS", Repo: "ZenLabs", Platforms: []string{"koreader"},
		SourceAsset: "zenos.koplugin.zip", PluginModule: "zenos",
		PluginModuleAliases: []string{"zen_ui"}, SourceAssetAliases: []string{"zen_ui.koplugin.zip"},
		Assets: `[{"arch":"any","asset":"zenos.koplugin.zip"},{"arch":"any","asset":"zen_ui.koplugin.zip"}]`,
	}}); err != nil {
		t.Fatal(err)
	}
	manager := New(st, repo.New(st), "host")
	if result, err := manager.SelectAsset("zen-ui"); err != nil || result.Auto != "zenos.koplugin.zip" || result.NeedsChoice {
		t.Fatalf("fresh SelectAsset = %+v, %v", result, err)
	}

	legacyPath := filepath.Join(plugins, "zen_ui.koplugin")
	if err := os.Mkdir(legacyPath, 0755); err != nil {
		t.Fatal(err)
	}
	if result, err := manager.SelectAsset("zen-ui"); err != nil || result.Auto != "zen_ui.koplugin.zip" || result.NeedsChoice {
		t.Fatalf("legacy-root SelectAsset = %+v, %v", result, err)
	}
	if err := os.RemoveAll(legacyPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(plugins, "zenos.koplugin"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "zen-ui", Name: "Zen UI", Version: "3.0.0", Repo: "ZenLabs", Asset: "zen_ui.koplugin.zip",
	}); err != nil {
		t.Fatal(err)
	}
	if result, err := manager.SelectAsset("zen-ui"); err != nil || result.Auto != "zenos.koplugin.zip" || result.NeedsChoice {
		t.Fatalf("canonical-root SelectAsset = %+v, %v", result, err)
	}
	if err := os.Mkdir(legacyPath, 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.SelectAsset("zen-ui"); err == nil || !strings.Contains(err.Error(), "matches multiple KOReader plugin directories") {
		t.Fatalf("dual-root SelectAsset error = %v", err)
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

func TestKOReaderRootCandidatesIgnoreRelativePluginDirectory(t *testing.T) {
	t.Setenv("ZENPM_KOREADER_DIR", "")
	t.Setenv("ZENPM_KOREADER_ROOT", "")
	t.Setenv("KOREADER_DIR", "")
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", "plugins")
	if got := koreaderRootCandidates("test"); len(got) != 0 {
		t.Fatalf("relative plugin directory inferred KOReader root candidates: %#v", got)
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

func TestUpdateSkipsIgnoredInstalledPackages(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "2.0.0", Repo: "ZenLabs", InstallURL: "https://example.invalid/install.sh",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "ZenLabs", UpdateIgnored: true,
	}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Update(""); err != nil {
		t.Fatal(err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].Version != "1.0.0" || !installed[0].UpdateIgnored {
		t.Fatalf("installed = %#v, %v", installed, err)
	}
}

func TestUpdateSkipsOnlyMatchingIgnoredUpdateVersion(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "pkg", Name: "Package", Version: "2.0.0", Repo: "ZenLabs", InstallURL: "https://example.invalid/install.sh",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "pkg", Name: "Package", Version: "1.0.0", Repo: "ZenLabs", UpdateIgnoredVersion: "2.0.0",
	}); err != nil {
		t.Fatal(err)
	}

	if err := New(st, repo.New(st), "host").Update(""); err != nil {
		t.Fatal(err)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].Version != "1.0.0" || installed[0].UpdateIgnoredVersion != "2.0.0" {
		t.Fatalf("installed = %#v, %v", installed, err)
	}
}
