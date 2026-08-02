package pkg

import (
	"archive/zip"
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/xZenLabs/zen-pm/internal/releases"
	"github.com/xZenLabs/zen-pm/internal/repo"
)

const (
	genericPluginInstaller = "plugin"
	genericPatchInstaller  = "patch"
	genericFontInstaller   = "font"
)

func genericKOReaderInstaller(entry *repo.CatalogEntry) string {
	if !packageHasPlatform(entry, "koreader") {
		return ""
	}
	if isPatchPackage(entry) {
		return genericPatchInstaller
	}
	if isFontPackage(entry) {
		return genericFontInstaller
	}
	return genericPluginInstaller
}

// nativeKOReaderInstaller handles KOReader plugins and patches in-process.
func (m *Manager) nativeKOReaderInstaller(entry *repo.CatalogEntry, override string) string {
	return genericKOReaderInstaller(entry)
}

// installGenericKOReader performs the work of the repository's generic shell
// installers in-process, so it does not depend on curl, wget, or BusyBox.
func (m *Manager) installGenericKOReader(entry *repo.CatalogEntry, override, releaseTag, kind string) (string, string, error) {
	assetName, _, data, err := m.downloadInstallAsset(entry, override, releaseTag)
	if err != nil {
		return "", "", err
	}
	root, err := m.koreaderRoot()
	if err != nil {
		return "", "", err
	}

	switch kind {
	case genericPluginInstaller:
		version, path, err := m.installKOReaderPlugin(entry, root, assetName, data)
		return version, path, err
	case genericPatchInstaller:
		path, err := m.installKOReaderPatch(entry, root, assetName, data)
		return "", path, err
	case genericFontInstaller:
		path, err := m.installKOReaderFont(entry, root, assetName, data)
		return "", path, err
	default:
		return "", "", fmt.Errorf("unknown generic KOReader installer %q", kind)
	}
}

func (m *Manager) downloadInstallAsset(entry *repo.CatalogEntry, override, releaseTag string) (string, string, []byte, error) {
	assetName := m.installAssetName(entry, override)
	assetURL := ""
	if isFontPackage(entry) {
		selected, selectedOK := selectedAsset(entry.Assets, assetName)
		if selectedOK && strings.TrimSpace(selected.URL) != "" {
			assetURL = strings.TrimSpace(selected.URL)
		} else {
			return "", "", nil, fmt.Errorf("font package %q requires an explicit ZIP asset URL", entry.ID)
		}
	} else if releaseTag == "" {
		selected, selectedOK := selectedAsset(entry.Assets, assetName)
		if selectedOK {
			assetURL = strings.TrimSpace(selected.URL)
		}
	}
	if assetName == "" {
		assetName = strings.TrimSpace(entry.SourceAsset)
	}
	if assetName == "" && genericKOReaderInstaller(entry) == genericPluginInstaller {
		assetName = ".koplugin.zip"
	}

	if assetURL == "" && usesSourcePackage(entry) {
		if strings.HasSuffix(strings.ToLower(assetName), ".lua") {
			if repository, ok := releases.GitHubRepository(entry.Source); ok {
				assetURL = "https://raw.githubusercontent.com/" + repository + "/HEAD/" + url.PathEscape(assetName)
			}
		}
		if assetURL == "" {
			assetURL = strings.TrimSpace(entry.SourceURL)
			if assetURL == "" {
				assetURL = strings.TrimSpace(entry.Source)
			}
		}
	}
	if assetURL == "" {
		versionsURL := strings.TrimSpace(entry.VersionsURL)
		if versionsURL == "" {
			return "", "", nil, fmt.Errorf("package %q has no versions metadata", entry.ID)
		}
		_, releaseAsset, err := releases.ResolveVersionsAsset(versionsURL, releaseTag, assetName)
		if err != nil {
			return "", "", nil, err
		}
		assetName = releaseAsset.Name
		assetURL = releaseAsset.URL
	}
	data, err := repo.FetchBytes(assetURL)
	if err != nil {
		return "", "", nil, fmt.Errorf("fetch %s: %w", assetURL, err)
	}
	return assetName, assetURL, data, nil
}

func (m *Manager) koreaderRoot() (string, error) {
	for _, root := range koreaderRootCandidates(m.plat) {
		if isKOReaderRoot(root) || isKOReaderPluginRoot(root) {
			return root, nil
		}
	}
	return "", fmt.Errorf("KOReader installation not found")
}

func isKOReaderRoot(root string) bool {
	if root == "" {
		return false
	}
	if _, err := os.Stat(filepath.Join(root, "koreader.sh")); err == nil {
		return true
	}
	_, err := os.Stat(filepath.Join(root, "reader.lua"))
	return err == nil
}

// Some KOReader platforms keep runnable files separately from the user data
// directory, which contains plugins and patches.
func isKOReaderPluginRoot(root string) bool {
	info, err := os.Stat(filepath.Join(root, "plugins"))
	return err == nil && info.IsDir()
}

func koreaderPluginDir(root string) string {
	if path := strings.TrimSpace(os.Getenv("ZENPM_KOREADER_PLUGIN_DIR")); path != "" {
		if filepath.IsAbs(path) {
			return filepath.Clean(path)
		}
		return filepath.Join(root, path)
	}
	return filepath.Join(root, "plugins")
}

func koreaderPatchDir(root string) string {
	if path := strings.TrimSpace(os.Getenv("ZENPM_KOREADER_PATCH_DIR")); path != "" {
		return filepath.Clean(path)
	}
	return filepath.Join(root, "patches")
}

func (m *Manager) installKOReaderPlugin(entry *repo.CatalogEntry, root, assetName string, data []byte) (string, string, error) {
	pluginsDir := koreaderPluginDir(root)
	if info, err := os.Stat(pluginsDir); err != nil || !info.IsDir() {
		return "", "", fmt.Errorf("KOReader plugins directory not found at %s", pluginsDir)
	}
	stage, sourceDir, err := m.extractArchive(data)
	if err != nil {
		return "", "", err
	}
	defer os.RemoveAll(stage)
	sourceDir = pluginArchiveSource(sourceDir)

	name := pluginTrackingName(entry, assetName)
	if base := filepath.Base(sourceDir); strings.HasSuffix(base, ".koplugin") {
		name = base
	}
	destination := filepath.Join(pluginsDir, name)
	if err := replaceTree(sourceDir, destination); err != nil {
		return "", "", err
	}
	_ = os.RemoveAll(filepath.Join(destination, "__MACOSX"))
	version, _ := koreaderPluginVersion(destination)
	return version, destination, nil
}

func pluginArchiveSource(sourceDir string) string {
	if strings.HasSuffix(filepath.Base(sourceDir), ".koplugin") {
		return sourceDir
	}
	entries, err := os.ReadDir(sourceDir)
	if err != nil {
		return sourceDir
	}
	pluginDir := ""
	for _, entry := range entries {
		if !entry.IsDir() || !strings.HasSuffix(entry.Name(), ".koplugin") {
			continue
		}
		if pluginDir != "" {
			return sourceDir
		}
		pluginDir = filepath.Join(sourceDir, entry.Name())
	}
	if pluginDir != "" {
		return pluginDir
	}
	return sourceDir
}

func (m *Manager) installKOReaderPatch(entry *repo.CatalogEntry, root, assetName string, data []byte) (string, error) {
	patchesDir := koreaderPatchDir(root)
	if err := os.MkdirAll(patchesDir, 0755); err != nil {
		return "", fmt.Errorf("create KOReader patches directory: %w", err)
	}
	if strings.HasSuffix(strings.ToLower(assetName), ".lua") {
		name := filepath.Base(assetName)
		path := filepath.Join(patchesDir, name)
		if err := os.WriteFile(path, data, 0644); err != nil {
			return "", fmt.Errorf("write patch %s: %w", path, err)
		}
		return path, nil
	}

	stage, sourceDir, err := m.extractArchive(data)
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stage)
	destination := filepath.Join(patchesDir, entry.ID)
	if err := replaceTree(sourceDir, destination); err != nil {
		return "", err
	}
	_ = os.RemoveAll(filepath.Join(destination, "__MACOSX"))
	return destination, nil
}

func (m *Manager) installKOReaderFont(entry *repo.CatalogEntry, root, assetName string, data []byte) (string, error) {
	if !strings.HasSuffix(strings.ToLower(assetName), ".zip") {
		return "", fmt.Errorf("font asset %q must be a ZIP archive", assetName)
	}
	if filepath.Base(entry.ID) != entry.ID {
		return "", fmt.Errorf("invalid font package %q", entry.ID)
	}
	fontsDir := filepath.Join(root, "fonts")
	if err := os.MkdirAll(fontsDir, 0755); err != nil {
		return "", fmt.Errorf("create KOReader fonts directory: %w", err)
	}
	stage, sourceDir, err := m.extractArchive(data)
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stage)

	directory := filepath.Base(sourceDir)
	if sourceDir == stage {
		directory = entry.ID
	}
	if directory == "." || directory == "" || filepath.Base(directory) != directory {
		return "", fmt.Errorf("invalid font directory %q", directory)
	}
	destination := filepath.Join(fontsDir, directory)
	if !pathWithinRoot(root, destination) {
		return "", fmt.Errorf("invalid KOReader font path %q", destination)
	}
	if err := replaceTree(sourceDir, destination); err != nil {
		return "", fmt.Errorf("install font directory: %w", err)
	}
	_ = os.RemoveAll(filepath.Join(destination, "__MACOSX"))
	return destination, nil
}

func (m *Manager) uninstallGenericKOReader(entry *repo.CatalogEntry, asset, kind string) error {
	root, err := m.koreaderRoot()
	if err != nil {
		return err
	}
	switch kind {
	case genericPluginInstaller:
		return removeKOReaderPlugin(root, pluginTrackingName(entry, asset))
	case genericPatchInstaller:
		path, err := m.installedPatchPath(entry.ID, asset)
		if err != nil {
			return err
		}
		return removeKOReaderPatch(root, entry.ID, asset, path)
	case genericFontInstaller:
		path, err := m.installedPackagePath(entry.ID)
		if err != nil {
			return err
		}
		return removeKOReaderFont(root, entry.ID, path)
	default:
		return fmt.Errorf("unknown generic KOReader installer %q", kind)
	}
}

func (m *Manager) installedPackagePath(id string) (string, error) {
	installed, err := m.st.ReadInstalled()
	if err != nil {
		return "", err
	}
	for _, entry := range installed {
		if entry.ID == id {
			return entry.InstallPath, nil
		}
	}
	return "", nil
}

func (m *Manager) installedPatchPath(id, asset string) (string, error) {
	installed, err := m.st.ReadInstalledPatchFiles()
	if err != nil {
		return "", err
	}
	for _, entry := range installed {
		if entry.PackageID == id && entry.Asset == asset {
			return entry.InstallPath, nil
		}
	}
	return "", nil
}

func removeKOReaderFont(root, id, fontDir string) error {
	if filepath.Base(id) != id {
		return fmt.Errorf("invalid KOReader font package %q", id)
	}
	if fontDir == "" {
		var err error
		fontDir, err = legacyKOReaderFontPath(root, id)
		if err != nil {
			return err
		}
	}
	if fontDir != "" {
		fontsDir := filepath.Join(root, "fonts")
		if filepath.Dir(filepath.Clean(fontDir)) != fontsDir || !pathWithinRoot(fontsDir, fontDir) {
			return fmt.Errorf("invalid tracked KOReader font directory %q", fontDir)
		}
		if err := os.RemoveAll(fontDir); err != nil {
			return fmt.Errorf("remove KOReader font directory %s: %w", fontDir, err)
		}
	}
	return removeLegacyKOReaderFontTracking(root, id)
}

func removeKOReaderPlugin(root, name string) error {
	destination := filepath.Join(koreaderPluginDir(root), name)
	if !pathWithinRoot(root, destination) {
		return fmt.Errorf("invalid KOReader plugin path %q", destination)
	}
	if err := os.RemoveAll(destination); err != nil {
		return fmt.Errorf("remove KOReader plugin %s: %w", destination, err)
	}
	return nil
}

func (m *Manager) removeTrackedKOReaderPlugin(pluginPath string) error {
	pluginPath = filepath.Clean(pluginPath)
	if !strings.HasSuffix(filepath.Base(pluginPath), ".koplugin") {
		return fmt.Errorf("invalid tracked KOReader plugin path %q", pluginPath)
	}
	pluginDirs, err := m.koreaderPluginDirs()
	if err != nil {
		return err
	}
	for _, pluginDir := range pluginDirs {
		if filepath.Clean(filepath.Dir(pluginPath)) != filepath.Clean(pluginDir) {
			continue
		}
		if err := os.RemoveAll(pluginPath); err != nil {
			return fmt.Errorf("remove KOReader plugin %s: %w", pluginPath, err)
		}
		return nil
	}
	return fmt.Errorf("tracked KOReader plugin path is outside the plugins directories: %q", pluginPath)
}

func removeKOReaderPatch(root, id, asset, patchPath string) error {
	asset = filepath.Base(strings.TrimSpace(asset))
	if asset == "" {
		return fmt.Errorf("KOReader patch asset is required")
	}
	if patchPath == "" {
		var err error
		patchPath, err = legacyKOReaderPatchPath(root, id, asset)
		if err != nil {
			return err
		}
	}
	if patchPath != "" {
		patchesDir := koreaderPatchDir(root)
		if filepath.Clean(patchPath) == filepath.Clean(patchesDir) || !pathWithinRoot(patchesDir, patchPath) {
			return fmt.Errorf("invalid tracked KOReader patch path %q", patchPath)
		}
		if err := os.RemoveAll(patchPath); err != nil {
			return fmt.Errorf("remove KOReader patch %s: %w", patchPath, err)
		}
		if strings.HasSuffix(strings.ToLower(asset), ".lua") {
			if err := os.Remove(patchPath + ".disabled"); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("remove disabled KOReader patch %s: %w", patchPath, err)
			}
		}
	} else {
		for _, name := range []string{asset, asset + ".disabled"} {
			path := filepath.Join(koreaderPatchDir(root), name)
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("remove KOReader patch %s: %w", path, err)
			}
		}
	}
	return removeLegacyKOReaderPatchTracking(root, id, asset)
}

func legacyKOReaderFontPath(root, id string) (string, error) {
	tracking := filepath.Join(root, ".zenpm-fonts", filepath.Base(id))
	return legacyTrackingValue(tracking, "font_dir")
}

func legacyKOReaderPatchPath(root, id, asset string) (string, error) {
	for _, name := range legacyPatchTrackingNames(id, asset) {
		tracking := filepath.Join(root, ".zenpm-patches", name)
		for _, key := range []string{"patch_dir", "patch_file"} {
			path, err := legacyTrackingValue(tracking, key)
			if err != nil && !os.IsNotExist(err) {
				return "", err
			}
			if path != "" {
				return path, nil
			}
		}
	}
	return "", nil
}

func legacyPatchTrackingNames(id, asset string) []string {
	names := []string{asset}
	if id != "" && id != asset {
		names = append(names, id)
	}
	return names
}

func removeLegacyKOReaderFontTracking(root, id string) error {
	tracking := filepath.Join(root, ".zenpm-fonts", filepath.Base(id))
	if err := os.Remove(tracking); err != nil && !os.IsNotExist(err) {
		return err
	}
	return removeEmptyDir(filepath.Dir(tracking))
}

func removeLegacyKOReaderPatchTracking(root, id, asset string) error {
	trackingDir := filepath.Join(root, ".zenpm-patches")
	for _, name := range legacyPatchTrackingNames(id, asset) {
		if err := os.Remove(filepath.Join(trackingDir, name)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return removeEmptyDir(trackingDir)
}

func legacyTrackingValue(path, key string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	prefix := key + "="
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix)), nil
		}
	}
	return "", nil
}

func removeEmptyDir(path string) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) && !os.IsExist(err) {
		return err
	}
	return nil
}

func (m *Manager) migrateLegacyKOReaderTracking() error {
	if m.st == nil {
		return nil
	}
	root, err := m.koreaderRoot()
	if err != nil {
		return nil
	}
	if err := os.RemoveAll(filepath.Join(root, ".zenpm-plugins")); err != nil {
		return err
	}
	installed, err := m.st.ReadInstalled()
	if err != nil {
		return err
	}
	for _, entry := range installed {
		if entry.InstallPath != "" {
			continue
		}
		path, err := legacyKOReaderFontPath(root, entry.ID)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		fontsDir := filepath.Join(root, "fonts")
		if path == "" || filepath.Dir(filepath.Clean(path)) != fontsDir || !pathWithinRoot(fontsDir, path) {
			continue
		}
		entry.InstallPath = path
		if err := m.st.AppendInstalled(entry); err != nil {
			return err
		}
		if err := removeLegacyKOReaderFontTracking(root, entry.ID); err != nil {
			return err
		}
	}

	patches, err := m.st.ReadInstalledPatchFiles()
	if err != nil {
		return err
	}
	for _, entry := range patches {
		if entry.InstallPath != "" {
			continue
		}
		path, err := legacyKOReaderPatchPath(root, entry.PackageID, entry.Asset)
		if err != nil {
			return err
		}
		patchesDir := koreaderPatchDir(root)
		if path == "" || filepath.Clean(path) == filepath.Clean(patchesDir) || !pathWithinRoot(patchesDir, path) {
			continue
		}
		entry.InstallPath = path
		if err := m.st.AppendInstalledPatchFile(entry); err != nil {
			return err
		}
		if err := removeLegacyKOReaderPatchTracking(root, entry.PackageID, entry.Asset); err != nil {
			return err
		}
	}
	return nil
}

func pathWithinRoot(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func pluginTrackingName(entry *repo.CatalogEntry, assetName string) string {
	name := strings.TrimSuffix(filepath.Base(assetName), ".zip")
	if !strings.HasSuffix(name, ".koplugin") {
		name = strings.TrimSpace(entry.PluginModule)
		if name == "" {
			name = entry.ID
		}
		name = strings.TrimSuffix(name, ".zip")
		if !strings.HasSuffix(name, ".koplugin") {
			name += ".koplugin"
		}
	}
	return name
}

func (m *Manager) extractArchive(data []byte) (string, string, error) {
	stage, err := os.MkdirTemp(m.st.TmpDir, "koreader-install-*")
	if err != nil {
		return "", "", fmt.Errorf("create extraction directory: %w", err)
	}
	if err := extractZip(data, stage); err != nil {
		os.RemoveAll(stage)
		return "", "", err
	}
	entries, err := os.ReadDir(stage)
	if err != nil {
		os.RemoveAll(stage)
		return "", "", err
	}
	if len(entries) == 1 && entries[0].IsDir() {
		return stage, filepath.Join(stage, entries[0].Name()), nil
	}
	return stage, stage, nil
}

func extractZip(data []byte, destination string) error {
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return fmt.Errorf("read ZIP archive: %w", err)
	}
	for _, file := range reader.File {
		name := filepath.Clean(file.Name)
		if name == "." || filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, ".."+string(filepath.Separator)) {
			return fmt.Errorf("ZIP contains unsafe path %q", file.Name)
		}
		path := filepath.Join(destination, name)
		if path != destination && !strings.HasPrefix(path, destination+string(filepath.Separator)) {
			return fmt.Errorf("ZIP contains unsafe path %q", file.Name)
		}
		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(path, 0755); err != nil {
				return err
			}
			continue
		}
		if file.Mode()&fs.ModeSymlink != 0 {
			return fmt.Errorf("ZIP contains unsupported symlink %q", file.Name)
		}
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			return err
		}
		input, err := file.Open()
		if err != nil {
			return err
		}
		mode := file.Mode().Perm()
		if mode == 0 {
			mode = 0644
		}
		output, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
		if err == nil {
			_, err = io.Copy(output, input)
			closeErr := output.Close()
			if err == nil {
				err = closeErr
			}
		}
		input.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func replaceTree(source, destination string) error {
	if err := os.RemoveAll(destination); err != nil {
		return err
	}
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, rel)
		if entry.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode().Perm())
	})
}
