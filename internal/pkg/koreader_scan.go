package pkg

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/xZenLabs/zen-pm/internal/log"
	"github.com/xZenLabs/zen-pm/internal/releases"
	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
)

const koreaderPluginDirsKey = "koreader_plugin_dirs"

// UnmanagedKOReaderPatch is a user patch found on disk without a ZenPM package
// record. It deliberately has no catalog package ID.
type UnmanagedKOReaderPatch struct {
	Asset    string
	Disabled bool
}

// KOReaderPluginScanResult describes one scan of KOReader's external plugins.
type KOReaderPluginScanResult struct {
	Scanned int `json:"scanned"`
	Matched int `json:"matched"`
	Added   int `json:"added"`
	Updated int `json:"updated"`
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

// ScanKOReaderPlugins records installed external KOReader plugins. Catalog
// matches use catalog metadata; unmatched plugins use their directory name.
// pluginDirs replaces the paths reported by KOReader; nil reuses saved paths.
// Always reconcile disk contents, including installs made outside ZenPM.
func (m *Manager) ScanKOReaderPlugins(pluginDirs []string) (KOReaderPluginScanResult, error) {
	var result KOReaderPluginScanResult
	if err := m.st.LockAcquire("operation"); err != nil {
		return result, err
	}
	defer m.st.LockRelease("operation")
	if pluginDirs != nil {
		for _, dir := range pluginDirs {
			if !filepath.IsAbs(dir) || strings.ContainsRune(dir, '\x00') {
				return result, fmt.Errorf("KOReader plugin directory must be an absolute path: %q", dir)
			}
		}
		data, err := json.Marshal(pluginDirs)
		if err != nil {
			return result, err
		}
		if err := m.st.WriteValue(koreaderPluginDirsKey, string(data)); err != nil {
			return result, fmt.Errorf("save KOReader plugin directories: %w", err)
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
	installedByPath := make(map[string]state.InstalledEntry, len(installed))
	for _, entry := range installed {
		installedByID[entry.ID] = entry
		if entry.InstallPath != "" {
			installedByPath[filepath.Clean(entry.InstallPath)] = entry
		}
	}

	pluginDirs, err = m.koreaderPluginDirs()
	if err != nil {
		return result, err
	}
	if err := rejectDuplicateKOReaderPluginCatalogPaths(pluginDirs, byModule); err != nil {
		return result, err
	}
	scannedDirs := make(map[string]bool, len(pluginDirs))
	foundPaths := make(map[string]bool)
	foundIDs := make(map[string]bool)
	for _, pluginDir := range pluginDirs {
		scannedDirs[filepath.Clean(pluginDir)] = true
	}
	for _, pluginDir := range pluginDirs {
		entries, err := os.ReadDir(pluginDir)
		if err != nil {
			return result, fmt.Errorf("read KOReader plugins directory %s: %w", pluginDir, err)
		}
		for _, dir := range entries {
			if !isScannableKOReaderPluginDir(pluginDir, dir) {
				continue
			}
			module := strings.TrimSuffix(dir.Name(), ".koplugin")
			if koreaderBuiltInPlugins[module] {
				continue
			}
			result.Scanned++
			pluginPath := filepath.Join(pluginDir, dir.Name())
			foundPaths[filepath.Clean(pluginPath)] = true

			version, err := koreaderPluginVersion(pluginPath)
			if err != nil {
				log.Warnf("Could not read version for KOReader plugin %s: %v", module, err)
				version = "0.0.0"
			}

			candidates := byModule[module]
			previousByPath, knownPath := installedByPath[filepath.Clean(pluginPath)]
			pkg := matchingKOReaderPlugin(candidates, version, previousByPath, knownPath)
			if pkg == nil {
				pkg = matchingTrackedKOReaderPlugin(candidates, installedByID)
			}
			if pkg == nil && len(candidates) == 0 {
				pkg = byID[module]
			}
			id, name, repoName := module, module, ""
			if pkg != nil {
				result.Matched++
				id, name, repoName = pkg.ID, pkg.Name, pkg.Repo
			} else if len(candidates) > 1 || byID[module] != nil {
				id = "local-plugin:" + module
			}
			foundIDs[id] = true

			if pkg != nil && len(candidates) > 1 {
				for _, candidate := range candidates {
					if candidate.ID == pkg.ID {
						continue
					}
					previous, exists := installedByID[candidate.ID]
					if !exists {
						continue
					}
					samePath := previous.InstallPath != "" && filepath.Clean(previous.InstallPath) == filepath.Clean(pluginPath)
					if !samePath && (previous.InstallPath != "" || previous.Asset != "" || !sameKOReaderPluginVersion(version, previous.Version)) {
						continue
					}
					if err := m.st.RemoveInstalled(candidate.ID); err != nil {
						return result, fmt.Errorf("remove mismatched KOReader plugin %s: %w", candidate.ID, err)
					}
					delete(installedByID, candidate.ID)
				}
			}
			if pkg != nil {
				for staleID, stale := range installedByID {
					if staleID == pkg.ID || !isUntrackedKOReaderPluginRecord(stale) {
						continue
					}
					samePath := stale.InstallPath != "" && filepath.Clean(stale.InstallPath) == filepath.Clean(pluginPath)
					sameAsset := strings.TrimSuffix(filepath.Base(strings.TrimSpace(stale.Asset)), ".zip") == dir.Name()
					if !samePath && !sameAsset {
						continue
					}
					if err := m.st.RemoveInstalled(staleID); err != nil {
						return result, fmt.Errorf("remove untracked KOReader plugin %s: %w", staleID, err)
					}
					delete(installedByID, staleID)
				}
			}

			previous, exists := installedByID[id]
			if exists && version == "0.0.0" && previous.Version != "" && previous.Version != "0.0.0" {
				version = previous.Version
			}
			current := state.InstalledEntry{
				ID: id, Name: name, Version: version, Repo: repoName, InstallPath: pluginPath,
			}
			mappedAsset := ""
			if pkg != nil {
				mappedAsset = koreaderPluginAssetForModule(pkg, module)
				current.Asset = mappedAsset
			}
			if exists {
				if pkg == nil {
					current.Name = previous.Name
					current.Repo = previous.Repo
				}
				current.Asset = previous.Asset
				if mappedAsset != "" {
					current.Asset = mappedAsset
				}
				current.AssetArch = previous.AssetArch
				current.InstalledAt = previous.InstalledAt
				if previous.Name == current.Name && previous.Version == current.Version &&
					previous.Repo == current.Repo && previous.Asset == current.Asset && previous.InstallPath == current.InstallPath {
					continue
				}
				if err := m.st.AppendInstalled(current); err != nil {
					return result, fmt.Errorf("record KOReader plugin %s: %w", id, err)
				}
				result.Updated++
				installedByID[id] = current
				continue
			}
			if err := m.st.AppendInstalled(current); err != nil {
				return result, fmt.Errorf("record KOReader plugin %s: %w", id, err)
			}
			result.Added++
			installedByID[id] = current
		}
	}
	for _, entry := range installed {
		path := filepath.Clean(entry.InstallPath)
		if foundIDs[entry.ID] || foundPaths[path] || !strings.HasSuffix(filepath.Base(path), ".koplugin") || !scannedDirs[filepath.Dir(path)] {
			continue
		}
		if err := m.st.RemoveInstalled(entry.ID); err != nil {
			return result, fmt.Errorf("remove missing KOReader plugin %s: %w", entry.ID, err)
		}
	}

	return result, nil
}

func rejectDuplicateKOReaderPluginCatalogPaths(pluginDirs []string, byModule map[string][]*repo.CatalogEntry) error {
	matchedPaths := make(map[string]string)
	for _, pluginDir := range pluginDirs {
		entries, err := os.ReadDir(pluginDir)
		if err != nil {
			return fmt.Errorf("read KOReader plugins directory %s: %w", pluginDir, err)
		}
		for _, dir := range entries {
			if !isScannableKOReaderPluginDir(pluginDir, dir) {
				continue
			}
			module := strings.TrimSuffix(dir.Name(), ".koplugin")
			candidates := byModule[module]
			if len(candidates) != 1 {
				continue
			}
			path := filepath.Join(pluginDir, dir.Name())
			if previous, exists := matchedPaths[candidates[0].ID]; exists && filepath.Clean(previous) != filepath.Clean(path) {
				return fmt.Errorf("catalog package %q matches multiple KOReader plugin directories (%s, %s)", candidates[0].ID, previous, path)
			}
			matchedPaths[candidates[0].ID] = path
		}
	}
	return nil
}

func isScannableKOReaderPluginDir(pluginDir string, entry os.DirEntry) bool {
	if !strings.HasSuffix(entry.Name(), ".koplugin") {
		return false
	}
	if entry.IsDir() {
		return true
	}
	if entry.Type()&os.ModeSymlink == 0 {
		return false
	}
	info, err := os.Stat(filepath.Join(pluginDir, entry.Name()))
	return err == nil && info.IsDir()
}

func (m *Manager) koreaderPluginDirs(additionalDirs ...string) ([]string, error) {
	seen := map[string]bool{}
	var dirs []string
	add := func(path string) {
		path = strings.TrimSpace(path)
		if path == "" {
			return
		}
		path = filepath.Clean(path)
		if absolute, err := filepath.Abs(path); err == nil {
			path = absolute
		}
		if !seen[path] {
			seen[path] = true
			dirs = append(dirs, path)
		}
	}

	for _, dir := range additionalDirs {
		add(dir)
	}
	for _, root := range koreaderRootCandidates(m.plat) {
		add(koreaderPluginDir(root))
		add(filepath.Join(root, "plugins"))
	}
	if dir := os.Getenv("ZENPM_KOREADER_PLUGIN_DIR"); filepath.IsAbs(dir) {
		add(dir)
	}
	if m.st != nil {
		value, err := m.st.ReadValue(koreaderPluginDirsKey)
		if err != nil {
			return nil, fmt.Errorf("read KOReader plugin directories: %w", err)
		}
		if value != "" {
			var paths []string
			if err := json.Unmarshal([]byte(value), &paths); err != nil {
				return nil, fmt.Errorf("decode KOReader plugin directories: %w", err)
			}
			for _, path := range paths {
				add(path)
			}
		}
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
	entries, err := os.ReadDir(koreaderPatchDir(root))
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

func koreaderPluginCatalog(catalog []*repo.CatalogEntry) (map[string][]*repo.CatalogEntry, map[string]*repo.CatalogEntry) {
	byModule := make(map[string][]*repo.CatalogEntry)
	byID := make(map[string]*repo.CatalogEntry)
	for _, entry := range catalog {
		if !packageHasPlatform(entry, "koreader") || isPatchPackage(entry) {
			continue
		}
		for _, module := range koreaderPluginModules(entry) {
			byModule[module] = append(byModule[module], entry)
		}
		if entry.ID != "" && byID[entry.ID] == nil {
			byID[entry.ID] = entry
		}
	}
	return byModule, byID
}

func matchingKOReaderPlugin(candidates []*repo.CatalogEntry, version string, previous state.InstalledEntry, knownPath bool) *repo.CatalogEntry {
	if len(candidates) == 1 {
		return candidates[0]
	}

	var versionMatch *repo.CatalogEntry
	for _, entry := range candidates {
		if !sameKOReaderPluginVersion(version, entry.Version) {
			continue
		}
		if versionMatch != nil {
			versionMatch = nil
			break
		}
		versionMatch = entry
	}
	if versionMatch != nil {
		return versionMatch
	}

	if knownPath {
		for _, entry := range candidates {
			if entry.ID == previous.ID {
				return entry
			}
		}
	}
	return nil
}

func matchingTrackedKOReaderPlugin(candidates []*repo.CatalogEntry, installed map[string]state.InstalledEntry) *repo.CatalogEntry {
	var match *repo.CatalogEntry
	for _, entry := range candidates {
		installedEntry, ok := installed[entry.ID]
		if !ok || strings.TrimSpace(installedEntry.Asset) == "" {
			continue
		}
		if match != nil {
			return nil
		}
		match = entry
	}
	return match
}

func isUntrackedKOReaderPluginRecord(entry state.InstalledEntry) bool {
	return strings.HasPrefix(entry.ID, "local-plugin:") ||
		(entry.Repo == "" && entry.Asset == "" && entry.InstallPath != "")
}

func sameKOReaderPluginVersion(left, right string) bool {
	base := func(version string) string {
		version = releases.NormalizeVersion(version)
		return strings.SplitN(version, "-", 2)[0]
	}
	left, right = base(left), base(right)
	return left != "" && left != "0.0.0" && left == right
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
