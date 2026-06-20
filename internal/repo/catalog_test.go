package repo

import "testing"

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
}

func TestCatalogSourceAssetRoundTrip(t *testing.T) {
	entry := &CatalogEntry{
		Repo:        "ZenLabs",
		Priority:    10,
		ID:          "sudoku-koplugin",
		Name:        "Sudoku",
		Version:     "1.2.1",
		InstallURL:  "install.sh",
		Source:      "omer-faruq/sudoku.koplugin",
		SourceAsset: "sudoku.koplugin.zip",
	}

	got, err := parseCatalogLine(entry.serialize())
	if err != nil {
		t.Fatal(err)
	}
	if got.SourceAsset != entry.SourceAsset {
		t.Fatalf("SourceAsset = %q, want %q", got.SourceAsset, entry.SourceAsset)
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
