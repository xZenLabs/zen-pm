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
)

func genericKOReaderInstaller(entry *repo.CatalogEntry) string {
	if entry == nil {
		return ""
	}
	installURL := strings.TrimSpace(entry.InstallURL)
	if i := strings.IndexAny(installURL, "?#"); i >= 0 {
		installURL = installURL[:i]
	}
	switch filepath.Base(installURL) {
	case "install-plugin.sh":
		return genericPluginInstaller
	case "install-patch.sh":
		return genericPatchInstaller
	default:
		return ""
	}
}

// nativeKOReaderInstaller claims ZenPM's generic KOReader scripts. Go handles
// their asset download, filesystem changes, and tracking without a shell.
func (m *Manager) nativeKOReaderInstaller(entry *repo.CatalogEntry, override string) string {
	kind := genericKOReaderInstaller(entry)
	if kind == "" || !packageHasPlatform(entry, "koreader") {
		return ""
	}
	return kind
}

// installGenericKOReader performs the work of the repository's generic shell
// installers in-process, so it does not depend on curl, wget, or BusyBox.
func (m *Manager) installGenericKOReader(entry *repo.CatalogEntry, override, releaseTag, kind string) error {
	assetName, assetURL, data, err := m.downloadInstallAsset(entry, override, releaseTag)
	if err != nil {
		return err
	}
	root, err := m.koreaderRoot()
	if err != nil {
		return err
	}

	switch kind {
	case genericPluginInstaller:
		return m.installKOReaderPlugin(entry, root, assetName, assetURL, data)
	case genericPatchInstaller:
		return m.installKOReaderPatch(entry, root, assetName, assetURL, data)
	default:
		return fmt.Errorf("unknown generic KOReader installer %q", kind)
	}
}

func (m *Manager) downloadInstallAsset(entry *repo.CatalogEntry, override, releaseTag string) (string, string, []byte, error) {
	assetName := m.installAssetName(entry, override)
	selected, selectedOK := selectedAsset(entry.Assets, assetName)
	assetURL := ""
	if selectedOK {
		assetURL = strings.TrimSpace(selected.URL)
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
		_, releaseAsset, err := releases.ResolveGitHubReleaseAsset(entry.Source, releaseTag, assetName)
		if err != nil {
			return "", "", nil, err
		}
		assetURL = releaseAsset.URL
	}
	data, err := repo.FetchBytes(assetURL)
	if err != nil {
		return "", "", nil, fmt.Errorf("fetch %s: %w", assetURL, err)
	}
	return assetName, assetURL, data, nil
}

func (m *Manager) koreaderRoot() (string, error) {
	explicitRoot := strings.TrimSpace(os.Getenv("ZENPM_KOREADER_ROOT"))
	if explicitRoot != "" {
		explicitRoot = filepath.Clean(explicitRoot)
	}
	for _, root := range koreaderRootCandidates(m.plat) {
		if isKOReaderRoot(root) || (root == explicitRoot && isKOReaderPluginRoot(root)) {
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

// Android keeps KOReader's runnable files inside its APK, while the external
// KOReader data directory only contains user files such as plugins. The
// companion supplies that directory explicitly.
func isKOReaderPluginRoot(root string) bool {
	info, err := os.Stat(filepath.Join(root, "plugins"))
	return err == nil && info.IsDir()
}

func (m *Manager) installKOReaderPlugin(entry *repo.CatalogEntry, root, assetName, assetURL string, data []byte) error {
	pluginsDir := filepath.Join(root, "plugins")
	if info, err := os.Stat(pluginsDir); err != nil || !info.IsDir() {
		return fmt.Errorf("KOReader plugins directory not found at %s", pluginsDir)
	}
	stage, sourceDir, err := m.extractArchive(data)
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)

	name := pluginTrackingName(entry, assetName)
	if base := filepath.Base(sourceDir); strings.HasSuffix(base, ".koplugin") {
		name = base
	}
	destination := filepath.Join(pluginsDir, name)
	if err := replaceTree(sourceDir, destination); err != nil {
		return err
	}
	_ = os.RemoveAll(filepath.Join(destination, "__MACOSX"))
	return writeTrackingFile(filepath.Join(root, ".zenpm-plugins", name), []string{
		"name=" + name,
		"plugin_dir=" + destination,
		"asset_url=" + assetURL,
		"asset_filename=" + assetName,
		"repo_ref=" + entry.Source,
	})
}

func (m *Manager) installKOReaderPatch(entry *repo.CatalogEntry, root, assetName, assetURL string, data []byte) error {
	patchesDir := filepath.Join(root, "patches")
	if err := os.MkdirAll(patchesDir, 0755); err != nil {
		return fmt.Errorf("create KOReader patches directory: %w", err)
	}
	trackingDir := filepath.Join(root, ".zenpm-patches")
	if strings.HasSuffix(strings.ToLower(assetName), ".lua") {
		name := filepath.Base(assetName)
		path := filepath.Join(patchesDir, name)
		if err := os.WriteFile(path, data, 0644); err != nil {
			return fmt.Errorf("write patch %s: %w", path, err)
		}
		return writeTrackingFile(filepath.Join(trackingDir, name), []string{
			"name=" + name,
			"patch_file=" + path,
			"asset_url=" + assetURL,
			"asset_filename=" + assetName,
			"repo_ref=" + entry.Source,
		})
	}

	stage, sourceDir, err := m.extractArchive(data)
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	destination := filepath.Join(patchesDir, entry.ID)
	if err := replaceTree(sourceDir, destination); err != nil {
		return err
	}
	_ = os.RemoveAll(filepath.Join(destination, "__MACOSX"))
	return writeTrackingFile(filepath.Join(trackingDir, entry.ID), []string{
		"name=" + entry.ID,
		"patch_dir=" + destination,
		"asset_url=" + assetURL,
		"asset_filename=" + assetName,
		"repo_ref=" + entry.Source,
	})
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
		return removeKOReaderPatch(root, entry.ID, asset)
	default:
		return fmt.Errorf("unknown generic KOReader installer %q", kind)
	}
}

func removeKOReaderPlugin(root, name string) error {
	tracking := filepath.Join(root, ".zenpm-plugins", name)
	destination := filepath.Join(root, "plugins", name)
	if value, err := trackingValue(tracking, "plugin_dir"); err == nil && value != "" {
		destination = value
	}
	if !pathWithinRoot(root, destination) {
		return fmt.Errorf("invalid tracked KOReader plugin path %q", destination)
	}
	if err := os.RemoveAll(destination); err != nil {
		return fmt.Errorf("remove KOReader plugin %s: %w", destination, err)
	}
	if err := os.Remove(tracking); err != nil && !os.IsNotExist(err) {
		return err
	}
	return removeEmptyDir(filepath.Dir(tracking))
}

func removeKOReaderPatch(root, id, asset string) error {
	asset = filepath.Base(strings.TrimSpace(asset))
	if asset == "" {
		return fmt.Errorf("KOReader patch asset is required")
	}
	trackingDir := filepath.Join(root, ".zenpm-patches")
	trackingNames := []string{asset}
	if id != "" && id != asset {
		trackingNames = append(trackingNames, id)
	}
	removedDir := false
	for _, name := range trackingNames {
		tracking := filepath.Join(trackingDir, name)
		if patchDir, err := trackingValue(tracking, "patch_dir"); err == nil && patchDir != "" {
			if !pathWithinRoot(root, patchDir) {
				return fmt.Errorf("invalid tracked KOReader patch path %q", patchDir)
			}
			if err := os.RemoveAll(patchDir); err != nil {
				return fmt.Errorf("remove KOReader patch %s: %w", patchDir, err)
			}
			removedDir = true
		}
		if err := os.Remove(tracking); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if !removedDir {
		for _, name := range []string{asset, asset + ".disabled"} {
			path := filepath.Join(root, "patches", name)
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("remove KOReader patch %s: %w", path, err)
			}
		}
	}
	return removeEmptyDir(trackingDir)
}

func trackingValue(path, key string) (string, error) {
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

func writeTrackingFile(path string, lines []string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0644)
}
