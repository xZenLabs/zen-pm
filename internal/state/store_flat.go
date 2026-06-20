package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type CatalogEntry struct {
	Repo          string
	Priority      int
	ID            string
	Name          string
	Version       string
	Platforms     []string
	Deps          []string
	InstallURL    string
	UninstallURL  string
	Size          string
	Description   string
	Author        string
	Tags          []string
	IconURL       string
	RepoIconURL   string
	Images        []string
	Featured      bool
	FeaturedImage string
	Category      string
	Source        string
	SourceAsset   string
}

type flatFileStore struct {
	s *State
}

func (f *flatFileStore) ReadRepos() ([]RepoEntry, error) {
	return readReposFile(f.s.ReposDB)
}

func (f *flatFileStore) WriteRepos(repos []RepoEntry) error {
	return writeReposFile(f.s.ReposDB, repos)
}

func (f *flatFileStore) seedInstalled() error {
	if _, err := os.Stat(f.s.InstalledDB); err == nil {
		return nil
	}
	return os.WriteFile(f.s.InstalledDB, []byte(""), 0644)
}

func (f *flatFileStore) ReadInstalled() ([]InstalledEntry, error) {
	return readInstalledFile(f.s.InstalledDB)
}

func (f *flatFileStore) AppendInstalled(e InstalledEntry) error {
	if e.InstalledAt == "" {
		e.InstalledAt = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	}
	line := fmt.Sprintf("%s|%s|%s|%s|%s\n", e.ID, e.Version, e.Repo, e.InstalledAt, e.Name)
	file, err := os.OpenFile(f.s.InstalledDB, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.WriteString(line)
	return err
}

func (f *flatFileStore) RemoveInstalled(id string) error {
	entries, err := f.ReadInstalled()
	if err != nil {
		return err
	}
	var out []InstalledEntry
	for _, e := range entries {
		if e.ID != id {
			out = append(out, e)
		}
	}
	return writeInstalledFile(f.s.InstalledDB, out)
}

func (f *flatFileStore) IsInstalled(id string) (bool, string) {
	entries, _ := f.ReadInstalled()
	for _, e := range entries {
		if e.ID == id {
			return true, e.Version
		}
	}
	return false, ""
}

func (f *flatFileStore) ReadCatalog() ([]CatalogEntry, error) {
	return readCatalogFile(filepath.Join(f.s.CacheDir, "catalog.merged"))
}

func (f *flatFileStore) WriteCatalog(entries []CatalogEntry) error {
	return writeCatalogFile(filepath.Join(f.s.CacheDir, "catalog.merged"), entries)
}

func readReposFile(path string) ([]RepoEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var repos []RepoEntry
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "|", 5)
		if len(parts) < 4 {
			continue
		}
		var priority int
		fmt.Sscanf(parts[2], "%d", &priority)
		repos = append(repos, RepoEntry{
			Name: parts[0], URL: parts[1], Priority: priority, Trust: parts[3],
			Default: len(parts) >= 5 && parts[4] == "default",
		})
	}
	return repos, nil
}

func writeReposFile(path string, repos []RepoEntry) error {
	var sb strings.Builder
	for _, r := range repos {
		defFlag := ""
		if r.Default {
			defFlag = "default"
		}
		fmt.Fprintf(&sb, "%s|%s|%d|%s|%s\n", r.Name, r.URL, r.Priority, r.Trust, defFlag)
	}
	return os.WriteFile(path, []byte(sb.String()), 0644)
}

func readInstalledFile(path string) ([]InstalledEntry, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var entries []InstalledEntry
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 5)
		if len(parts) < 4 {
			continue
		}
		entry := InstalledEntry{
			ID: parts[0], Version: parts[1], Repo: parts[2], InstalledAt: parts[3],
		}
		if len(parts) >= 5 {
			entry.Name = parts[4]
		}
		if entry.Name == "" {
			entry.Name = entry.ID
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

func writeInstalledFile(path string, entries []InstalledEntry) error {
	var sb strings.Builder
	for _, e := range entries {
		fmt.Fprintf(&sb, "%s|%s|%s|%s|%s\n", e.ID, e.Version, e.Repo, e.InstalledAt, e.Name)
	}
	return os.WriteFile(path, []byte(sb.String()), 0644)
}

func readCatalogFile(path string) ([]CatalogEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var entries []CatalogEntry
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		e, err := parseCatalogLine(line)
		if err != nil {
			continue
		}
		entries = append(entries, e)
	}
	return entries, nil
}

func writeCatalogFile(path string, entries []CatalogEntry) error {
	var sb strings.Builder
	for _, e := range entries {
		sb.WriteString(serializeCatalogEntry(e))
		sb.WriteByte('\n')
	}
	return os.WriteFile(path, []byte(sb.String()), 0644)
}

func serializeCatalogEntry(e CatalogEntry) string {
	return strings.Join([]string{
		e.Repo,
		fmt.Sprintf("%d", e.Priority),
		e.ID, e.Name, e.Version,
		strings.Join(e.Platforms, ","),
		strings.Join(e.Deps, ","),
		e.InstallURL, e.UninstallURL,
		e.Size,
		e.Description, e.Author,
		strings.Join(e.Tags, ","),
		e.IconURL,
		e.RepoIconURL,
		strings.Join(e.Images, ","),
		boolCatalogField(e.Featured),
		e.FeaturedImage,
		e.Category,
		e.Source,
		e.SourceAsset,
	}, "|")
}

func parseCatalogLine(line string) (CatalogEntry, error) {
	parts := strings.Split(line, "|")
	return parseModernCatalogLine(parts)
}

func parseModernCatalogLine(parts []string) (CatalogEntry, error) {
	if len(parts) < 10 {
		return CatalogEntry{}, fmt.Errorf("invalid catalog line (got %d fields)", len(parts))
	}
	var priority int
	fmt.Sscanf(parts[1], "%d", &priority)
	e := CatalogEntry{
		Repo: parts[0], Priority: priority,
		ID: parts[2], Name: parts[3], Version: parts[4],
		InstallURL: parts[7], UninstallURL: parts[8],
		Size: parts[9],
	}
	if parts[5] != "" {
		e.Platforms = strings.Split(parts[5], ",")
	}
	if parts[6] != "" {
		e.Deps = strings.Split(parts[6], ",")
	}
	if len(parts) >= 11 {
		e.Description = parts[10]
	}
	if len(parts) >= 12 {
		e.Author = parts[11]
	}
	if len(parts) >= 13 && parts[12] != "" {
		e.Tags = strings.Split(parts[12], ",")
	}
	if len(parts) >= 14 {
		e.IconURL = parts[13]
	}
	if len(parts) >= 15 {
		e.RepoIconURL = parts[14]
	}
	if len(parts) >= 16 && parts[15] != "" {
		e.Images = strings.Split(parts[15], ",")
	}
	if len(parts) >= 17 {
		e.Featured = parts[16] == "featured" || parts[16] == "true" || parts[16] == "1"
	}
	if len(parts) >= 18 {
		e.FeaturedImage = parts[17]
	}
	if len(parts) >= 19 {
		e.Category = parts[18]
	}
	if len(parts) >= 20 {
		e.Source = parts[19]
	}
	if len(parts) >= 21 {
		e.SourceAsset = parts[20]
	}
	return e, nil
}

func parseLegacyCatalogLine(parts []string) (CatalogEntry, error) {
	var priority int
	fmt.Sscanf(parts[1], "%d", &priority)
	e := CatalogEntry{
		Repo: parts[0], Priority: priority,
		ID: parts[2], Name: parts[3], Version: parts[4],
		InstallURL: parts[7], UninstallURL: parts[8],
		Size: parts[11],
	}
	if parts[5] != "" {
		e.Platforms = strings.Split(parts[5], ",")
	}
	if parts[6] != "" {
		e.Deps = strings.Split(parts[6], ",")
	}
	if len(parts) >= 13 {
		e.Description = parts[12]
	}
	if len(parts) >= 14 {
		e.Author = parts[13]
	}
	if len(parts) >= 15 && parts[14] != "" {
		e.Tags = strings.Split(parts[14], ",")
	}
	if len(parts) >= 16 {
		e.IconURL = parts[15]
	}
	if len(parts) >= 17 {
		e.RepoIconURL = parts[16]
	}
	if len(parts) >= 18 && parts[17] != "" {
		e.Images = strings.Split(parts[17], ",")
	}
	if len(parts) >= 19 {
		e.Featured = parts[18] == "featured" || parts[18] == "true" || parts[18] == "1"
	}
	if len(parts) >= 20 {
		e.FeaturedImage = parts[19]
	}
	return e, nil
}

func boolCatalogField(value bool) string {
	if value {
		return "featured"
	}
	return ""
}
