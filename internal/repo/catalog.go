package repo

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"ZPM/internal/log"
)

// CatalogEntry is the internal merged-catalog representation.
// Pipe-separated on disk (12 fields): repo|priority|id|name|version|platforms|deps|install_url|uninstall_url|manifest_url|sha256|size
type CatalogEntry struct {
	Repo         string
	Priority     int
	ID           string
	Name         string
	Version      string
	Platforms    []string
	Deps         []string
	InstallURL   string
	UninstallURL string
	ManifestURL  string
	SHA256       string
	Size         string
}

func (e *CatalogEntry) HasPlatform(p string) bool {
	for _, pl := range e.Platforms {
		if pl == p {
			return true
		}
	}
	return false
}

func (e *CatalogEntry) serialize() string {
	return strings.Join([]string{
		e.Repo,
		fmt.Sprintf("%d", e.Priority),
		e.ID, e.Name, e.Version,
		strings.Join(e.Platforms, ","),
		strings.Join(e.Deps, ","),
		e.InstallURL, e.UninstallURL, e.ManifestURL,
		e.SHA256, e.Size,
	}, "|")
}

func parseCatalogLine(line string) (*CatalogEntry, error) {
	parts := strings.SplitN(line, "|", 12)
	if len(parts) < 12 {
		return nil, fmt.Errorf("invalid catalog line (got %d fields): %q", len(parts), line)
	}
	var priority int
	fmt.Sscanf(parts[1], "%d", &priority)
	e := &CatalogEntry{
		Repo: parts[0], Priority: priority,
		ID: parts[2], Name: parts[3], Version: parts[4],
		InstallURL: parts[7], UninstallURL: parts[8], ManifestURL: parts[9],
		SHA256: parts[10], Size: parts[11],
	}
	if parts[5] != "" {
		e.Platforms = strings.Split(parts[5], ",")
	}
	if parts[6] != "" {
		e.Deps = strings.Split(parts[6], ",")
	}
	return e, nil
}

// indexJSON mirrors the repos/default/index.json schema.
type indexJSON struct {
	SchemaVersion string `json:"schema_version"`
	Repo          struct {
		ID   string `json:"id"`
		Name string `json:"name"`
		URL  string `json:"url"`
	} `json:"repo"`
	Packages []struct {
		ID           string   `json:"id"`
		Name         string   `json:"name"`
		Version      string   `json:"version"`
		Platforms    []string `json:"platforms"`
		Dependencies []string `json:"dependencies"`
		InstallURL   string   `json:"install_url"`
		UninstallURL string   `json:"uninstall_url"`
		ManifestURL  string   `json:"manifest_url"`
		SHA256       string   `json:"sha256"`
		Size         string   `json:"size"`
	} `json:"packages"`
}

// FetchCatalog downloads index.json from a repo URL and returns its entries.
func FetchCatalog(repoName, repoURL string, priority int, cacheDir string) ([]*CatalogEntry, error) {
	indexURL := joinURL(repoURL, "index.json")
	log.Infof("Fetching %s", indexURL)
	data, err := fetchBytes(indexURL)
	if err != nil {
		return nil, fmt.Errorf("fetch %s: %w", indexURL, err)
	}

	// Cache raw index for debugging.
	os.WriteFile(filepath.Join(cacheDir, "index-"+repoName+".json"), data, 0644)

	var idx indexJSON
	if err := json.Unmarshal(data, &idx); err != nil {
		return nil, fmt.Errorf("parse index.json from %s: %w", repoName, err)
	}

	var entries []*CatalogEntry
	for _, p := range idx.Packages {
		entries = append(entries, &CatalogEntry{
			Repo:         repoName,
			Priority:     priority,
			ID:           p.ID,
			Name:         p.Name,
			Version:      p.Version,
			Platforms:    p.Platforms,
			Deps:         p.Dependencies,
			InstallURL:   resolveURL(repoURL, p.InstallURL),
			UninstallURL: resolveURL(repoURL, p.UninstallURL),
			ManifestURL:  resolveURL(repoURL, p.ManifestURL),
			SHA256:       p.SHA256,
			Size:         p.Size,
		})
	}
	return entries, nil
}

// MergeCatalogs deduplicates by package ID, preferring lower priority number (higher priority).
func MergeCatalogs(all []*CatalogEntry) []*CatalogEntry {
	sort.SliceStable(all, func(i, j int) bool {
		if all[i].Priority != all[j].Priority {
			return all[i].Priority < all[j].Priority
		}
		return all[i].Name < all[j].Name
	})
	seen := make(map[string]bool, len(all))
	var out []*CatalogEntry
	for _, e := range all {
		if !seen[e.ID] {
			seen[e.ID] = true
			out = append(out, e)
		}
	}
	return out
}

// WriteMergedCatalog persists the merged catalog to disk.
func WriteMergedCatalog(path string, entries []*CatalogEntry) error {
	var sb strings.Builder
	for _, e := range entries {
		sb.WriteString(e.serialize())
		sb.WriteByte('\n')
	}
	return os.WriteFile(path, []byte(sb.String()), 0644)
}

// ReadMergedCatalog loads a previously written merged catalog.
func ReadMergedCatalog(path string) ([]*CatalogEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var entries []*CatalogEntry
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		e, err := parseCatalogLine(line)
		if err != nil {
			continue // skip malformed lines
		}
		entries = append(entries, e)
	}
	return entries, nil
}

// FilterByPlatform returns only entries that match the given platform string.
// An empty platform string returns all entries.
func FilterByPlatform(entries []*CatalogEntry, platform string) []*CatalogEntry {
	if platform == "" {
		return entries
	}
	var out []*CatalogEntry
	for _, e := range entries {
		if e.HasPlatform(platform) {
			out = append(out, e)
		}
	}
	return out
}

// FetchBytes downloads or reads (file://) a URL and returns raw bytes.
func FetchBytes(url string) ([]byte, error) {
	return fetchBytes(url)
}

func fetchBytes(url string) ([]byte, error) {
	if strings.HasPrefix(url, "file://") {
		return os.ReadFile(strings.TrimPrefix(url, "file://"))
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("HTTP %d from %s", resp.StatusCode, url)
	}
	return io.ReadAll(resp.Body)
}

func joinURL(base, path string) string {
	return strings.TrimRight(base, "/") + "/" + strings.TrimLeft(path, "/")
}

func resolveURL(base, rel string) string {
	if rel == "" {
		return ""
	}
	if strings.HasPrefix(rel, "http://") || strings.HasPrefix(rel, "https://") || strings.HasPrefix(rel, "file://") {
		return rel
	}
	return joinURL(base, rel)
}
