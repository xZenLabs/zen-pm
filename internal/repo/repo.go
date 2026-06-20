package repo

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"ZPM/internal/log"
	"ZPM/internal/state"
)

// Manager wraps all repository operations.
type Manager struct {
	st *state.State
}

// UserAddedPriority is the fixed priority assigned to all user-added repos.
// Lower numbers = higher priority. Default repos use priority 10.
const UserAddedPriority = 100

func New(st *state.State) *Manager {
	return &Manager{st: st}
}

// GetState exposes the underlying state (needed by callers that only hold a Manager).
func (m *Manager) GetState() *state.State {
	return m.st
}

func (m *Manager) List() ([]state.RepoEntry, error) {
	return m.st.ReadRepos()
}

func (m *Manager) Add(name, url string, priority int, trust string) error {
	repos, err := m.st.ReadRepos()
	if err != nil {
		return err
	}
	for _, r := range repos {
		if r.Name == name {
			if r.Default {
				return fmt.Errorf("cannot replace default repo %q", name)
			}
			return fmt.Errorf("repo %q already exists", name)
		}
	}
	repos = append(repos, state.RepoEntry{Name: name, URL: url, Priority: priority, Trust: trust})
	return m.st.WriteRepos(repos)
}

func (m *Manager) Remove(name string) error {
	repos, err := m.st.ReadRepos()
	if err != nil {
		return err
	}
	var out []state.RepoEntry
	found := false
	for _, r := range repos {
		if r.Name == name {
			if r.Default {
				return fmt.Errorf("cannot remove default repo %q", name)
			}
			found = true
		} else {
			out = append(out, r)
		}
	}
	if !found {
		return fmt.Errorf("repo %q not found", name)
	}
	return m.st.WriteRepos(out)
}

func (m *Manager) Refresh() error {
	repos, err := m.st.ReadRepos()
	if err != nil {
		return err
	}
	if len(repos) == 0 {
		return fmt.Errorf("no repositories configured")
	}
	var all []*CatalogEntry
	for _, r := range repos {
		log.Infof("Refreshing repo %s from %s", r.Name, r.URL)
		entries, err := FetchCatalog(r.Name, r.URL, r.Priority, m.st.CacheDir)
		if err != nil {
			log.Warnf("Repo %s: %v", r.Name, err)
			continue
		}
		log.Infof("Repo %s: %d packages", r.Name, len(entries))
		all = append(all, entries...)
	}
	merged := MergeCatalogs(all)
	if err := m.st.WriteCatalog(toStateCatalog(merged)); err != nil {
		return fmt.Errorf("write merged catalog: %w", err)
	}
	m.CacheInstalledUninstallScripts(merged)
	log.Infof("Catalog refreshed: %d packages total", len(merged))
	return nil
}

func (m *Manager) CacheInstalledUninstallScripts(catalog []*CatalogEntry) {
	installed, err := m.st.ReadInstalled()
	if err != nil || len(installed) == 0 {
		return
	}
	installedSet := make(map[string]bool, len(installed))
	for _, e := range installed {
		installedSet[e.ID] = true
	}
	for _, e := range catalog {
		if !installedSet[e.ID] || e.UninstallURL == "" {
			continue
		}
		path := m.st.CachedUninstallScriptPath(e.ID)
		if _, err := os.Stat(path); err == nil {
			continue
		}
		data, err := fetchBytes(e.UninstallURL)
		if err != nil {
			log.Warnf("Could not cache uninstall script for %s: %v", e.ID, err)
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			log.Warnf("Could not create script cache dir for %s: %v", e.ID, err)
			continue
		}
		if err := os.WriteFile(path, data, 0755); err != nil {
			log.Warnf("Could not write uninstall script cache for %s: %v", e.ID, err)
		}
	}
}

func (m *Manager) ReadCatalog() ([]*CatalogEntry, error) {
	entries, err := m.st.ReadCatalog()
	if err != nil {
		return nil, err
	}
	return fromStateCatalog(entries), nil
}

// FetchScript downloads a script URL to a temp file and returns its path.
func (m *Manager) FetchScript(scriptURL string) (string, error) {
	name := fmt.Sprintf("script-%d.sh", time.Now().UnixNano())
	dst := filepath.Join(m.st.TmpDir, name)
	data, err := fetchBytes(scriptURL)
	if err != nil {
		return "", fmt.Errorf("fetch %s: %w", scriptURL, err)
	}
	if err := os.WriteFile(dst, data, 0755); err != nil {
		return "", fmt.Errorf("write script: %w", err)
	}
	return dst, nil
}

func toStateCatalog(entries []*CatalogEntry) []state.CatalogEntry {
	out := make([]state.CatalogEntry, 0, len(entries))
	for _, e := range entries {
		if e == nil {
			continue
		}
		out = append(out, state.CatalogEntry{
			Repo: e.Repo, Priority: e.Priority, ID: e.ID, Name: e.Name, Version: e.Version,
			Platforms: e.Platforms, Deps: e.Deps, InstallURL: e.InstallURL, UninstallURL: e.UninstallURL,
			Size: e.Size, Description: e.Description, Author: e.Author, Tags: e.Tags,
			IconURL: e.IconURL, RepoIconURL: e.RepoIconURL, Images: e.Images,
			Featured: e.Featured, FeaturedImage: e.FeaturedImage, Category: e.Category, Source: e.Source, SourceAsset: e.SourceAsset,
			SourceType: e.SourceType, SourceURL: e.SourceURL, Stars: e.Stars, Assets: e.Assets, Constraints: e.Constraints,
		})
	}
	return out
}

func fromStateCatalog(entries []state.CatalogEntry) []*CatalogEntry {
	out := make([]*CatalogEntry, 0, len(entries))
	for _, e := range entries {
		out = append(out, &CatalogEntry{
			Repo: e.Repo, Priority: e.Priority, ID: e.ID, Name: e.Name, Version: e.Version,
			Platforms: e.Platforms, Deps: e.Deps, InstallURL: e.InstallURL, UninstallURL: e.UninstallURL,
			Size: e.Size, Description: e.Description, Author: e.Author, Tags: e.Tags,
			IconURL: e.IconURL, RepoIconURL: e.RepoIconURL, Images: e.Images,
			Featured: e.Featured, FeaturedImage: e.FeaturedImage, Category: e.Category, Source: e.Source, SourceAsset: e.SourceAsset,
			SourceType: e.SourceType, SourceURL: e.SourceURL, Stars: e.Stars, Assets: e.Assets, Constraints: e.Constraints,
		})
	}
	return out
}
