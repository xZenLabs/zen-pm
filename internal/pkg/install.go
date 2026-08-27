package pkg

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	"github.com/xZenLabs/zen-pm/internal/assets"
	"github.com/xZenLabs/zen-pm/internal/log"
	"github.com/xZenLabs/zen-pm/internal/platform"
	"github.com/xZenLabs/zen-pm/internal/releases"
	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
)

// Manager drives package install/uninstall/update operations.
type Manager struct {
	st    *state.State
	repos *repo.Manager
	plat  string
}

func New(st *state.State, repos *repo.Manager, plat string) *Manager {
	m := &Manager{st: st, repos: repos, plat: plat}
	if err := m.migrateLegacyKOReaderTracking(); err != nil {
		log.Warnf("Could not migrate legacy KOReader tracking: %v", err)
	}
	if err := m.reconcileKOReaderPluginAliasRecords(); err != nil {
		log.Warnf("Could not reconcile KOReader plugin aliases: %v", err)
	}
	return m
}

func (m *Manager) Install(id string) error {
	return m.InstallAsset(id, "")
}

func (m *Manager) CheckInstall(id string) error {
	_, _, _, _, err := m.installPlan(id)
	return err
}

// InstallAsset installs id, forcing assetOverride as the release asset when non-empty.
// When empty, the asset is auto-selected for the current device.
func (m *Manager) InstallAsset(id, assetOverride string) error {
	return m.installAssetRelease(id, assetOverride, "", true)
}

// InstallRelease installs a specific release and records its tag as the
// installed version.
func (m *Manager) InstallRelease(id, tag, assetOverride string) error {
	return m.installAssetRelease(id, assetOverride, tag, true)
}

// Reinstall removes an installed package before installing it again. When tag
// is non-empty, it installs that specific release.
func (m *Manager) Reinstall(id, assetOverride, tag string) error {
	uninstallAsset := ""
	if m.isPatchFileInstalled(id, assetOverride) {
		uninstallAsset = assetOverride
	}
	if err := m.Uninstall(id, uninstallAsset); err != nil {
		return fmt.Errorf("uninstall %s: %w", id, err)
	}
	if tag != "" {
		return m.installAssetRelease(id, assetOverride, tag, false)
	}
	return m.installAssetRelease(id, assetOverride, "", false)
}

func (m *Manager) installAssetRelease(id, assetOverride, releaseTag string, markTargetNew bool) (retErr error) {
	catalog, plan, installedSet, launcherPendingSet, err := m.installPlan(id)
	if err != nil {
		return err
	}

	if err := m.st.LockAcquire("operation"); err != nil {
		return err
	}
	log.Infof("Package operation started: install %s", id)
	defer func() {
		m.st.LockRelease("operation")
		if retErr != nil {
			log.Errorf("Package operation failed: install %s: %v", id, retErr)
			return
		}
		log.Infof("Package operation completed: install %s", id)
	}()

	byID := make(map[string]*repo.CatalogEntry, len(catalog))
	for _, e := range catalog {
		byID[e.ID] = e
	}

	for _, pkgID := range plan {
		if installedSet[pkgID] && pkgID != id {
			log.Infof("Already installed: %s", pkgID)
			continue
		}
		entry := byID[pkgID]
		override := ""
		if pkgID == id {
			override = assetOverride
		}
		installEntry := entry
		if pkgID == id && releaseTag != "" && !isFontPackage(entry) {
			releaseSource, err := releases.GitHubReleaseURL(entry.Source, releaseTag)
			if err != nil {
				return err
			}
			entryCopy := *entry
			entryCopy.Source = releaseSource
			entryCopy.Version = releaseTag
			installEntry = &entryCopy
		}
		patchReason := patchPackageReason(entry)
		log.Infof("Package %s patch classification: patch=%t reason=%s category=%q install_url=%q source=%q source_type=%q assets=%d selected_asset=%q",
			pkgID, patchReason != "", patchReason, entry.Category, shortLogValue(entry.InstallURL), shortLogValue(entry.Source), entry.SourceType, len(assets.Parse(entry.Assets)), override)
		if patchAsset := ""; patchReason != "" {
			patchAsset = m.resolvePatchAsset(entry, override)
			log.Infof("Installing patch file %q from %s (repo %s)", patchAsset, entry.ID, entry.Repo)
		} else {
			log.Infof("Installing %s %s from repo %s", entry.ID, displayVersion(installEntry.Version), entry.Repo)
		}
		genericInstaller := m.nativeKOReaderInstaller(entry, override)
		launcherAddPending := genericInstaller == genericPluginInstaller &&
			(launcherPendingSet[pkgID] || (!installedSet[pkgID] && (pkgID != id || markTargetNew)))
		if genericInstaller == genericPluginInstaller {
			override, err = m.prepareKOReaderPluginInstall(entry, override)
			if err != nil {
				return fmt.Errorf("install %s: %w", pkgID, err)
			}
		}
		installedPluginVersion := ""
		installedPath := ""
		if genericInstaller != "" {
			var err error
			installedPluginVersion, installedPath, err = m.installGenericKOReader(entry, override, releaseTag, genericInstaller)
			if err != nil {
				return fmt.Errorf("install %s: %w", pkgID, err)
			}
		} else {
			scriptPath, err := m.repos.FetchScript(entry.InstallURL)
			if err != nil {
				return fmt.Errorf("fetch install script for %s: %w", pkgID, err)
			}
			if err := platform.ExecuteScriptWithEnv(scriptPath, m.installEnv(installEntry, override)); err != nil {
				return fmt.Errorf("install script failed for %s: %w", pkgID, err)
			}
		}
		if genericInstaller == "" {
			if err := m.cacheUninstallScript(entry); err != nil {
				log.Warnf("Could not cache uninstall script for %s: %v", pkgID, err)
			}
		}

		installedVersion := installEntry.Version
		if genericInstaller == genericPluginInstaller {
			installedVersion = releaseTag
			if installedPluginVersion != "" && installedPluginVersion != "0.0.0" {
				installedVersion = installedPluginVersion
			}
		}

		if patchReason != "" {
			asset := m.resolvePatchAsset(entry, override)
			if asset == "" {
				return fmt.Errorf("install %s: could not resolve patch file name", pkgID)
			}
			_ = m.st.RemoveInstalled(pkgID)
			if err := m.st.AppendInstalledPatchFile(state.PatchFileEntry{
				PackageID: pkgID, Asset: asset, Name: entry.Name, Version: installedVersion, Repo: entry.Repo, InstallPath: installedPath,
			}); err != nil {
				return err
			}
			log.Infof("Installed patch file: %s / %s", pkgID, asset)
			continue
		}

		selectedName, selectedArch := m.installedAsset(installEntry, override)
		if genericInstaller == genericPluginInstaller {
			if err := m.removeConflictingKOReaderPluginRecords(pkgID, installedPath, catalog); err != nil {
				return err
			}
		}
		_ = m.st.RemoveInstalled(pkgID)
		if err := m.st.AppendInstalled(state.InstalledEntry{
			ID: pkgID, Name: entry.Name, Version: installedVersion, Repo: entry.Repo,
			Asset: selectedName, AssetArch: selectedArch, InstallPath: installedPath,
			LauncherAddPending: launcherAddPending,
		}); err != nil {
			return err
		}
		log.Infof("Installed: %s %s", pkgID, displayVersion(installedVersion))
	}

	return nil
}

func (m *Manager) installPlan(id string) ([]*repo.CatalogEntry, []string, map[string]bool, map[string]bool, error) {
	catalog, err := m.repos.ReadCatalog()
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("read catalog: %w", err)
	}
	installed, _ := m.st.ReadInstalled()
	installedSet := m.installedDependencySet(installed)
	launcherPendingSet := make(map[string]bool)
	for _, entry := range installed {
		if entry.LauncherAddPending {
			launcherPendingSet[entry.ID] = true
		}
	}
	plan, err := ResolvePlanWithInstalled(id, catalog, installedSet)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	return catalog, plan, installedSet, launcherPendingSet, nil
}

func (m *Manager) installedDependencySet(installed []state.InstalledEntry) map[string]bool {
	installedSet := make(map[string]bool, len(installed)+1)
	for _, e := range installed {
		installedSet[e.ID] = true
	}
	if m.plat == platform.Kindle && platform.KindleHasKUAL() {
		installedSet["kual"] = true
	}
	return installedSet
}

func (m *Manager) removeConflictingKOReaderPluginRecords(id, installPath string, catalog []*repo.CatalogEntry) error {
	installPath = strings.TrimSpace(installPath)
	if !strings.HasSuffix(filepath.Base(installPath), ".koplugin") {
		return nil
	}
	installPath = filepath.Clean(installPath)
	pluginName := filepath.Base(installPath)
	conflictingIDs := make(map[string]bool)
	for _, entry := range catalog {
		if entry == nil || entry.ID == id || !isGenericKOReaderPlugin(entry) {
			continue
		}
		if pluginTrackingName(entry, entry.SourceAsset) == pluginName {
			conflictingIDs[entry.ID] = true
		}
	}
	installed, err := m.st.ReadInstalled()
	if err != nil {
		return err
	}
	for _, entry := range installed {
		if entry.ID == id {
			continue
		}
		samePath := entry.InstallPath != "" && filepath.Clean(entry.InstallPath) == installPath
		sameAsset := strings.TrimSuffix(filepath.Base(strings.TrimSpace(entry.Asset)), ".zip") == pluginName
		if !samePath && !sameAsset && !conflictingIDs[entry.ID] {
			continue
		}
		if err := m.st.RemoveInstalled(entry.ID); err != nil {
			return fmt.Errorf("remove conflicting KOReader plugin %s: %w", entry.ID, err)
		}
	}
	return nil
}

func (m *Manager) Uninstall(id, asset string) (retErr error) {
	asset = strings.TrimSpace(asset)
	isPatch := asset != ""
	trackedPluginPath := ""
	if isPatch {
		if !m.isPatchFileInstalled(id, asset) {
			return fmt.Errorf("patch file %q of %q is not installed", asset, id)
		}
		log.Infof("Uninstalling patch file %s / %s", id, asset)
	} else {
		ok, _ := m.st.IsInstalled(id)
		if !ok {
			return fmt.Errorf("package %q is not installed", id)
		}
		installedPath, err := m.installedPackagePath(id)
		if err != nil {
			return fmt.Errorf("read installed package %q: %w", id, err)
		}
		if strings.HasSuffix(filepath.Base(installedPath), ".koplugin") {
			trackedPluginPath = installedPath
		}
		log.Infof("Uninstalling %s", id)
	}

	entry := m.findCatalogEntry(id)
	trackedUnmatchedPlugin := trackedPluginPath != "" &&
		(!validKOReaderPluginName(filepath.Base(trackedPluginPath)) ||
			m.nativeKOReaderInstaller(entry, asset) != genericPluginInstaller)
	if !trackedUnmatchedPlugin &&
		(entry == nil || (entry.UninstallURL == "" && m.nativeKOReaderInstaller(entry, asset) == "")) {
		log.Warnf("Package %s uninstall script missing from catalog; refreshing catalog", id)
		if err := m.repos.Refresh(); err != nil {
			log.Warnf("Package %s catalog refresh before uninstall failed: %v", id, err)
		} else {
			entry = m.findCatalogEntry(id)
		}
	}

	if err := m.st.LockAcquire("operation"); err != nil {
		return err
	}
	log.Infof("Package operation started: uninstall %s", id)
	defer func() {
		m.st.LockRelease("operation")
		if retErr != nil {
			log.Errorf("Package operation failed: uninstall %s: %v", id, retErr)
			return
		}
		log.Infof("Package operation completed: uninstall %s", id)
	}()

	genericInstaller := m.nativeKOReaderInstaller(entry, asset)
	if trackedUnmatchedPlugin {
		if err := m.removeTrackedKOReaderPlugin(trackedPluginPath); err != nil {
			return err
		}
		log.Infof("Package %s removed from tracked KOReader plugin path %s", id, trackedPluginPath)
	} else if genericInstaller != "" {
		if err := m.uninstallGenericKOReader(entry, asset, genericInstaller); err != nil {
			return err
		}
		log.Infof("Package %s removed with native KOReader installer", id)
	} else if entry != nil && entry.UninstallURL != "" {
		log.Infof("Package %s uninstall metadata: repo=%s version=%s uninstall_url=%s", id, entry.Repo, displayVersion(entry.Version), entry.UninstallURL)
		scriptPath, err := m.repos.FetchScript(entry.UninstallURL)
		if err != nil {
			log.Warnf("Fetch uninstall script failed for %s, trying cached script: %v", id, err)
			scriptPath = m.st.CachedUninstallScriptPath(id)
			if _, statErr := os.Stat(scriptPath); statErr != nil {
				return fmt.Errorf("fetch uninstall script: %w", err)
			}
			log.Infof("Package %s using cached uninstall script: %s", id, scriptPath)
		} else {
			log.Infof("Package %s fetched uninstall script to %s", id, scriptPath)
		}
		if scriptPath != "" {
			log.Infof("Package %s executing uninstall script: %s", id, scriptPath)
			env := m.uninstallEnv(id)
			if isPatch {
				env["ZENPM_PACKAGE_SOURCE_ASSET"] = asset
			} else if entry != nil && isGenericKOReaderPlugin(entry) {
				if asset := m.installAssetName(entry, ""); asset != "" {
					env["ZENPM_PACKAGE_SOURCE_ASSET"] = asset
				} else if entry.SourceAsset != "" {
					env["ZENPM_PACKAGE_SOURCE_ASSET"] = entry.SourceAsset
				}
			}
			if err := platform.ExecuteScriptWithEnv(scriptPath, env); err != nil {
				return fmt.Errorf("uninstall script failed: %w", err)
			}
			log.Infof("Package %s uninstall script completed", id)
		}
	} else {
		scriptPath := m.st.CachedUninstallScriptPath(id)
		if _, err := os.Stat(scriptPath); err == nil {
			log.Infof("Package %s using cached uninstall script: %s", id, scriptPath)
			log.Infof("Package %s executing uninstall script: %s", id, scriptPath)
			env := m.uninstallEnv(id)
			if isPatch {
				env["ZENPM_PACKAGE_SOURCE_ASSET"] = asset
			}
			if err := platform.ExecuteScriptWithEnv(scriptPath, env); err != nil {
				return fmt.Errorf("uninstall script failed: %w", err)
			}
			log.Infof("Package %s uninstall script completed", id)
		} else {
			log.Warnf("Package %s has no uninstall script; removing installed record only", id)
		}
	}

	if isPatch {
		if err := m.st.RemoveInstalledPatchFile(id, asset); err != nil {
			return err
		}
		log.Infof("Uninstalled patch file: %s / %s", id, asset)
		return nil
	}

	if err := m.st.RemoveInstalled(id); err != nil {
		return err
	}
	_ = os.Remove(m.st.CachedUninstallScriptPath(id))

	log.Infof("Uninstalled: %s", id)
	return nil
}

func (m *Manager) findCatalogEntry(id string) *repo.CatalogEntry {
	catalog, err := m.repos.ReadCatalog()
	if err != nil {
		log.Warnf("Read catalog before uninstall failed for %s: %v", id, err)
		return nil
	}
	for _, e := range catalog {
		if e.ID == id {
			return e
		}
	}
	return nil
}

func (m *Manager) cacheUninstallScript(entry *repo.CatalogEntry) error {
	if entry == nil || entry.UninstallURL == "" {
		return nil
	}
	data, err := repo.FetchBytes(entry.UninstallURL)
	if err != nil {
		return err
	}
	path := m.st.CachedUninstallScriptPath(entry.ID)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0755)
}

func (m *Manager) device() assets.Device {
	devicePlatform := strings.SplitN(m.plat, ",", 2)[0]
	dev := assets.Device{Platform: devicePlatform, OS: runtime.GOOS, Arch: runtime.GOARCH}
	if devicePlatform == platform.Kindle {
		dev.KindleHF = platform.KindleABI() == "hf"
		dev.CortexA9 = platform.KindleIsCortexA9()
	}
	return dev
}

// SelectAsset resolves asset selection for id against the current device.
func (m *Manager) SelectAsset(id string) (assets.Result, error) {
	catalog, err := m.repos.ReadCatalog()
	if err != nil {
		return assets.Result{}, err
	}
	for _, e := range catalog {
		if e.ID == id {
			if isPatchPackage(e) {
				parsed := assets.Parse(e.Assets)
				if len(parsed) > 1 {
					return assets.Result{Candidates: parsed, NeedsChoice: true}, nil
				}
				if len(parsed) == 1 {
					return assets.Result{Auto: parsed[0].Asset}, nil
				}
			}
			return m.selectAssetWithError(e)
		}
	}
	return assets.Result{}, fmt.Errorf("package %q not found", id)
}

func (m *Manager) installEnv(entry *repo.CatalogEntry, override string) map[string]string {
	env := m.baseScriptEnv(entry.ID)

	asset := m.installAssetName(entry, override)
	selectedAsset, hasSelectedAsset := selectedAsset(entry.Assets, asset)
	if entry.SourceURL != "" {
		env["ZENPM_PACKAGE_SOURCE_URL"] = entry.SourceURL
	}
	if source := packageSourceRef(entry, selectedAsset, hasSelectedAsset); source != "" {
		env["ZENPM_PACKAGE_SOURCE"] = source
	}

	if asset != "" {
		if usesSourcePackage(entry) {
			log.Infof("Package %s using source asset %q", entry.ID, asset)
		} else {
			log.Infof("Package %s using release asset %q", entry.ID, asset)
		}
		env["ZENPM_PACKAGE_SOURCE_ASSET"] = asset
		addSelectedAssetEnv(env, selectedAsset, hasSelectedAsset, !usesSourcePackage(entry))
	} else if entry.SourceAsset != "" {
		log.Infof("Package %s using source asset pattern %q", entry.ID, entry.SourceAsset)
		env["ZENPM_PACKAGE_SOURCE_ASSET"] = entry.SourceAsset
	} else if entry.Source != "" && isGenericKOReaderPlugin(entry) {
		log.Warnf("Package %s has no source_asset; falling back to .koplugin.zip asset pattern", entry.ID)
		env["ZENPM_PACKAGE_SOURCE_ASSET"] = ".koplugin.zip"
	} else if entry.Source != "" {
		log.Warnf("Package %s has source but no source_asset; install script may choose its default asset", entry.ID)
	}
	return env
}

func (m *Manager) installAssetName(entry *repo.CatalogEntry, override string) string {
	asset := strings.TrimSpace(override)
	if asset == "" {
		asset = m.selectAsset(entry).Auto
	}
	return asset
}

func (m *Manager) selectAsset(entry *repo.CatalogEntry) assets.Result {
	result, _ := m.selectAssetWithError(entry)
	return result
}

func (m *Manager) selectAssetWithError(entry *repo.CatalogEntry) (assets.Result, error) {
	result := assets.Select(entry.Assets, m.device())
	if result.Auto != "" || !result.NeedsChoice {
		return result, nil
	}
	if asset, ok, err := m.selectKOReaderPluginIdentityAsset(entry, result.Candidates); err != nil {
		return result, err
	} else if ok {
		return assets.Result{Auto: asset}, nil
	}
	installed, err := m.st.ReadInstalled()
	if err != nil {
		return result, nil
	}
	for _, item := range installed {
		if item.ID != entry.ID || item.Asset == "" {
			continue
		}
		for _, candidate := range result.Candidates {
			if assetNamesMatchIgnoringVersion(candidate.Asset, item.Asset) {
				return assets.Result{Auto: candidate.Asset}, nil
			}
		}
		if isSpecificAssetArch(item.AssetArch) {
			match := ""
			for _, candidate := range result.Candidates {
				if strings.EqualFold(candidate.Arch, item.AssetArch) {
					if match != "" {
						match = ""
						break
					}
					match = candidate.Asset
				}
			}
			if match != "" {
				return assets.Result{Auto: match}, nil
			}
		}
	}
	return result, nil
}

func (m *Manager) installedAsset(entry *repo.CatalogEntry, override string) (string, string) {
	name := m.installAssetName(entry, override)
	asset, ok := selectedAsset(entry.Assets, name)
	if !ok {
		return name, ""
	}
	return name, asset.Arch
}

var assetVersion = regexp.MustCompile(`(?i)(^|[^a-z0-9])v?[0-9]+(?:[._][0-9]+)+`)

func assetNamesMatchIgnoringVersion(a, b string) bool {
	normalize := func(name string) string {
		name = strings.ToLower(strings.TrimSpace(name))
		name = assetVersion.ReplaceAllString(name, "$1")
		return strings.Map(func(r rune) rune {
			if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
				return r
			}
			return -1
		}, name)
	}
	return normalize(a) != "" && normalize(a) == normalize(b)
}

func isSpecificAssetArch(arch string) bool {
	arch = strings.TrimSpace(arch)
	return arch != "" && !strings.EqualFold(arch, "any") && !strings.EqualFold(arch, "all")
}

func sourceType(entry *repo.CatalogEntry) string {
	return strings.ToLower(strings.TrimSpace(entry.SourceType))
}

func usesSourcePackage(entry *repo.CatalogEntry) bool {
	return entry != nil && sourceType(entry) == "source"
}

func packageSourceRef(entry *repo.CatalogEntry, selected assets.Asset, hasSelected bool) string {
	if usesSourcePackage(entry) && hasSelected && strings.TrimSpace(selected.URL) != "" {
		return strings.TrimSpace(selected.URL)
	}
	if usesSourcePackage(entry) && strings.TrimSpace(entry.SourceURL) != "" {
		return strings.TrimSpace(entry.SourceURL)
	}
	return strings.TrimSpace(entry.Source)
}

func selectedAsset(rawAssets, selected string) (assets.Asset, bool) {
	for _, asset := range assets.Parse(rawAssets) {
		if asset.Asset == selected {
			return asset, true
		}
	}
	return assets.Asset{}, false
}

func addSelectedAssetEnv(env map[string]string, asset assets.Asset, ok bool, includeURL bool) {
	if !ok {
		return
	}
	if includeURL && asset.URL != "" {
		env["ZENPM_PACKAGE_ASSET_URL"] = asset.URL
	}
	if asset.Size != "" {
		env["ZENPM_PACKAGE_ASSET_SIZE"] = asset.Size
	}
	if asset.Arch != "" {
		env["ZENPM_PACKAGE_ASSET_ARCH"] = asset.Arch
	}
}

func (m *Manager) uninstallEnv(id string) map[string]string {
	return m.baseScriptEnv(id)
}

func (m *Manager) baseScriptEnv(id string) map[string]string {
	env := map[string]string{
		"ZENPM_PACKAGE_ID": id,
	}
	if m.plat == platform.Kindle {
		env["ZENPM_USE_GO_CURL"] = "1"
	}
	if m.st != nil {
		caBundle := m.st.CABundle
		if m.plat == platform.Kindle && m.st.RSACABundle != "" {
			caBundle = m.st.RSACABundle
		}
		if caBundle != "" {
			env["CURL_CA_BUNDLE"] = caBundle
			env["SSL_CERT_FILE"] = caBundle
		}
	}
	addKOReaderEnv(env, m.plat)
	return env
}

func addKOReaderEnv(env map[string]string, plat string) {
	pluginDir := strings.TrimSpace(os.Getenv("ZENPM_KOREADER_PLUGIN_DIR"))
	patchDir := strings.TrimSpace(os.Getenv("ZENPM_KOREADER_PATCH_DIR"))
	if pluginDir != "" {
		env["ZENPM_KOREADER_PLUGIN_DIR"] = filepath.Clean(pluginDir)
	}
	if patchDir != "" {
		env["ZENPM_KOREADER_PATCH_DIR"] = filepath.Clean(patchDir)
	}
	candidates := koreaderRootCandidates(plat)
	if len(candidates) == 0 {
		return
	}
	explicit := map[string]bool{}
	for _, root := range []string{os.Getenv("ZENPM_KOREADER_DIR"), os.Getenv("KOREADER_DIR")} {
		root = strings.TrimSpace(root)
		if root != "" {
			explicit[filepath.Clean(root)] = true
		}
	}
	env["ZENPM_KOREADER_PATHS"] = strings.Join(candidates, ":")
	for _, root := range candidates {
		if root == "" {
			continue
		}
		if explicit[root] || pathExists(root) {
			env["ZENPM_KOREADER_DIR"] = root
			if pluginDir == "" {
				env["ZENPM_KOREADER_PLUGIN_DIR"] = filepath.Join(root, "plugins")
			}
			if patchDir == "" {
				env["ZENPM_KOREADER_PATCH_DIR"] = filepath.Join(root, "patches")
			}
			return
		}
	}
}

func koreaderRootCandidates(plat string) []string {
	var candidates []string
	seen := map[string]bool{}
	add := func(path string) {
		path = strings.TrimSpace(path)
		if path == "" {
			return
		}
		path = filepath.Clean(path)
		if !seen[path] {
			seen[path] = true
			candidates = append(candidates, path)
		}
	}

	add(os.Getenv("ZENPM_KOREADER_DIR"))
	add(os.Getenv("ZENPM_KOREADER_ROOT"))
	add(os.Getenv("KOREADER_DIR"))
	if pluginsDir := strings.TrimSpace(os.Getenv("ZENPM_KOREADER_PLUGIN_DIR")); pluginsDir != "" {
		pluginsDir = filepath.Clean(pluginsDir)
		if filepath.IsAbs(pluginsDir) && filepath.Base(pluginsDir) == "plugins" {
			add(filepath.Dir(pluginsDir))
		}
	}
	switch plat {
	case platform.Kindle:
		add("/mnt/us/koreader")
	case platform.Kobo:
		add("/mnt/onboard/.adds/koreader")
	case platform.Host:
		if home, err := os.UserHomeDir(); err == nil {
			add(filepath.Join(home, ".config", "koreader"))
		}
	}
	return candidates
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func displayVersion(version string) string {
	version = strings.TrimSpace(version)
	if version == "" {
		return "v0.0.0"
	}
	if strings.HasPrefix(strings.ToLower(version), "v") {
		return version
	}
	return "v" + version
}

func isGenericKOReaderPlugin(entry *repo.CatalogEntry) bool {
	return genericKOReaderInstaller(entry) == genericPluginInstaller
}

func isPatchPackage(entry *repo.CatalogEntry) bool {
	return patchPackageReason(entry) != ""
}

func isFontPackage(entry *repo.CatalogEntry) bool {
	if entry == nil {
		return false
	}
	category := strings.ToLower(strings.TrimSpace(entry.Category))
	category = strings.ReplaceAll(category, "-", "")
	category = strings.ReplaceAll(category, "_", "")
	category = strings.ReplaceAll(category, " ", "")
	return category == "font" || category == "fonts"
}

func patchPackageReason(entry *repo.CatalogEntry) string {
	if entry == nil {
		return ""
	}
	category := strings.ToLower(strings.TrimSpace(entry.Category))
	category = strings.ReplaceAll(category, "-", "")
	category = strings.ReplaceAll(category, "_", "")
	category = strings.ReplaceAll(category, " ", "")
	if category == "patch" || category == "patches" ||
		category == "koreaderpatch" || category == "koreaderpatches" {
		return "category"
	}

	installURL := strings.TrimSpace(entry.InstallURL)
	if i := strings.IndexAny(installURL, "?#"); i >= 0 {
		installURL = installURL[:i]
	}
	if filepath.Base(installURL) == "install-patch.sh" {
		return "install_url"
	}

	source := strings.ToLower(strings.Join([]string{entry.Source, entry.SourceURL, entry.SourceAsset}, " "))
	if strings.Contains(source, "koreader.patches") || strings.Contains(source, "koreader-patches") {
		return "source"
	}

	parsed := assets.Parse(entry.Assets)
	if len(parsed) > 0 && packageHasPlatform(entry, "koreader") {
		allLua := true
		for _, asset := range parsed {
			name := strings.ToLower(strings.TrimSpace(asset.Asset))
			url := strings.ToLower(strings.TrimSpace(asset.URL))
			if !strings.HasSuffix(name, ".lua") && !strings.Contains(url, ".lua") {
				allLua = false
				break
			}
		}
		if allLua {
			return "lua_assets"
		}
	}

	return ""
}

func packageHasPlatform(entry *repo.CatalogEntry, platform string) bool {
	if entry == nil {
		return false
	}
	platform = strings.ToLower(strings.TrimSpace(platform))
	for _, value := range entry.Platforms {
		if strings.ToLower(strings.TrimSpace(value)) == platform {
			return true
		}
	}
	return false
}

func shortLogValue(value string) string {
	value = strings.TrimSpace(value)
	if len(value) <= 120 {
		return value
	}
	return value[:117] + "..."
}

func (m *Manager) isPatchFileInstalled(id, asset string) bool {
	files, err := m.st.ReadInstalledPatchFiles()
	if err != nil {
		return false
	}
	for _, f := range files {
		if f.PackageID == id && f.Asset == asset {
			return true
		}
	}
	return false
}

// resolvePatchAsset returns the patch file name for a patch install, using the
// explicit override when given, else the sole asset when the package has one.
func (m *Manager) resolvePatchAsset(entry *repo.CatalogEntry, override string) string {
	if override = strings.TrimSpace(override); override != "" {
		return override
	}
	parsed := assets.Parse(entry.Assets)
	if len(parsed) == 1 {
		return parsed[0].Asset
	}
	return ""
}

func (m *Manager) Update(id string) error {
	installed, err := m.st.ReadInstalled()
	if err != nil {
		return err
	}
	catalog, err := m.repos.ReadCatalog()
	if err != nil {
		return err
	}
	byID := make(map[string]*repo.CatalogEntry, len(catalog))
	for _, e := range catalog {
		byID[e.ID] = e
	}

	for _, e := range installed {
		if id != "" && e.ID != id {
			continue
		}
		latest, ok := byID[e.ID]
		if !ok {
			log.Warnf("Package %s not in any repo, skipping", e.ID)
			continue
		}
		latestVersion := latest.Version
		if releases.VersionGreater(latestVersion, e.Version) {
			if id == "" && (e.UpdateIgnored || e.UpdateIgnoredVersion == latestVersion) {
				log.Infof("Package %s has updates ignored, skipping", e.ID)
				continue
			}
			log.Infof("Updating %s: %s -> %s", e.ID, e.Version, latestVersion)
			if err := m.Install(e.ID); err != nil {
				return err
			}
		} else {
			log.Infof("Package %s is up to date (%s)", e.ID, e.Version)
		}
	}
	return nil
}
