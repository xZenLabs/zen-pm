package pkg

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
)

func TestScanKOReaderPluginsRecordsMatchedExternalPlugins(t *testing.T) {
	manager, st, plugins := newKOReaderScanner(t, []state.CatalogEntry{
		{ID: "mapped-package", Name: "Mapped", Version: "9.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "mapped"},
		{ID: "mapped", Name: "ID Match", Version: "9.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "another-module"},
		{ID: "fallback", Name: "Fallback", Version: "9.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"}},
		{ID: "hello-package", Name: "Hello", Version: "9.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "hello"},
		{ID: "patch-package", Name: "Patch", Version: "9.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "patch", Category: "patches"},
	})
	writeKOReaderPlugin(t, plugins, "mapped", `return { version = "1.2.3" }`)
	writeKOReaderPlugin(t, plugins, "fallback", `return { fullname = "Fallback" }`)
	writeKOReaderPlugin(t, plugins, "hello", `return { version = "99.0.0" }`)
	writeKOReaderPlugin(t, plugins, "patch", `return { version = "99.0.0" }`)
	writeKOReaderPlugin(t, plugins, "unmatched", `return { version = "99.0.0" }`)
	if err := os.Mkdir(filepath.Join(plugins, "not-a-plugin"), 0755); err != nil {
		t.Fatal(err)
	}

	result, err := manager.ScanKOReaderPlugins(false)
	if err != nil {
		t.Fatal(err)
	}
	if result.Scanned != 4 || result.Matched != 2 || result.Added != 4 || result.Updated != 0 {
		t.Fatalf("scan result = %+v", result)
	}

	installed, err := st.ReadInstalled()
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]state.InstalledEntry{}
	for _, entry := range installed {
		got[entry.ID] = entry
	}
	if got["mapped-package"].Version != "1.2.3" || got["fallback"].Version != "0.0.0" ||
		got["unmatched"].Version != "99.0.0" || got["unmatched"].Name != "unmatched" ||
		got["unmatched"].InstallPath != filepath.Join(plugins, "unmatched.koplugin") ||
		got["patch"].InstallPath != filepath.Join(plugins, "patch.koplugin") || len(got) != 4 {
		t.Fatalf("installed = %#v, want matched and unmatched plugin directories", got)
	}
	marker, err := st.ReadValue(koreaderPluginsScannedKey)
	if err != nil || marker != "1" {
		t.Fatalf("scan marker = %q, %v; want 1, nil", marker, err)
	}
}

func TestScanKOReaderPluginsReadsVersionFallbackFiles(t *testing.T) {
	manager, st, plugins := newKOReaderScanner(t, []state.CatalogEntry{
		{ID: "version-file", Name: "Version File", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "version-file"},
		{ID: "build-info", Name: "Build Info", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "build-info"},
	})
	versionPath := writeKOReaderPlugin(t, plugins, "version-file", `return { fullname = "Version File" }`)
	if err := os.WriteFile(filepath.Join(filepath.Dir(versionPath), "VERSION"), []byte(" 1.2.3\n"), 0644); err != nil {
		t.Fatal(err)
	}
	buildInfoPath := writeKOReaderPlugin(t, plugins, "build-info", `return { fullname = "Build Info" }`)
	if err := os.WriteFile(filepath.Join(filepath.Dir(buildInfoPath), "BUILD_INFO.json"), []byte(`{"version":"4.5.6"}`), 0644); err != nil {
		t.Fatal(err)
	}

	if _, err := manager.ScanKOReaderPlugins(false); err != nil {
		t.Fatal(err)
	}
	if _, version := st.IsInstalled("version-file"); version != "1.2.3" {
		t.Fatalf("VERSION version = %q, want 1.2.3", version)
	}
	if _, version := st.IsInstalled("build-info"); version != "4.5.6" {
		t.Fatalf("BUILD_INFO.json version = %q, want 4.5.6", version)
	}
}

func TestScanKOReaderPluginsKeepsKnownInstalledVersionWhenMetadataHasNone(t *testing.T) {
	manager, st, plugins := newKOReaderScanner(t, []state.CatalogEntry{{
		ID: "reader", Name: "Reader", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "reader",
	}})
	writeKOReaderPlugin(t, plugins, "reader", `return { fullname = "Reader" }`)
	if err := st.AppendInstalled(state.InstalledEntry{ID: "reader", Name: "Reader", Version: "1.2.3", Repo: "ZenLabs"}); err != nil {
		t.Fatal(err)
	}

	result, err := manager.ScanKOReaderPlugins(true)
	if err != nil {
		t.Fatal(err)
	}
	if result.Updated != 1 {
		t.Fatalf("scan result = %+v, want install path update", result)
	}
	if _, version := st.IsInstalled("reader"); version != "1.2.3" {
		t.Fatalf("installed version = %q, want 1.2.3", version)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].InstallPath != filepath.Join(plugins, "reader.koplugin") {
		t.Fatalf("installed plugin = %#v, %v", installed, err)
	}
}

func TestUninstallUnmatchedKOReaderPluginRemovesDetectedDirectory(t *testing.T) {
	manager, st, plugins := newKOReaderScanner(t, []state.CatalogEntry{{
		ID: "local-plugin", Name: "Different Host Package", Repo: "ZenLabs", Platforms: []string{"host"},
	}})
	writeKOReaderPlugin(t, plugins, "local-plugin", `return { version = "1.2.3" }`)

	if _, err := manager.ScanKOReaderPlugins(false); err != nil {
		t.Fatal(err)
	}
	if err := manager.Uninstall("local-plugin", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(plugins, "local-plugin.koplugin")); !os.IsNotExist(err) {
		t.Fatalf("unmatched plugin directory remains after uninstall: %v", err)
	}
	if installed, _ := st.IsInstalled("local-plugin"); installed {
		t.Fatal("unmatched plugin remains installed after uninstall")
	}
}

func TestScanKOReaderPluginsAutomaticOnceManualRescans(t *testing.T) {
	manager, st, plugins := newKOReaderScanner(t, []state.CatalogEntry{{
		ID: "reader", Name: "Reader", Version: "9.0.0", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "reader",
	}})
	meta := writeKOReaderPlugin(t, plugins, "reader", `return { version = "1.0.0" }`)

	if result, err := manager.ScanKOReaderPlugins(false); err != nil || result.Added != 1 {
		t.Fatalf("first scan = %+v, %v", result, err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{
		ID: "reader", Name: "Reader", Version: "1.0.0", Repo: "ZenLabs", Asset: "reader-armv7.koplugin.zip", AssetArch: "armv7",
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(meta, []byte(`return { version = "2.0.0" }`), 0644); err != nil {
		t.Fatal(err)
	}
	if result, err := manager.ScanKOReaderPlugins(false); err != nil || !result.Skipped {
		t.Fatalf("second automatic scan = %+v, %v; want skipped", result, err)
	}
	if _, version := st.IsInstalled("reader"); version != "1.0.0" {
		t.Fatalf("version after skipped scan = %q, want 1.0.0", version)
	}
	if result, err := manager.ScanKOReaderPlugins(true); err != nil || result.Updated != 1 {
		t.Fatalf("manual scan = %+v, %v", result, err)
	}
	if _, version := st.IsInstalled("reader"); version != "2.0.0" {
		t.Fatalf("version after manual scan = %q, want 2.0.0", version)
	}
	installed, err := st.ReadInstalled()
	if err != nil || len(installed) != 1 || installed[0].Asset != "reader-armv7.koplugin.zip" || installed[0].AssetArch != "armv7" {
		t.Fatalf("installed after manual scan = %#v, %v", installed, err)
	}
}

func TestScanKOReaderPluginsDoesNotMarkUnavailableOrEmptyCatalog(t *testing.T) {
	manager, st, _ := newKOReaderScanner(t, []state.CatalogEntry{{
		ID: "reader", Name: "Reader", Repo: "ZenLabs", Platforms: []string{"koreader"}, PluginModule: "reader",
	}})
	if _, err := manager.ScanKOReaderPlugins(false); err == nil {
		t.Fatal("scan without a plugins directory succeeded")
	}
	if marker, _ := st.ReadValue(koreaderPluginsScannedKey); marker != "" {
		t.Fatalf("marker after unavailable scan = %q, want empty", marker)
	}

	emptyManager, emptyState, plugins := newKOReaderScanner(t, nil)
	writeKOReaderPlugin(t, plugins, "reader", `return { version = "1.0.0" }`)
	if _, err := emptyManager.ScanKOReaderPlugins(false); err == nil {
		t.Fatal("scan with empty catalog succeeded")
	}
	if marker, _ := emptyState.ReadValue(koreaderPluginsScannedKey); marker != "" {
		t.Fatalf("marker after empty catalog scan = %q, want empty", marker)
	}
}

func TestUnmanagedKOReaderPatchesListsOnlyUntrackedPatchFiles(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	root := filepath.Join(t.TempDir(), "koreader")
	patches := filepath.Join(root, "patches")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_DIR", root)
	if err := os.MkdirAll(patches, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	for name := range map[string]bool{
		"managed.lua":           false,
		"unmanaged.lua":         false,
		"disabled.lua.disabled": false,
		"not-a-patch.txt":       false,
	} {
		if err := os.WriteFile(filepath.Join(patches, name), nil, 0644); err != nil {
			t.Fatal(err)
		}
	}

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalledPatchFile(state.PatchFileEntry{PackageID: "managed", Asset: "managed.lua"}); err != nil {
		t.Fatal(err)
	}
	patchesFound, err := New(st, repo.New(st), "host").UnmanagedKOReaderPatches()
	if err != nil {
		t.Fatal(err)
	}
	if len(patchesFound) != 2 || patchesFound[0].Asset != "disabled.lua" || !patchesFound[0].Disabled || patchesFound[1].Asset != "unmanaged.lua" || patchesFound[1].Disabled {
		t.Fatalf("unmanaged patches = %#v", patchesFound)
	}
}

func newKOReaderScanner(t *testing.T, catalog []state.CatalogEntry) (*Manager, *state.State, string) {
	t.Helper()
	home := filepath.Join(t.TempDir(), "ZenPM")
	plugins := filepath.Join(t.TempDir(), "plugins")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_KOREADER_PLUGIN_DIR", plugins)
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog(catalog); err != nil {
		t.Fatal(err)
	}
	return New(st, repo.New(st), "host"), st, plugins
}

func writeKOReaderPlugin(t *testing.T, plugins, name, meta string) string {
	t.Helper()
	path := filepath.Join(plugins, name+".koplugin")
	if err := os.MkdirAll(path, 0755); err != nil {
		t.Fatal(err)
	}
	metaPath := filepath.Join(path, "_meta.lua")
	if err := os.WriteFile(metaPath, []byte(meta), 0644); err != nil {
		t.Fatal(err)
	}
	return metaPath
}
