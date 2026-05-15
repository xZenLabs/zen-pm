package pkg

import (
	"fmt"

	"ZPM/internal/repo"
)

// ResolvePlan returns the install order for id and all its transitive dependencies
// (dependency-first). Returns an error on cycles or missing packages.
func ResolvePlan(id string, catalog []*repo.CatalogEntry) ([]string, error) {
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

	var dfs func(string) error
	dfs = func(cur string) error {
		if visited[cur] {
			return nil
		}
		if inStack[cur] {
			return fmt.Errorf("dependency cycle at %q", cur)
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
			if err := dfs(dep); err != nil {
				return err
			}
		}
		inStack[cur] = false
		visited[cur] = true
		plan = append(plan, cur)
		return nil
	}

	if err := dfs(id); err != nil {
		return nil, err
	}
	return plan, nil
}
