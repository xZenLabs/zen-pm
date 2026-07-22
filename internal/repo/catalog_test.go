package repo

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"

	"github.com/xZenLabs/zen-pm/internal/state"
)

func TestCacheInstalledUninstallScriptsSkipsNativeKOReaderPackages(t *testing.T) {
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AppendInstalled(state.InstalledEntry{ID: "reader-plugin"}); err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Write([]byte("#!/bin/sh\n"))
	}))
	defer srv.Close()

	New(st).CacheInstalledUninstallScripts([]*CatalogEntry{{
		ID: "reader-plugin", Platforms: []string{"kindle", "koreader"}, UninstallURL: srv.URL,
	}})

	if requests.Load() != 0 {
		t.Fatalf("uninstall script requests = %d, want 0", requests.Load())
	}
	if _, err := os.Stat(st.CachedUninstallScriptPath("reader-plugin")); !os.IsNotExist(err) {
		t.Fatalf("cached uninstall script exists or could not be checked: %v", err)
	}
}

func TestFilterByPlatformRequiresAllEntryPlatforms(t *testing.T) {
	entries := []*CatalogEntry{
		{ID: "kindle-only", Platforms: []string{"kindle"}},
		{ID: "koreader-only", Platforms: []string{"koreader"}},
		{ID: "kindle-koreader", Platforms: []string{"kindle", "koreader"}},
		{ID: "kobo-koreader", Platforms: []string{"kobo", "koreader"}},
	}

	filtered := FilterByPlatform(entries, "kindle,koreader")

	assertEntryIDs(t, filtered, []string{"kindle-only", "koreader-only", "kindle-koreader"})
}

func TestFilterByPlatformExcludesMultiPlatformEntryWhenAnyRequirementMissing(t *testing.T) {
	entries := []*CatalogEntry{
		{ID: "kindle-only", Platforms: []string{"kindle"}},
		{ID: "kindle-koreader", Platforms: []string{"kindle", "koreader"}},
	}

	filtered := FilterByPlatform(entries, "kindle")

	assertEntryIDs(t, filtered, []string{"kindle-only"})
}

func TestFilterByPlatformDoesNotShowKindleKoreaderOnKoboKoreader(t *testing.T) {
	entries := []*CatalogEntry{
		{ID: "koreader-only", Platforms: []string{"koreader"}},
		{ID: "kobo-only", Platforms: []string{"kobo"}},
		{ID: "kindle-koreader", Platforms: []string{"kindle", "koreader"}},
	}

	filtered := FilterByPlatform(entries, "kobo,koreader")

	assertEntryIDs(t, filtered, []string{"koreader-only", "kobo-only"})
}

func TestFilterByPlatformTreatsKindleForgeAsKindle(t *testing.T) {
	entries := []*CatalogEntry{
		{ID: "kindle-only", Platforms: []string{"kindle"}},
		{ID: "kindleforge-only", Platforms: []string{"kindleforge"}},
	}

	filtered := FilterByPlatform(entries, "kindle")

	assertEntryIDs(t, filtered, []string{"kindle-only", "kindleforge-only"})
}

func TestFilterByPlatformSupportsAndroidKoreader(t *testing.T) {
	entries := []*CatalogEntry{
		{ID: "android-only", Platforms: []string{"android"}},
		{ID: "android-koreader", Platforms: []string{"android", "koreader"}},
		{ID: "not-android", Platforms: []string{"koreader"}, IncompatiblePlatforms: []string{"android", "host"}},
		{ID: "host-only", Platforms: []string{"host"}},
	}

	filtered := FilterByPlatform(entries, "android,koreader")

	assertEntryIDs(t, filtered, []string{"android-only", "android-koreader"})

	filtered = FilterByPlatform(entries, "host,koreader")

	assertEntryIDs(t, filtered, []string{"host-only"})
}

func TestKindleForgeCategoryUsesFirstMappedTag(t *testing.T) {
	got := kindleForgeCategory([]string{"unknown", "Audio", "Games"})
	if got != "media" {
		t.Fatalf("kindleForgeCategory() = %q, want %q", got, "media")
	}
}

func TestParseKindleForgeCatalogMapsTagsToCategory(t *testing.T) {
	entries := parseKindleForgeCatalog("KindleForge", "https://example.invalid", 1, []kfRegistryEntry{
		{URI: "notebook", Tags: []string{"tools", "games"}},
	})

	if len(entries) != 1 {
		t.Fatalf("got %d entries, want 1", len(entries))
	}
	if entries[0].Category != "utility" {
		t.Fatalf("Category = %q, want %q", entries[0].Category, "utility")
	}
	if entries[0].InstallURL != "https://example.invalid/notebook/install.sh" {
		t.Fatalf("InstallURL = %q", entries[0].InstallURL)
	}
	if entries[0].UninstallURL != "https://example.invalid/notebook/uninstall.sh" {
		t.Fatalf("UninstallURL = %q", entries[0].UninstallURL)
	}
}

func TestFetchCatalogUsesKindleForgeRegistryOnly(t *testing.T) {
	var manifestRequests int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/manifest.json":
			atomic.AddInt32(&manifestRequests, 1)
			http.Error(w, "manifest should not be fetched", http.StatusInternalServerError)
		case "/registry.json":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`[{"name":"Notebook","uri":"notebook","tags":["tools"]}]`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	entries, err := FetchCatalog("KindleForge", srv.URL, 1, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(&manifestRequests); got != 0 {
		t.Fatalf("manifest requests = %d, want 0", got)
	}
	assertEntryIDs(t, entries, []string{"notebook"})
}

func TestCatalogSourceAssetRoundTrip(t *testing.T) {
	featuredOrder := 10
	entry := &CatalogEntry{
		Repo:                  "ZenLabs",
		Priority:              10,
		ID:                    "sudoku-koplugin",
		Name:                  "Sudoku",
		Version:               "1.2.1",
		InstallURL:            "install.sh",
		Source:                "omer-faruq/sudoku.koplugin",
		SourceAsset:           "sudoku.koplugin.zip",
		SourceType:            "release",
		SourceURL:             "https://example.invalid/source.zip",
		Stars:                 "42",
		Assets:                `[{"arch":"arm","asset":"pkg.zip","url":"https://example.invalid/pkg.zip","size":"12"}]`,
		Constraints:           `{"abi":["hf","sf"]}`,
		Conflicts:             []string{"zen-ui"},
		IncompatiblePlatforms: []string{"android", "host"},
		FeaturedOrder:         &featuredOrder,
		ReadmeURL:             "https://example.invalid/readme.md",
	}

	got, err := parseCatalogLine(entry.serialize())
	if err != nil {
		t.Fatal(err)
	}
	if got.SourceAsset != entry.SourceAsset {
		t.Fatalf("SourceAsset = %q, want %q", got.SourceAsset, entry.SourceAsset)
	}
	if got.Stars != entry.Stars {
		t.Fatalf("Stars = %q, want %q", got.Stars, entry.Stars)
	}
	if got.FeaturedOrder == nil || *got.FeaturedOrder != featuredOrder {
		t.Fatalf("FeaturedOrder = %v, want %d", got.FeaturedOrder, featuredOrder)
	}
	if got.SourceType != entry.SourceType || got.SourceURL != entry.SourceURL || got.Assets != entry.Assets || got.Constraints != entry.Constraints || got.ReadmeURL != entry.ReadmeURL || len(got.Conflicts) != 1 || got.Conflicts[0] != "zen-ui" || len(got.IncompatiblePlatforms) != 2 || got.IncompatiblePlatforms[0] != "android" || got.IncompatiblePlatforms[1] != "host" {
		t.Fatalf("round trip = %#v, want source/assets fields from %#v", got, entry)
	}
}

func TestParseZenPMCatalogIncludesManifestDBFields(t *testing.T) {
	manifest := manifestJSON{}
	if err := json.Unmarshal([]byte(`{
		"packages": [
			{
				"id": "koreader-rsvp-plugin",
				"name": "Koreader Rsvp Plugin",
				"version": "0.0.0-source",
				"platforms": ["koreader"],
				"install_url": "packages/koreader/install-plugin.sh",
				"uninstall_url": "packages/koreader/uninstall-plugin.sh",
				"source": "https://github.com/karpushchenko/koreader-rsvp-plugin",
				"source_type": "source",
				"source_url": "https://codeload.github.com/karpushchenko/koreader-rsvp-plugin/zip/refs/heads/main",
				"readme_url": "packages/koreader/koreader-rsvp-plugin/README.md",
				"featured_order": 10,
				"stars": "31",
				"assets": [{"arch":"arm","asset":"plugin.zip","url":"https://example.invalid/plugin.zip","size":"12"}],
				"constraints": {"abi":["hf","sf"]},
				"conflicts": ["zen-ui"],
				"incompatible_platforms": ["android", "host"],
				"launcher": {"kobo":{"type":"nickelmenu"}}
			},
			{
				"id": "koreader-null-stars",
				"name": "Koreader Null Stars",
				"version": "0.0.0-source",
				"platforms": ["koreader"],
				"install_url": "packages/koreader/install-plugin.sh",
				"stars": null
			},
			{
				"id": "kindle-browser",
				"name": "Kindle Browser",
				"version": "1.0.0",
				"platforms": ["kindle"]
			}
		]
	}`), &manifest); err != nil {
		t.Fatal(err)
	}

	entries := parseZenPMCatalog("ZenLabs", "https://example.invalid/repo", 10, manifest)
	if len(entries) != 3 {
		t.Fatalf("got %d entries, want 3", len(entries))
	}
	if entries[0].Stars != "31" {
		t.Fatalf("Stars = %q, want %q", entries[0].Stars, "31")
	}
	if entries[0].SourceType != "source" {
		t.Fatalf("SourceType = %q, want source", entries[0].SourceType)
	}
	if entries[0].SourceURL != "https://codeload.github.com/karpushchenko/koreader-rsvp-plugin/zip/refs/heads/main" {
		t.Fatalf("SourceURL = %q", entries[0].SourceURL)
	}
	if entries[0].ReadmeURL != "https://example.invalid/repo/packages/koreader/koreader-rsvp-plugin/README.md" {
		t.Fatalf("ReadmeURL = %q", entries[0].ReadmeURL)
	}
	if entries[0].UninstallURL != "https://example.invalid/repo/packages/koreader/uninstall-plugin.sh" {
		t.Fatalf("UninstallURL = %q", entries[0].UninstallURL)
	}
	if entries[0].Assets != `[{"arch":"arm","asset":"plugin.zip","url":"https://example.invalid/plugin.zip","size":"12"}]` {
		t.Fatalf("Assets = %q", entries[0].Assets)
	}
	if entries[0].Constraints != `{"abi":["hf","sf"]}` {
		t.Fatalf("Constraints = %q", entries[0].Constraints)
	}
	if len(entries[0].Conflicts) != 1 || entries[0].Conflicts[0] != "zen-ui" {
		t.Fatalf("Conflicts = %#v", entries[0].Conflicts)
	}
	if len(entries[0].IncompatiblePlatforms) != 2 || entries[0].IncompatiblePlatforms[0] != "android" || entries[0].IncompatiblePlatforms[1] != "host" {
		t.Fatalf("IncompatiblePlatforms = %#v", entries[0].IncompatiblePlatforms)
	}
	if entries[0].FeaturedOrder == nil || *entries[0].FeaturedOrder != 10 {
		t.Fatalf("FeaturedOrder = %v, want 10", entries[0].FeaturedOrder)
	}
	if entries[1].Stars != "" {
		t.Fatalf("null Stars = %q, want empty", entries[1].Stars)
	}
	if entries[2].InstallURL != "https://example.invalid/repo/packages/kindle/kindle-browser/scripts/install.sh" {
		t.Fatalf("Kindle InstallURL = %q", entries[2].InstallURL)
	}
	if entries[2].UninstallURL != "https://example.invalid/repo/packages/kindle/kindle-browser/scripts/uninstall.sh" {
		t.Fatalf("Kindle UninstallURL = %q", entries[2].UninstallURL)
	}
}

func TestFillMissingKindleScriptURLsForCachedCatalog(t *testing.T) {
	entries := []*CatalogEntry{{
		Repo:      "ZenLabs",
		ID:        "kindle-browser",
		Platforms: []string{"kindle"},
	}}
	fillMissingKindleScriptURLs(entries, []state.RepoEntry{{Name: "ZenLabs", URL: "https://example.invalid/repo"}})

	if entries[0].InstallURL != "https://example.invalid/repo/packages/kindle/kindle-browser/scripts/install.sh" {
		t.Fatalf("Kindle InstallURL = %q", entries[0].InstallURL)
	}
	if entries[0].UninstallURL != "https://example.invalid/repo/packages/kindle/kindle-browser/scripts/uninstall.sh" {
		t.Fatalf("Kindle UninstallURL = %q", entries[0].UninstallURL)
	}
}

func assertEntryIDs(t *testing.T, entries []*CatalogEntry, want []string) {
	t.Helper()
	if len(entries) != len(want) {
		t.Fatalf("got %d entries, want %d", len(entries), len(want))
	}
	for i, entry := range entries {
		if entry.ID != want[i] {
			t.Fatalf("entry %d = %q, want %q", i, entry.ID, want[i])
		}
	}
}
