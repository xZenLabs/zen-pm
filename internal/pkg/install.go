package pkg

import (
	"fmt"

	"ZPM/internal/log"
	"ZPM/internal/platform"
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
	catalog, err := m.repos.ReadCatalog()
	if err != nil {
		return fmt.Errorf("read catalog: %w", err)
	}
	plan, err := ResolvePlan(id, catalog)
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

	installed, _ := m.st.ReadInstalled()
	installedSet := make(map[string]bool, len(installed))
	for _, e := range installed {
		installedSet[e.ID] = true
	}

	for _, pkgID := range plan {
		if installedSet[pkgID] {
			log.Infof("Already installed: %s", pkgID)
			continue
		}
		entry := byID[pkgID]
		log.Infof("Installing %s v%s from repo %s", entry.ID, entry.Version, entry.Repo)

		j.Record("fetch-script", "ok", "pkg="+pkgID)
		scriptPath, err := m.repos.FetchScript(entry.InstallURL)
		if err != nil {
			j.Abort("fetch failed: " + err.Error())
			return fmt.Errorf("fetch install script for %s: %w", pkgID, err)
		}

		j.Record("execute", "ok", fmt.Sprintf("pkg=%s ver=%s", pkgID, entry.Version))
		if err := platform.ExecuteScript(scriptPath); err != nil {
			j.Abort("execute failed: " + err.Error())
			return fmt.Errorf("install script failed for %s: %w", pkgID, err)
		}

		if err := m.st.AppendInstalled(state.InstalledEntry{
			ID: pkgID, Version: entry.Version, Repo: entry.Repo,
		}); err != nil {
			j.Abort("record failed: " + err.Error())
			return err
		}
		log.Infof("Installed: %s v%s", pkgID, entry.Version)
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

	if entry != nil && entry.UninstallURL != "" {
		scriptPath, err := m.repos.FetchScript(entry.UninstallURL)
		if err != nil {
			j.Abort("fetch failed: " + err.Error())
			return fmt.Errorf("fetch uninstall script: %w", err)
		}
		if err := platform.ExecuteScript(scriptPath); err != nil {
			j.Abort("execute failed: " + err.Error())
			return fmt.Errorf("uninstall script failed: %w", err)
		}
	}

	if err := m.st.RemoveInstalled(id); err != nil {
		j.Abort("remove from db failed: " + err.Error())
		return err
	}

	log.Infof("Uninstalled: %s", id)
	j.Commit()
	return nil
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
		if versionGT(latest.Version, e.Version) {
			log.Infof("Updating %s: %s -> %s", e.ID, e.Version, latest.Version)
			if err := m.Install(e.ID); err != nil {
				return err
			}
		} else {
			log.Infof("Package %s is up to date (%s)", e.ID, e.Version)
		}
	}
	return nil
}

// versionGT returns true if a > b using simple numeric semver comparison.
func versionGT(a, b string) bool {
	parse := func(v string) [3]int {
		var maj, min, pat int
		fmt.Sscanf(v, "%d.%d.%d", &maj, &min, &pat)
		return [3]int{maj, min, pat}
	}
	av, bv := parse(a), parse(b)
	for i := range av {
		if av[i] > bv[i] {
			return true
		}
		if av[i] < bv[i] {
			return false
		}
	}
	return false
}
