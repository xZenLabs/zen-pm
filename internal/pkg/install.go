package pkg

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"ZPM/internal/assets"
	"ZPM/internal/log"
	"ZPM/internal/platform"
	"ZPM/internal/releases"
	"ZPM/internal/repo"
	"ZPM/internal/state"
	"ZPM/internal/tx"
)

// Manager drives package install/uninstall/update operations.
type Manager struct {
	st    *state.State
	repos *repo.Manager
	plat  string
}

func New(st *state.State, repos *repo.Manager, plat string) *Manager {
	return &Manager{st: st, repos: repos, plat: plat}
}

func (m *Manager) Install(id string) error {
	return m.InstallAsset(id, "")
}

// InstallAsset installs id, forcing assetOverride as the release asset when non-empty.
// When empty, the asset is auto-selected for the current device.
func (m *Manager) InstallAsset(id, assetOverride string) error {
	catalog, err := m.repos.ReadCatalog()
	if err != nil {
		return fmt.Errorf("read catalog: %w", err)
	}
	installed, _ := m.st.ReadInstalled()
	installedSet := make(map[string]bool, len(installed))
	for _, e := range installed {
		installedSet[e.ID] = true
	}
	plan, err := ResolvePlanWithInstalled(id, catalog, installedSet)
	if err != nil {
		return err
	}

	j, err := tx.Begin(m.st, "install", id)
	if err != nil {
		return err
	}

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
		log.Infof("Installing %s %s from repo %s", entry.ID, displayVersion(entry.Version), entry.Repo)

		j.Record("fetch-script", "ok", "pkg="+pkgID)
		scriptPath, err := m.repos.FetchScript(entry.InstallURL)
		if err != nil {
			j.Abort("fetch failed: " + err.Error())
			return fmt.Errorf("fetch install script for %s: %w", pkgID, err)
		}

		override := ""
		if pkgID == id {
			override = assetOverride
		}
		j.Record("execute", "ok", fmt.Sprintf("pkg=%s ver=%s", pkgID, entry.Version))
		if err := platform.ExecuteScriptWithEnv(scriptPath, m.installEnv(entry, override)); err != nil {
			j.Abort("execute failed: " + err.Error())
			return fmt.Errorf("install script failed for %s: %w", pkgID, err)
		}

		if err := m.cacheUninstallScript(entry); err != nil {
			log.Warnf("Could not cache uninstall script for %s: %v", pkgID, err)
		}

		installedVersion := releaseVersion(entry)

		_ = m.st.RemoveInstalled(pkgID)
		if err := m.st.AppendInstalled(state.InstalledEntry{
			ID: pkgID, Name: entry.Name, Version: installedVersion, Repo: entry.Repo,
		}); err != nil {
			j.Abort("record failed: " + err.Error())
			return err
		}
		log.Infof("Installed: %s %s", pkgID, displayVersion(installedVersion))
	}

	j.Commit()
	return nil
}

func (m *Manager) Uninstall(id string) error {
	ok, _ := m.st.IsInstalled(id)
	if !ok {
		return fmt.Errorf("package %q is not installed", id)
	}

	catalog, _ := m.repos.ReadCatalog()
	var entry *repo.CatalogEntry
	for _, e := range catalog {
		if e.ID == id {
			entry = e
			break
		}
	}

	j, err := tx.Begin(m.st, "uninstall", id)
	if err != nil {
		return err
	}

	scriptPath := ""
	if entry != nil && entry.UninstallURL != "" {
		scriptPath, err := m.repos.FetchScript(entry.UninstallURL)
		if err != nil {
			log.Warnf("Fetch uninstall script failed for %s, trying cached script: %v", id, err)
			scriptPath = m.st.CachedUninstallScriptPath(id)
			if _, statErr := os.Stat(scriptPath); statErr != nil {
				j.Abort("fetch failed: " + err.Error())
				return fmt.Errorf("fetch uninstall script: %w", err)
			}
		}
	} else {
		scriptPath = m.st.CachedUninstallScriptPath(id)
		if _, err := os.Stat(scriptPath); err != nil {
			scriptPath = ""
		}
	}

	if scriptPath != "" {
		if err := platform.ExecuteScript(scriptPath); err != nil {
			j.Abort("execute failed: " + err.Error())
			return fmt.Errorf("uninstall script failed: %w", err)
		}
	}

	if err := m.st.RemoveInstalled(id); err != nil {
		j.Abort("remove from db failed: " + err.Error())
		return err
	}
	_ = os.Remove(m.st.CachedUninstallScriptPath(id))

	log.Infof("Uninstalled: %s", id)
	j.Commit()
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
	dev := assets.Device{Platform: m.plat}
	if m.plat == platform.Kindle {
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
			return assets.Select(e.Assets, m.device()), nil
		}
	}
	return assets.Result{}, fmt.Errorf("package %q not found", id)
}

func (m *Manager) installEnv(entry *repo.CatalogEntry, override string) map[string]string {
	env := map[string]string{
		"ZENPM_PACKAGE_ID": entry.ID,
	}
	if entry.Source != "" {
		env["ZENPM_PACKAGE_SOURCE"] = entry.Source
	}

	asset := strings.TrimSpace(override)
	if asset == "" {
		if res := assets.Select(entry.Assets, m.device()); res.Auto != "" {
			asset = res.Auto
		}
	}

	if asset != "" {
		log.Infof("Package %s using release asset %q", entry.ID, asset)
		env["ZENPM_PACKAGE_SOURCE_ASSET"] = asset
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
	if entry == nil || !strings.HasSuffix(entry.InstallURL, "/install-plugin.sh") {
		return false
	}
	for _, platform := range entry.Platforms {
		if strings.EqualFold(strings.TrimSpace(platform), "koreader") {
			return true
		}
	}
	return false
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
		latestVersion := releaseVersion(latest)
		if releases.VersionGreater(latestVersion, e.Version) {
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

func releaseVersion(entry *repo.CatalogEntry) string {
	if entry == nil {
		return ""
	}
	if latest, err := releases.LatestGitHubReleaseTag(entry.Source); err == nil && latest != "" {
		return latest
	}
	return entry.Version
}
