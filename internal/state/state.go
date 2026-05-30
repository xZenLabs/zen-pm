package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	defaultKindleHome = "/mnt/us/ZenPM"
	defaultKoboHome   = "/mnt/onboard/.adds/ZenPM"
)

// State holds all resolved paths for ZenPM's working directories.
type State struct {
	Home          string
	ReposDB       string
	InstalledDB   string
	CacheDir      string
	TmpDir        string
	LockDir       string
	JournalDir    string
	LogFile       string
	SeededRepoURL string // non-empty only when repos.db was just created
}

// Init resolves ZENPM_HOME (or a platform default), creates all directories,
// and seeds empty databases if missing.
func Init(platform string) (*State, error) {
	home := os.Getenv("ZENPM_HOME")
	if home == "" {
		switch platform {
		case "kindle":
			home = defaultKindleHome
		case "kobo":
			home = defaultKoboHome
		default:
			if h, err := os.UserHomeDir(); err == nil {
				home = filepath.Join(h, ".zenpm")
			} else {
				home = "/tmp/.zenpm"
			}
		}
	}

	s := &State{
		Home:        home,
		ReposDB:     filepath.Join(home, "state", "repos.db"),
		InstalledDB: filepath.Join(home, "state", "installed.db"),
		CacheDir:    filepath.Join(home, "cache"),
		TmpDir:      filepath.Join(home, "tmp"),
		LockDir:     filepath.Join(home, "locks"),
		JournalDir:  filepath.Join(home, "journal"),
		LogFile:     filepath.Join(home, "ZenPM.log"),
	}

	for _, dir := range []string{
		filepath.Join(home, "state"),
		s.CacheDir, s.TmpDir, s.LockDir, s.JournalDir,
	} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return nil, fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}

	if err := seedReposDB(s); err != nil {
		return nil, err
	}
	if err := seedInstalledDB(s); err != nil {
		return nil, err
	}
	return s, nil
}

func seedReposDB(s *State) error {
	if _, err := os.Stat(s.ReposDB); err == nil {
		return nil // already exists
	}
	url := os.Getenv("ZENPM_DEFAULT_REPO_URL")
	if url == "" {
		// Derive repos path relative to binary: binary at <root>/backend/zenpm,
		// repos at <root>/repos/default.
		if exe, err := os.Executable(); err == nil {
			candidate := filepath.Join(filepath.Dir(filepath.Dir(exe)), "repos", "default")
			if _, err := os.Stat(candidate); err == nil {
				url = "file://" + candidate
			}
		}
	}
	if url == "" {
		url = "file://repos/default"
	}
	// Write before logging since log may not be initialized yet; caller logs after Init.
	s.SeededRepoURL = url
	return os.WriteFile(s.ReposDB, []byte("default|"+url+"|100|warn-unsigned\n"), 0644)
}

func seedInstalledDB(s *State) error {
	if _, err := os.Stat(s.InstalledDB); err == nil {
		return nil
	}
	return os.WriteFile(s.InstalledDB, []byte(""), 0644)
}

// LockAcquire grabs a named lock via mkdir (atomic on Linux/macOS).
func (s *State) LockAcquire(name string) error {
	if err := os.Mkdir(filepath.Join(s.LockDir, name+".lock"), 0755); err != nil {
		return fmt.Errorf("operation lock busy: %s", name)
	}
	return nil
}

// LockRelease removes the named lock directory.
func (s *State) LockRelease(name string) {
	os.Remove(filepath.Join(s.LockDir, name+".lock"))
}

// --- Repo entries ---

// RepoEntry represents one line in repos.db.
type RepoEntry struct {
	Name     string
	URL      string
	Priority int
	Trust    string
}

func (s *State) ReadRepos() ([]RepoEntry, error) {
	data, err := os.ReadFile(s.ReposDB)
	if err != nil {
		return nil, err
	}
	var repos []RepoEntry
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "|", 4)
		if len(parts) < 4 {
			continue
		}
		var priority int
		fmt.Sscanf(parts[2], "%d", &priority)
		repos = append(repos, RepoEntry{
			Name: parts[0], URL: parts[1], Priority: priority, Trust: parts[3],
		})
	}
	return repos, nil
}

func (s *State) WriteRepos(repos []RepoEntry) error {
	var sb strings.Builder
	for _, r := range repos {
		fmt.Fprintf(&sb, "%s|%s|%d|%s\n", r.Name, r.URL, r.Priority, r.Trust)
	}
	return os.WriteFile(s.ReposDB, []byte(sb.String()), 0644)
}

// --- Installed entries ---

// InstalledEntry represents one line in installed.db.
type InstalledEntry struct {
	ID          string
	Version     string
	Repo        string
	InstalledAt string
}

func (s *State) ReadInstalled() ([]InstalledEntry, error) {
	data, err := os.ReadFile(s.InstalledDB)
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
		parts := strings.SplitN(line, "|", 4)
		if len(parts) < 4 {
			continue
		}
		entries = append(entries, InstalledEntry{
			ID: parts[0], Version: parts[1], Repo: parts[2], InstalledAt: parts[3],
		})
	}
	return entries, nil
}

func (s *State) AppendInstalled(e InstalledEntry) error {
	if e.InstalledAt == "" {
		e.InstalledAt = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	}
	line := fmt.Sprintf("%s|%s|%s|%s\n", e.ID, e.Version, e.Repo, e.InstalledAt)
	f, err := os.OpenFile(s.InstalledDB, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(line)
	return err
}

func (s *State) RemoveInstalled(id string) error {
	entries, err := s.ReadInstalled()
	if err != nil {
		return err
	}
	var out []InstalledEntry
	for _, e := range entries {
		if e.ID != id {
			out = append(out, e)
		}
	}
	var sb strings.Builder
	for _, e := range out {
		fmt.Fprintf(&sb, "%s|%s|%s|%s\n", e.ID, e.Version, e.Repo, e.InstalledAt)
	}
	return os.WriteFile(s.InstalledDB, []byte(sb.String()), 0644)
}

func (s *State) IsInstalled(id string) (bool, string) {
	entries, _ := s.ReadInstalled()
	for _, e := range entries {
		if e.ID == id {
			return true, e.Version
		}
	}
	return false, ""
}
