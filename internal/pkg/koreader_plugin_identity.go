package pkg

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/xZenLabs/zen-pm/internal/assets"
	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
)

type koreaderPluginRootMatch struct {
	module string
	path   string
}

func koreaderPluginModules(entry *repo.CatalogEntry) []string {
	if entry == nil {
		return nil
	}
	seen := make(map[string]bool)
	modules := make([]string, 0, 1+len(entry.PluginModuleAliases))
	for _, value := range append([]string{entry.PluginModule}, entry.PluginModuleAliases...) {
		module := strings.TrimSuffix(strings.TrimSpace(value), ".koplugin")
		if module == "" || module == "." || filepath.Base(module) != module || seen[module] {
			continue
		}
		seen[module] = true
		modules = append(modules, module)
	}
	return modules
}

func (m *Manager) selectKOReaderPluginIdentityAsset(entry *repo.CatalogEntry, candidates []assets.Asset) (string, bool, error) {
	if entry == nil || len(entry.PluginModuleAliases) == 0 {
		return "", false, nil
	}
	available := make(map[string]bool, len(candidates))
	for _, candidate := range candidates {
		available[strings.TrimSpace(candidate.Asset)] = true
	}
	canonicalAsset := strings.TrimSpace(entry.SourceAsset)
	if canonicalAsset == "" || !available[canonicalAsset] {
		return "", false, nil
	}

	pluginDirs, err := m.koreaderPluginDirs()
	if err != nil {
		return canonicalAsset, true, nil
	}
	found, err := findKOReaderPluginIdentityRoot(entry, pluginDirs)
	if err != nil {
		return "", true, err
	}
	if found == nil {
		return canonicalAsset, true, nil
	}
	asset := koreaderPluginAssetForModule(entry, found.module)
	if asset == "" || !available[asset] {
		return "", false, nil
	}
	return asset, true, nil
}

func koreaderPluginAssetForModule(entry *repo.CatalogEntry, module string) string {
	modules := koreaderPluginModules(entry)
	for index, candidate := range modules {
		if candidate != module {
			continue
		}
		if index == 0 {
			asset := strings.TrimSpace(entry.SourceAsset)
			if pluginTrackingName(entry, asset) == module+".koplugin" {
				return asset
			}
			return module + ".koplugin.zip"
		}
		aliasIndex := index - 1
		if aliasIndex < len(entry.SourceAssetAliases) {
			asset := strings.TrimSpace(entry.SourceAssetAliases[aliasIndex])
			if asset != "" {
				return asset
			}
		}
		if pluginTrackingName(entry, entry.SourceAsset) == module+".koplugin" {
			return strings.TrimSpace(entry.SourceAsset)
		}
		return module + ".koplugin.zip"
	}
	return ""
}

func koreaderPluginModuleForAsset(entry *repo.CatalogEntry, asset string) (string, bool) {
	asset = strings.TrimSpace(asset)
	if asset == "" {
		return "", false
	}
	modules := koreaderPluginModules(entry)
	for _, module := range modules {
		if koreaderPluginAssetForModule(entry, module) == asset {
			return module, true
		}
	}
	name := pluginTrackingName(entry, asset)
	for _, module := range modules {
		if name == module+".koplugin" {
			return module, true
		}
	}
	return "", false
}

func findKOReaderPluginIdentityRoot(entry *repo.CatalogEntry, pluginDirs []string) (*koreaderPluginRootMatch, error) {
	var found *koreaderPluginRootMatch
	for _, pluginDir := range pluginDirs {
		for _, module := range koreaderPluginModules(entry) {
			path := filepath.Join(pluginDir, module+".koplugin")
			info, err := os.Lstat(path)
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return nil, fmt.Errorf("inspect KOReader plugin path %s: %w", path, err)
			}
			if !info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
				return nil, fmt.Errorf("KOReader plugin path conflict at %s", path)
			}
			if found != nil {
				return nil, fmt.Errorf("package %q matches multiple KOReader plugin directories (multiple plugin roots: %s, %s)", entry.ID, found.path, path)
			}
			found = &koreaderPluginRootMatch{module: module, path: path}
		}
	}
	return found, nil
}

func validateKOReaderPluginIdentityPath(entry *repo.CatalogEntry, pluginDirs []string, path string) error {
	path = filepath.Clean(strings.TrimSpace(path))
	for _, pluginDir := range pluginDirs {
		for _, module := range koreaderPluginModules(entry) {
			if path == filepath.Clean(filepath.Join(pluginDir, module+".koplugin")) {
				return nil
			}
		}
	}
	return fmt.Errorf("tracked KOReader plugin path is outside configured plugin identity roots: %q", path)
}

func (m *Manager) prepareKOReaderPluginInstall(entry *repo.CatalogEntry, override string) (string, error) {
	if len(koreaderPluginModules(entry)) < 2 {
		return override, nil
	}
	pluginDirs, err := m.koreaderPluginDirs()
	if err != nil {
		return "", err
	}
	trackedPath, err := m.installedPackagePath(entry.ID)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(trackedPath) != "" {
		if err := validateKOReaderPluginIdentityPath(entry, pluginDirs, trackedPath); err != nil {
			return "", err
		}
	}
	found, err := findKOReaderPluginIdentityRoot(entry, pluginDirs)
	if err != nil {
		return "", err
	}
	if found == nil {
		return override, nil
	}
	asset := koreaderPluginAssetForModule(entry, found.module)
	if asset == "" {
		return "", fmt.Errorf("package %q has no asset for existing plugin root %s", entry.ID, found.path)
	}
	return asset, nil
}

func (m *Manager) reconcileKOReaderPluginAliasRecords() error {
	if m.st == nil || m.repos == nil {
		return nil
	}
	catalog, err := m.repos.ReadCatalog()
	if err != nil {
		return err
	}
	pluginDirs, err := m.koreaderPluginDirs()
	if err != nil {
		return nil
	}
	installed, err := m.st.ReadInstalled()
	if err != nil {
		return err
	}
	byID := make(map[string]*repo.CatalogEntry, len(catalog))
	for _, entry := range catalog {
		byID[entry.ID] = entry
	}
	var updates []state.InstalledEntry
	for _, current := range installed {
		entry := byID[current.ID]
		if len(koreaderPluginModules(entry)) < 2 || !isGenericKOReaderPlugin(entry) {
			continue
		}
		if strings.TrimSpace(current.InstallPath) != "" {
			if err := validateKOReaderPluginIdentityPath(entry, pluginDirs, current.InstallPath); err != nil {
				return err
			}
		}
		found, err := findKOReaderPluginIdentityRoot(entry, pluginDirs)
		if err != nil {
			return err
		}
		if found == nil {
			continue
		}
		asset := koreaderPluginAssetForModule(entry, found.module)
		if asset == "" {
			return fmt.Errorf("package %q has no asset for existing plugin root %s", entry.ID, found.path)
		}
		updated := current
		if strings.TrimSpace(entry.Name) != "" {
			updated.Name = entry.Name
		}
		updated.Asset = asset
		updated.InstallPath = found.path
		if updated.Name != current.Name || updated.Asset != current.Asset || updated.InstallPath != current.InstallPath {
			updates = append(updates, updated)
		}
	}
	for _, update := range updates {
		if err := m.st.AppendInstalled(update); err != nil {
			return err
		}
	}
	return nil
}
