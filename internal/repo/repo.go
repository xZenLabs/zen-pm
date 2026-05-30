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
	if err := WriteMergedCatalog(m.catalogPath(), merged); err != nil {
		return fmt.Errorf("write merged catalog: %w", err)
	}
	log.Infof("Catalog refreshed: %d packages total", len(merged))
	return nil
}

func (m *Manager) catalogPath() string {
	return filepath.Join(m.st.CacheDir, "catalog.merged")
}

func (m *Manager) ReadCatalog() ([]*CatalogEntry, error) {
	return ReadMergedCatalog(m.catalogPath())
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
