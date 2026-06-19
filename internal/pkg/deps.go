package pkg

import (
	"fmt"

	"ZPM/internal/repo"
)

var externalDependencies = map[string]bool{
	"kual": true,
}

// ResolvePlan returns the install order for id and all its transitive dependencies
// (dependency-first). Returns an error on cycles or missing packages.
func ResolvePlan(id string, catalog []*repo.CatalogEntry) ([]string, error) {
	return ResolvePlanWithInstalled(id, catalog, nil)
}

// ResolvePlanWithInstalled is like ResolvePlan, but known external dependencies
// can be satisfied by already-installed device apps.
func ResolvePlanWithInstalled(id string, catalog []*repo.CatalogEntry, installed map[string]bool) ([]string, error) {
	byID := make(map[string]*repo.CatalogEntry, len(catalog))
	for _, e := range catalog {
		byID[e.ID] = e
	}
	if _, ok := byID[id]; !ok {
		return nil, fmt.Errorf("package %q not found in catalog", id)
	}

	visited := make(map[string]bool)
	inStack := make(map[string]bool)
	var plan []string

	var dfs func(string, bool) error
	dfs = func(cur string, isRoot bool) error {
		if visited[cur] {
			return nil
		}
		if inStack[cur] {
			return fmt.Errorf("dependency cycle at %q", cur)
		}
		if !isRoot && externalDependencies[cur] {
			if installed[cur] {
				return nil
			}
			return fmt.Errorf("dependency %q is not installed", cur)
		}
		entry, ok := byID[cur]
		if !ok {
			return fmt.Errorf("unknown dependency %q", cur)
		}
		inStack[cur] = true
		for _, dep := range entry.Deps {
			if dep == "" {
				continue
			}
			if err := dfs(dep, false); err != nil {
				return err
			}
		}
		inStack[cur] = false
		visited[cur] = true
		plan = append(plan, cur)
		return nil
	}

	if err := dfs(id, true); err != nil {
		return nil, err
	}
	return plan, nil
}
