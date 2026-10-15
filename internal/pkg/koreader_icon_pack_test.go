package pkg

import (
	"bytes"
	"encoding/json"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"sync/atomic"
	"testing"

	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
)

func TestIconPacksInstallAndUninstallIndependently(t *testing.T) {
	t.Setenv("ZENPM_HOME", filepath.Join(t.TempDir(), "ZenPM"))
	root := t.TempDir()
	t.Setenv("ZENPM_KOREADER_DIR", root)
	if err := os.WriteFile(filepath.Join(root, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	packs := map[string][]byte{}
	var icon bytes.Buffer
	if err := png.Encode(&icon, image.NewNRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"colour", "mono"} {
		packs["/"+name+".zip"] = zipContents(t, map[string]string{
			name + "/pack.json":      `{"schema_version":1,"id":"` + name + `","name":"Solar ` + name + `"}`,
			name + "/home.svg":       `<svg xmlns="http://www.w3.org/2000/svg"/>`,
			name + "/quick_home.png": icon.String(),
			name + "/legacy.svg":     `<?xml version="1.0" encoding="iso-8859-1"?><svg xmlns="http://www.w3.org/2000/svg"><text>` + "\xe9" + `</text></svg>`,
		})
	}
	var downloads atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		downloads.Add(1)
		w.Write(packs[r.URL.Path])
	}))
	defer server.Close()
	assets, _ := json.Marshal([]map[string]string{
		{"arch": "any", "asset": "colour.zip", "url": server.URL + "/colour.zip"},
		{"arch": "any", "asset": "mono.zip", "url": server.URL + "/mono.zip"},
	})
	catalog := []state.CatalogEntry{{
		ID: "solariconpack-2", Name: "Solar", Category: "iconpacks", Version: "1.0.0", Repo: "ZenLabs",
		Platforms: []string{"koreader"}, Assets: string(assets),
	}, {
		ID: "collision", Name: "Collision", Category: "iconpacks", Version: "1.0.0", Repo: "ZenLabs",
		Platforms: []string{"koreader"}, Assets: string(assets),
	}}
	if err := st.WriteCatalog(catalog); err != nil {
		t.Fatal(err)
	}
	manager := New(st, repo.New(st), "host")
	choices, err := manager.SelectAsset("solariconpack-2")
	if err != nil || !choices.NeedsChoice || len(choices.Candidates) != 2 {
		t.Fatalf("icon pack choices = %+v, %v", choices, err)
	}
	for _, name := range []string{"colour", "mono"} {
		if err := manager.InstallAsset("solariconpack-2", name+".zip"); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(root, "icons", "zen", name, "pack.json")); err != nil {
			t.Fatal(err)
		}
	}
	installed, err := st.ReadInstalledPatchFiles()
	if err != nil || len(installed) != 2 {
		t.Fatalf("tracked packs = %+v, %v", installed, err)
	}
	if err := manager.InstallAsset("collision", "colour.zip"); err == nil {
		t.Fatal("another package replaced a managed icon pack")
	}
	catalog[0].ID = "solariconpack-zen"
	if err := st.WriteCatalog(catalog); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"colour", "mono"} {
		if err := manager.InstallAsset("solariconpack-zen", name+".zip"); err != nil {
			t.Fatalf("install after catalog ID rename: %v", err)
		}
		installed, err = st.ReadInstalledPatchFiles()
		if err != nil || len(installed) != 2 {
			t.Fatalf("rename changed the number of tracked packs: %+v, %v", installed, err)
		}
		for _, pack := range installed {
			if pack.Asset == name+".zip" && pack.PackageID != "solariconpack-zen" {
				t.Fatalf("pack still tracked under the old ID: %+v", pack)
			}
		}
	}
	catalog[0].Version = "2.0.0"
	if err := st.WriteCatalog(catalog); err != nil {
		t.Fatal(err)
	}
	const updatedIcon = `<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h24v24H0z"/></svg>`
	for _, name := range []string{"colour", "mono"} {
		packs["/"+name+".zip"] = zipContents(t, map[string]string{
			name + "/pack.json": `{"schema_version":1,"id":"` + name + `","name":"Solar ` + name + `"}`,
			name + "/home.svg":  updatedIcon,
		})
	}
	if err := manager.InstallAsset("solariconpack-zen", "colour.zip"); err != nil {
		t.Fatal(err)
	}
	beforeUpdate := downloads.Load()
	if err := manager.Update("solariconpack-zen"); err != nil {
		t.Fatal(err)
	}
	if downloads.Load() != beforeUpdate+1 {
		t.Fatal("update did not download only the outdated icon pack")
	}
	installed, err = st.ReadInstalledPatchFiles()
	if err != nil || len(installed) != 2 {
		t.Fatalf("updated packs = %+v, %v", installed, err)
	}
	for _, pack := range installed {
		if pack.Version != "2.0.0" {
			t.Fatalf("update left a stale pack: %+v", pack)
		}
		data, err := os.ReadFile(filepath.Join(pack.InstallPath, "home.svg"))
		if err != nil || string(data) != updatedIcon {
			t.Fatalf("update did not replace the icon: %q, %v", data, err)
		}
	}
	if err := manager.Update(""); err != nil {
		t.Fatal(err)
	}
	if downloads.Load() != beforeUpdate+1 {
		t.Fatal("bulk update downloaded a current icon pack")
	}
	if err := manager.Reinstall("solariconpack-zen", "colour.zip", ""); err != nil {
		t.Fatal(err)
	}
	if err := manager.Uninstall("solariconpack-zen", "colour.zip"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "icons", "zen", "colour")); !os.IsNotExist(err) {
		t.Fatalf("colour pack remains: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "icons", "zen", "mono", "pack.json")); err != nil {
		t.Fatalf("uninstall removed sibling pack: %v", err)
	}
	installed, err = st.ReadInstalledPatchFiles()
	if err != nil || len(installed) != 1 || installed[0].Asset != "mono.zip" {
		t.Fatalf("remaining tracked packs = %+v, %v", installed, err)
	}
}

func TestIconPackRejectsInvalidArchivesWithoutReplacingExistingPack(t *testing.T) {
	t.Setenv("ZENPM_HOME", filepath.Join(t.TempDir(), "ZenPM"))
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	manager := New(st, repo.New(st), "host")
	root := t.TempDir()
	const metadata = `{"schema_version":1,"id":"safe","name":"Safe"}`
	const svg = `<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h24v24H0z"/></svg>`
	var icon bytes.Buffer
	if err := png.Encode(&icon, image.NewNRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	for name, files := range map[string]map[string]string{
		"empty ZIP":           {},
		"missing metadata":    {"safe/home.svg": svg},
		"invalid metadata":    {"safe/pack.json": "not JSON", "safe/home.svg": svg},
		"traversal":           {"safe/pack.json": metadata, "safe/../../escape.svg": svg},
		"multiple folders":    {"safe/pack.json": metadata, "other/home.svg": svg},
		"wrong id":            {"safe/pack.json": `{"schema_version":1,"id":"other","name":"Safe"}`, "safe/home.svg": svg},
		"wrong schema":        {"safe/pack.json": `{"schema_version":2,"id":"safe","name":"Safe"}`, "safe/home.svg": svg},
		"wrong metadata case": {"safe/pack.json": `{"SCHEMA_VERSION":1,"ID":"safe","NAME":"Safe"}`, "safe/home.svg": svg},
		"null version":        {"safe/pack.json": `{"schema_version":1,"id":"safe","name":"Safe","version":null}`, "safe/home.svg": svg},
		"null author":         {"safe/pack.json": `{"schema_version":1,"id":"safe","name":"Safe","author":null}`, "safe/home.svg": svg},
		"non-string author":   {"safe/pack.json": `{"schema_version":1,"id":"safe","name":"Safe","author":false}`, "safe/home.svg": svg},
		"no icons":            {"safe/pack.json": metadata},
		"no root icons":       {"safe/pack.json": metadata, "safe/nested/home.svg": svg},
		"unsupported format":  {"safe/pack.json": metadata, "safe/home.jpg": "icon"},
		"duplicate names":     {"safe/pack.json": metadata, "safe/home.svg": svg, "safe/HOME.svg": svg},
		"empty SVG":           {"safe/pack.json": metadata, "safe/home.svg": ""},
		"renamed text":        {"safe/pack.json": metadata, "safe/home.svg": "not an icon"},
		"non-SVG XML":         {"safe/pack.json": metadata, "safe/home.svg": "<html/>"},
		"wrong SVG namespace": {"safe/pack.json": metadata, "safe/home.svg": `<svg xmlns="https://example.invalid"/>`},
		"malformed SVG":       {"safe/pack.json": metadata, "safe/home.svg": "<svg><path></svg>"},
		"multiple SVG roots":  {"safe/pack.json": metadata, "safe/home.svg": svg + svg},
		"trailing SVG text":   {"safe/pack.json": metadata, "safe/home.svg": svg + "not XML"},
		"empty PNG":           {"safe/pack.json": metadata, "safe/home.png": ""},
		"renamed SVG":         {"safe/pack.json": metadata, "safe/home.png": svg},
		"truncated PNG":       {"safe/pack.json": metadata, "safe/home.png": icon.String()[:icon.Len()-12]},
		"one broken icon":     {"safe/pack.json": metadata, "safe/home.svg": svg, "safe/quick_home.svg": "broken"},
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			destination := filepath.Join(root, "icons", "zen", "safe")
			if err := os.MkdirAll(destination, 0755); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(destination, "original.svg")
			if err := os.WriteFile(marker, []byte("original"), 0644); err != nil {
				t.Fatal(err)
			}
			if _, err := manager.installKOReaderIconPack(&repo.CatalogEntry{ID: "safe"}, root, "safe.zip", assetFile(t, zipContents(t, files))); err == nil {
				t.Fatal("invalid icon pack was accepted")
			}
			data, err := os.ReadFile(marker)
			if err != nil || string(data) != "original" {
				t.Fatalf("existing pack was changed: %q, %v", data, err)
			}
		})
	}
	if err := removeKOReaderIconPack(root, root); err == nil {
		t.Fatal("uninstall accepted an unbounded directory")
	}
}

func TestIconPackRejectsUnrelatedOrphanOwners(t *testing.T) {
	t.Setenv("ZENPM_HOME", filepath.Join(t.TempDir(), "ZenPM"))
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	manager := New(st, repo.New(st), "host")
	archive := zipContents(t, map[string]string{
		"safe/pack.json": `{"schema_version":1,"id":"safe","name":"Safe"}`,
		"safe/home.svg":  `<svg xmlns="http://www.w3.org/2000/svg"/>`,
	})
	for _, owner := range []state.PatchFileEntry{
		{PackageID: "removed", Asset: "safe.zip", Repo: "Other"},
		{PackageID: "removed", Asset: "safe.zip"},
		{PackageID: "removed", Asset: "other.zip", Repo: "ZenLabs"},
	} {
		t.Run(owner.Repo+"/"+owner.Asset, func(t *testing.T) {
			root := t.TempDir()
			owner.InstallPath = filepath.Join(root, "icons", "zen", "safe")
			if err := os.MkdirAll(owner.InstallPath, 0755); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(owner.InstallPath, "original.svg")
			if err := os.WriteFile(marker, []byte("original"), 0644); err != nil {
				t.Fatal(err)
			}
			owner.InstalledAt = "2026-10-07T12:00:00Z"
			if err := st.AppendInstalledPatchFile(owner); err != nil {
				t.Fatal(err)
			}
			before, err := st.ReadInstalledPatchFiles()
			if err != nil {
				t.Fatal(err)
			}
			entry := &repo.CatalogEntry{ID: "current", Repo: "ZenLabs"}
			if _, err := manager.installKOReaderIconPack(entry, root, "safe.zip", assetFile(t, archive)); err == nil {
				t.Fatal("an unrelated orphan owner was replaced")
			}
			data, err := os.ReadFile(marker)
			if err != nil || string(data) != "original" {
				t.Fatalf("rejected install changed the existing pack: %q, %v", data, err)
			}
			installed, err := st.ReadInstalledPatchFiles()
			if err != nil || !slices.Equal(installed, before) {
				t.Fatalf("rejected install changed ownership: %+v, %v", installed, err)
			}
		})
	}
}

func TestIconPackDownloadValidationPreservesInstalledState(t *testing.T) {
	t.Setenv("ZENPM_HOME", filepath.Join(t.TempDir(), "ZenPM"))
	root := t.TempDir()
	t.Setenv("ZENPM_KOREADER_DIR", root)
	if err := os.WriteFile(filepath.Join(root, "reader.lua"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}
	const svg = `<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0h24v24H0z"/></svg>`
	packs := map[string][]byte{
		"/good.zip": zipContents(t, map[string]string{
			"safe/pack.json": `{"schema_version":1,"id":"safe","name":"Safe"}`,
			"safe/home.svg":  svg,
		}),
		"/bad.zip": zipContents(t, map[string]string{
			"safe/pack.json": `{"schema_version":1,"id":"safe","name":"Safe"}`,
			"safe/home.svg":  "not an icon",
		}),
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(packs[r.URL.Path])
	}))
	defer server.Close()
	manager := New(st, repo.New(st), "host")
	for i, download := range []string{"bad", "good", "bad"} {
		id := "safe"
		version := "1.0.0"
		if i == 2 {
			id = "renamed-safe"
			version = "2.0.0"
		}
		if err := st.WriteCatalog([]state.CatalogEntry{{
			ID: id, Name: "Safe", Category: "iconpacks", Version: version, Repo: "ZenLabs",
			Platforms: []string{"koreader"},
			Assets:    `[{"arch":"any","asset":"safe.zip","url":"` + server.URL + "/" + download + `.zip"}]`,
		}}); err != nil {
			t.Fatal(err)
		}
		before, err := st.ReadInstalledPatchFiles()
		if err != nil {
			t.Fatal(err)
		}
		err = manager.InstallAsset(id, "safe.zip")
		if (download == "good") != (err == nil) {
			t.Fatalf("install %s download returned %v", download, err)
		}
		if download == "good" {
			continue
		}
		installed, err := st.ReadInstalledPatchFiles()
		if err != nil {
			t.Fatal(err)
		}
		if !slices.Equal(installed, before) {
			t.Fatalf("failed install changed ownership: %+v, want %+v", installed, before)
		}
		if i == 0 {
			if len(installed) != 0 {
				t.Fatalf("failed initial install was recorded: %+v", installed)
			}
			if _, err := os.Stat(filepath.Join(root, "icons", "zen", "safe")); !os.IsNotExist(err) {
				t.Fatalf("failed initial install created a pack: %v", err)
			}
			continue
		}
		if len(installed) != 1 {
			t.Fatalf("failed update changed installed state: %+v", installed)
		}
		for _, reinstall := range []func(string, string, string) error{manager.Reinstall, manager.ReinstallGitHubRelease} {
			if err := reinstall(id, "safe.zip", ""); err == nil {
				t.Fatal("reinstall reported success for a malformed download")
			}
		}
		data, err := os.ReadFile(filepath.Join(root, "icons", "zen", "safe", "home.svg"))
		if err != nil || string(data) != svg {
			t.Fatalf("invalid download replaced the working icon: %q, %v", data, err)
		}
		after, err := st.ReadInstalledPatchFiles()
		if err != nil || len(after) != 1 || after[0] != installed[0] {
			t.Fatalf("invalid download changed installed state: %+v, %v", after, err)
		}
	}
}
