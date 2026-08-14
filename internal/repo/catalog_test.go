package repo

import (
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xZenLabs/zen-pm/internal/log"
	"github.com/xZenLabs/zen-pm/internal/state"
)

func TestCacheInstalledUninstallScriptsSkipsNativeKOReaderPackages(t *testing.T) {
	t.Setenv("ZENPM_HOME", t.TempDir())
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

func TestAddRejectsKindleForgeOnUnsupportedPlatform(t *testing.T) {
	t.Setenv("ZENPM_HOME", t.TempDir())
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	err = New(st).Add("KindleForge", "https://kf.penguins184.xyz", UserAddedPriority, "trusted")
	if err == nil || !strings.Contains(err.Error(), "compatible Kindle") {
		t.Fatalf("Add KindleForge error = %v", err)
	}
}

func TestRefreshSkipsKindleForgeOnUnsupportedPlatform(t *testing.T) {
	t.Setenv("ZENPM_HOME", t.TempDir())
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteRepos([]state.RepoEntry{{
		Name: "KindleForge", URL: "file://" + t.TempDir(), Priority: 10, Trust: "trusted",
	}}); err != nil {
		t.Fatal(err)
	}

	if err := New(st).Refresh(); err != nil {
		t.Fatal(err)
	}
	catalog, err := st.ReadCatalog()
	if err != nil || len(catalog) != 0 {
		t.Fatalf("catalog after skipped KindleForge refresh = %#v, %v", catalog, err)
	}
}

func TestRefreshKeepsCatalogWhenRepositoriesAreUnavailable(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	t.Setenv("ZENPM_HOME", home)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WriteRepos([]state.RepoEntry{{
		Name: "offline", URL: "file://" + filepath.Join(t.TempDir(), "missing"), Priority: 10,
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID: "cached", Name: "Cached", Version: "1.0.0", Repo: "offline", Platforms: []string{"koreader"},
	}}); err != nil {
		t.Fatal(err)
	}

	err = New(st).Refresh()
	if err == nil {
		t.Fatal("Refresh() succeeded with no reachable repositories")
	}
	catalog, err := st.ReadCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if len(catalog) != 1 || catalog[0].ID != "cached" {
		t.Fatalf("catalog after failed refresh = %#v, want cached entry", catalog)
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

func TestFetchCatalogFallbackLogNamesActualRepository(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "zenpm.log")
	log.Init(logPath)
	defer log.Init("")

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/registry.json" {
			w.Write([]byte(`[{"name":"Notebook","uri":"notebook"}]`))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()

	if _, err := FetchCatalog("ZenLabs", srv.URL, 1, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	logs := string(data)
	if !strings.Contains(logs, "Fetching registry for repo ZenLabs:") {
		t.Fatalf("log = %q, want actual repository name", logs)
	}
	if strings.Contains(logs, "Fetching KindleForge registry") {
		t.Fatalf("log = %q, contains misleading KindleForge label", logs)
	}
}

func TestRegistryFallbackSkipsTransportErrors(t *testing.T) {
	transportErr := fmt.Errorf("clock hint: %w", &url.Error{
		Op:  "Get",
		URL: "https://repo.example/manifest.json",
		Err: fmt.Errorf("TLS certificate validation failed"),
	})
	if shouldTryRegistryFallback(transportErr) {
		t.Fatal("transport error triggered registry fallback")
	}
	if !shouldTryRegistryFallback(fmt.Errorf("HTTP 404 Not Found")) {
		t.Fatal("HTTP response error did not trigger registry fallback")
	}
}

func TestAddTLSClockHintExplainsNotYetValidCertificate(t *testing.T) {
	now := time.Date(2012, time.January, 15, 15, 38, 23, 0, time.UTC)
	notBefore := time.Date(2026, time.July, 17, 4, 51, 13, 0, time.UTC)
	certErr := x509.CertificateInvalidError{
		Cert:   &x509.Certificate{NotBefore: notBefore, NotAfter: notBefore.Add(90 * 24 * time.Hour)},
		Reason: x509.Expired,
	}
	err := addTLSClockHint(fmt.Errorf("request failed: %w", certErr), now)

	for _, want := range []string{"device clock appears incorrect", now.Format(time.RFC3339), notBefore.Format(time.RFC3339), "sync the device date and time"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error = %q, want %q", err, want)
		}
	}
}

func TestAddTLSClockHintLeavesExpiredCertificateErrorUnchanged(t *testing.T) {
	now := time.Date(2026, time.August, 4, 0, 0, 0, 0, time.UTC)
	certErr := x509.CertificateInvalidError{
		Cert:   &x509.Certificate{NotBefore: now.Add(-48 * time.Hour), NotAfter: now.Add(-24 * time.Hour)},
		Reason: x509.Expired,
	}
	err := fmt.Errorf("request failed: %w", certErr)

	if got := addTLSClockHint(err, now); got != err {
		t.Fatalf("expired certificate error changed to %q", got)
	}
}

func TestFetchCatalogIncludesHTTPFailureDetail(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("User-Agent"); got != "ZenPM/1.0 (+https://github.com/xZenLabs/ZenPackageManager)" {
			t.Errorf("User-Agent = %q", got)
		}
		if got := r.Header.Get("Accept"); got != "application/json, text/plain, */*" {
			t.Errorf("Accept = %q", got)
		}
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte("blocked by test WAF"))
	}))
	defer srv.Close()

	_, err := FetchCatalog("blocked", srv.URL, 10, t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "blocked by test WAF") {
		t.Fatalf("FetchCatalog() error = %v, want HTTP failure detail", err)
	}
}

func TestFetchHTTPBytesRetriesHeaderTimeout(t *testing.T) {
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			time.Sleep(100 * time.Millisecond)
			return
		}
		w.Write([]byte("package data"))
	}))
	defer srv.Close()

	data, err := fetchHTTPBytes(srv.URL, &http.Client{Timeout: 25 * time.Millisecond}, 2)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "package data" {
		t.Fatalf("FetchHTTPBytes() = %q", data)
	}
	if got := requests.Load(); got != 2 {
		t.Fatalf("requests = %d, want 2", got)
	}
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
		VersionsURL:           "https://example.invalid/versions.json",
		ReleaseNotesURL:       "https://example.invalid/release-notes.md",
		PrereleaseNotesURL:    "https://example.invalid/prerelease-notes.md",
		PrereleaseVersion:     "1.3.0-rc.1",
		PluginModule:          "zenos",
		PluginModuleAliases:   []string{"zen_ui"},
		SourceAssetAliases:    []string{"zen_ui.koplugin.zip"},
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
	if got.PluginModule != "zenos" || len(got.PluginModuleAliases) != 1 || got.PluginModuleAliases[0] != "zen_ui" || len(got.SourceAssetAliases) != 1 || got.SourceAssetAliases[0] != "zen_ui.koplugin.zip" {
		t.Fatalf("plugin identity aliases = %#v", got)
	}
	if got.SourceType != entry.SourceType || got.SourceURL != entry.SourceURL || got.Assets != entry.Assets || got.Constraints != entry.Constraints || got.ReadmeURL != entry.ReadmeURL || got.VersionsURL != entry.VersionsURL || got.ReleaseNotesURL != entry.ReleaseNotesURL || got.PrereleaseNotesURL != entry.PrereleaseNotesURL || got.PrereleaseVersion != entry.PrereleaseVersion || len(got.Conflicts) != 1 || got.Conflicts[0] != "zen-ui" || len(got.IncompatiblePlatforms) != 2 || got.IncompatiblePlatforms[0] != "android" || got.IncompatiblePlatforms[1] != "host" {
		t.Fatalf("round trip = %#v, want source/assets fields from %#v", got, entry)
	}
}

func TestParseZenPMCatalogDerivesPluginModuleFromSource(t *testing.T) {
	manifest := manifestJSON{}
	if err := json.Unmarshal([]byte(`{
		"packages": [{
			"id": "zlibrary-2",
			"name": "Zlibrary",
			"version": "1.0.41",
			"platforms": ["koreader"],
			"source": "https://github.com/ZlibraryKO/zlibrary.koplugin",
			"source_asset": "zlibrary_plugin_v1.0.41.zip"
		}]
	}`), &manifest); err != nil {
		t.Fatal(err)
	}

	entries := parseZenPMCatalog("ZenLabs", "https://example.invalid/repo", 10, manifest)
	if len(entries) != 1 || entries[0].PluginModule != "zlibrary" {
		t.Fatalf("entries = %#v, want zlibrary plugin module", entries)
	}
}

func TestParseZenPMCatalogPreservesPluginIdentityAliases(t *testing.T) {
	manifest := manifestJSON{}
	if err := json.Unmarshal([]byte(`{
		"packages": [{
			"id": "zen-ui",
			"name": "ZenOS",
			"version": "3.0.0",
			"platforms": ["koreader"],
			"source_asset": "zenos.koplugin.zip",
			"source_asset_aliases": ["zen_ui.koplugin.zip"],
			"plugin_module": "zenos",
			"plugin_module_aliases": ["zen_ui"]
		}]
	}`), &manifest); err != nil {
		t.Fatal(err)
	}

	entries := parseZenPMCatalog("ZenLabs", "https://example.invalid/repo", 10, manifest)
	if len(entries) != 1 || entries[0].PluginModule != "zenos" || len(entries[0].PluginModuleAliases) != 1 || entries[0].PluginModuleAliases[0] != "zen_ui" || len(entries[0].SourceAssetAliases) != 1 || entries[0].SourceAssetAliases[0] != "zen_ui.koplugin.zip" {
		t.Fatalf("entries = %#v", entries)
	}
}

func TestFromStateCatalogDerivesMissingPluginModule(t *testing.T) {
	entries := fromStateCatalog([]state.CatalogEntry{{
		ID: "zlibrary-2", Platforms: []string{"koreader"},
		Source: "https://github.com/ZlibraryKO/zlibrary.koplugin", SourceAsset: "zlibrary_plugin_v1.0.41.zip",
	}})
	if len(entries) != 1 || entries[0].PluginModule != "zlibrary" {
		t.Fatalf("entries = %#v, want zlibrary plugin module", entries)
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
				"versions_url": "packages/koreader/koreader-rsvp-plugin/versions.json",
				"release_notes_url": "packages/koreader/koreader-rsvp-plugin/RELEASE_NOTES.md",
				"prerelease_version": "1.1.0-rc.1",
				"prerelease_notes_url": "packages/koreader/koreader-rsvp-plugin/PRERELEASE_NOTES.md",
				"published_at": "2026-07-24T12:00:00Z",
				"featured_order": 10,
				"stars": "31",
				"assets": [{"arch":"arm","asset":"plugin.zip","url":"packages/koreader/plugin.zip","size":"12"}],
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
	if entries[0].VersionsURL != "https://example.invalid/repo/packages/koreader/koreader-rsvp-plugin/versions.json" {
		t.Fatalf("VersionsURL = %q", entries[0].VersionsURL)
	}
	if entries[0].ReleaseNotesURL != "https://example.invalid/repo/packages/koreader/koreader-rsvp-plugin/RELEASE_NOTES.md" {
		t.Fatalf("ReleaseNotesURL = %q", entries[0].ReleaseNotesURL)
	}
	if entries[0].PrereleaseNotesURL != "https://example.invalid/repo/packages/koreader/koreader-rsvp-plugin/PRERELEASE_NOTES.md" || entries[0].PrereleaseVersion != "1.1.0-rc.1" {
		t.Fatalf("prerelease notes = %q / %q", entries[0].PrereleaseNotesURL, entries[0].PrereleaseVersion)
	}
	if entries[0].PublishedAt != "2026-07-24T12:00:00Z" {
		t.Fatalf("PublishedAt = %q", entries[0].PublishedAt)
	}
	if entries[0].UninstallURL != "https://example.invalid/repo/packages/koreader/uninstall-plugin.sh" {
		t.Fatalf("UninstallURL = %q", entries[0].UninstallURL)
	}
	if entries[0].Assets != `[{"arch":"arm","asset":"plugin.zip","size":"12","url":"https://example.invalid/repo/packages/koreader/plugin.zip"}]` {
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
