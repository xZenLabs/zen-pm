package pkg

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"ZPM/internal/log"
	"ZPM/internal/repo"
	"ZPM/internal/state"
)

const koreaderPluginsScannedKey = "koreader_plugins_scanned"

// UnmanagedKOReaderPatch is a user patch found on disk without a ZenPM package
// record. It deliberately has no catalog package ID.
type UnmanagedKOReaderPatch struct {
	Asset    string
	Disabled bool
}

// KOReaderPluginScanResult describes one scan of KOReader's external plugins.
type KOReaderPluginScanResult struct {
	Scanned int  `json:"scanned"`
	Matched int  `json:"matched"`
	Added   int  `json:"added"`
	Updated int  `json:"updated"`
	Skipped bool `json:"skipped,omitempty"`
}

// Keep this in step with KOReader's PluginLoader.BUILTIN_PLUGINS. Built-in and
// external plugins share the same plugins directory, so the names are the only
// reliable distinction available to the backend filesystem scan.
var koreaderBuiltInPlugins = map[string]bool{
	"archiveviewer": true, "autodim": true, "autostandby": true, "autosuspend": true,
	"autoturn": true, "autowarmth": true, "batterystat": true, "bookshortcuts": true,
	"calibre": true, "cloudstorage": true, "coverbrowser": true, "coverimage": true,
	"docsettingtweak": true, "exporter": true, "externalkeyboard": true, "gestures": true,
	"hello": true, "hotkeys": true, "httpinspector": true, "japanese": true,
	"keepalive": true, "kosync": true, "movetoarchive": true, "newsdownloader": true,
	"opds": true, "perceptionexpander": true, "profiles": true, "qrclipboard": true,
	"readtimer": true, "SSH": true, "statistics": true, "systemstat": true,
	"terminal": true, "texteditor": true, "timesync": true, "vocabbuilder": true,
	"wallabag": true,
}

var koreaderMetaVersion = regexp.MustCompile(`\bversion\s*=\s*["']([^"']+)["']`)

// ScanKOReaderPlugins records installed external KOReader plugins that match
// the current catalog. force bypasses the one-time scan marker.
func (m *Manager) ScanKOReaderPlugins(force bool) (KOReaderPluginScanResult, error) {
	var result KOReaderPluginScanResult
	if !force {
		value, err := m.st.ReadValue(koreaderPluginsScannedKey)
		if err != nil {
			return result, fmt.Errorf("read KOReader plugin scan marker: %w", err)
		}
		if value != "" {
			result.Skipped = true
			return result, nil
		}
	}

	catalog, err := m.repos.ReadCatalog()
	if err != nil {
		return result, fmt.Errorf("read catalog: %w", err)
	}
	if len(catalog) == 0 {
		return result, fmt.Errorf("KOReader plugin scan requires a non-empty catalog")
	}

	byModule, byID := koreaderPluginCatalog(catalog)
	installed, err := m.st.ReadInstalled()
	if err != nil {
		return result, fmt.Errorf("read installed packages: %w", err)
	}
	installedByID := make(map[string]state.InstalledEntry, len(installed))
	for _, entry := range installed {
		installedByID[entry.ID] = entry
	}

	pluginDirs, err := m.koreaderPluginDirs()
	if err != nil {
		return result, err
	}
	for _, pluginDir := range pluginDirs {
		entries, err := os.ReadDir(pluginDir)
		if err != nil {
			return result, fmt.Errorf("read KOReader plugins directory %s: %w", pluginDir, err)
		}
		for _, dir := range entries {
			if !dir.IsDir() || !strings.HasSuffix(dir.Name(), ".koplugin") {
				continue
			}
			module := strings.TrimSuffix(dir.Name(), ".koplugin")
			if koreaderBuiltInPlugins[module] {
				continue
			}
			result.Scanned++
			pkg := byModule[module]
			if pkg == nil {
				pkg = byID[module]
			}
			if pkg == nil {
				continue
			}
			result.Matched++

			version, err := koreaderPluginVersion(filepath.Join(pluginDir, dir.Name()))
			if err != nil {
				log.Warnf("Could not read version for KOReader plugin %s: %v", module, err)
				version = "0.0.0"
			}

			previous, exists := installedByID[pkg.ID]
			current := state.InstalledEntry{
				ID: pkg.ID, Name: pkg.Name, Version: version, Repo: pkg.Repo,
			}
			if exists {
				if previous.Name == current.Name && previous.Version == current.Version && previous.Repo == current.Repo {
					continue
				}
				current.InstalledAt = previous.InstalledAt
				if err := m.st.AppendInstalled(current); err != nil {
					return result, fmt.Errorf("record KOReader plugin %s: %w", pkg.ID, err)
				}
				result.Updated++
				installedByID[pkg.ID] = current
				continue
			}
			if err := m.st.AppendInstalled(current); err != nil {
				return result, fmt.Errorf("record KOReader plugin %s: %w", pkg.ID, err)
			}
			result.Added++
			installedByID[pkg.ID] = current
		}
	}

	if err := m.st.WriteValue(koreaderPluginsScannedKey, "1"); err != nil {
		return result, fmt.Errorf("write KOReader plugin scan marker: %w", err)
	}
	return result, nil
}

func (m *Manager) koreaderPluginDirs() ([]string, error) {
	seen := map[string]bool{}
	var dirs []string
	add := func(path string) {
		path = strings.TrimSpace(path)
		if path == "" {
			return
		}
		path = filepath.Clean(path)
		if !seen[path] {
			seen[path] = true
			dirs = append(dirs, path)
		}
	}

	add(os.Getenv("ZENPM_KOREADER_PLUGIN_DIR"))
	for _, root := range koreaderRootCandidates(m.plat) {
		add(filepath.Join(root, "plugins"))
	}

	var existing []string
	for _, dir := range dirs {
		info, err := os.Stat(dir)
		if err == nil && info.IsDir() {
			existing = append(existing, dir)
		}
	}
	if len(existing) == 0 {
		return nil, fmt.Errorf("KOReader plugins directory not found")
	}
	return existing, nil
}

// UnmanagedKOReaderPatches lists user patches that predate ZenPM or were
// installed outside it. The result is derived from the filesystem each time so
// it never assigns an unverifiable catalog package identity.
func (m *Manager) UnmanagedKOReaderPatches() ([]UnmanagedKOReaderPatch, error) {
	root, err := m.koreaderRoot()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(filepath.Join(root, "patches"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	managedEntries, err := m.st.ReadInstalledPatchFiles()
	if err != nil {
		return nil, err
	}
	managed := make(map[string]bool, len(managedEntries))
	for _, entry := range managedEntries {
		managed[entry.Asset] = true
	}

	var patches []UnmanagedKOReaderPatch
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		disabled := strings.HasSuffix(name, ".disabled")
		asset := strings.TrimSuffix(name, ".disabled")
		if !strings.HasSuffix(strings.ToLower(asset), ".lua") || managed[asset] {
			continue
		}
		patches = append(patches, UnmanagedKOReaderPatch{Asset: asset, Disabled: disabled})
	}
	sort.Slice(patches, func(i, j int) bool { return patches[i].Asset < patches[j].Asset })
	return patches, nil
}

func koreaderPluginCatalog(catalog []*repo.CatalogEntry) (map[string]*repo.CatalogEntry, map[string]*repo.CatalogEntry) {
	byModule := make(map[string]*repo.CatalogEntry)
	byID := make(map[string]*repo.CatalogEntry)
	for _, entry := range catalog {
		if !packageHasPlatform(entry, "koreader") || isPatchPackage(entry) {
			continue
		}
		if module := strings.TrimSpace(entry.PluginModule); module != "" && byModule[module] == nil {
			byModule[module] = entry
		}
		if entry.ID != "" && byID[entry.ID] == nil {
			byID[entry.ID] = entry
		}
	}
	return byModule, byID
}

func koreaderPluginVersion(pluginPath string) (string, error) {
	if data, err := os.ReadFile(filepath.Join(pluginPath, "_meta.lua")); err == nil {
		match := koreaderMetaVersion.FindSubmatch(data)
		if len(match) >= 2 {
			if version := strings.TrimSpace(string(match[1])); version != "" {
				return version, nil
			}
		}
	}

	if data, err := os.ReadFile(filepath.Join(pluginPath, "VERSION")); err == nil {
		if version := strings.TrimSpace(strings.SplitN(string(data), "\n", 2)[0]); version != "" {
			return version, nil
		}
	}

	if data, err := os.ReadFile(filepath.Join(pluginPath, "BUILD_INFO.json")); err == nil {
		var info struct {
			Version string `json:"version"`
		}
		if err := json.Unmarshal(data, &info); err != nil {
			return "", err
		}
		if version := strings.TrimSpace(info.Version); version != "" {
			return version, nil
		}
	}

	return "0.0.0", nil
}
