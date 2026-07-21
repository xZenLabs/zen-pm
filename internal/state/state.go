package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/xZenLabs/zen-pm/internal/cabundle"
)

const (
	defaultKindleHome          = "/mnt/us/ZenPM"
	defaultKoboHome            = "/mnt/onboard/.adds/ZenPM"
	kindlePersistDir           = "/mnt/us/.ZenPM"
	koboPersistDir             = "/mnt/onboard/.adds/.ZenPM"
	DefaultZenLabsRepoName     = "ZenLabs"
	DefaultZenLabsRepoURL      = "https://repo.zen-labs.org"
	DefaultKindleForgeRepoName = "KindleForge"
	DefaultKindleForgeRepoURL  = "https://kf.penguins184.xyz"
)

// State holds all resolved paths for ZenPM's working directories.
type State struct {
	Home          string
	SQLiteDB      string
	CacheDir      string
	ScriptDir     string
	TmpDir        string
	LockDir       string
	JournalDir    string
	CABundle      string
	LogFile       string
	SeededRepoURL string // non-empty only when the database was just created
	store         Store
}

type Store interface {
	ReadRepos() ([]RepoEntry, error)
	WriteRepos([]RepoEntry) error
	ReadInstalled() ([]InstalledEntry, error)
	AppendInstalled(InstalledEntry) error
	RemoveInstalled(string) error
	IsInstalled(string) (bool, string)
	ReadInstalledPatchFiles() ([]PatchFileEntry, error)
	AppendInstalledPatchFile(PatchFileEntry) error
	RemoveInstalledPatchFile(packageID, asset string) error
	ReadValue(string) (string, error)
	WriteValue(string, string) error
	ReadCatalog() ([]CatalogEntry, error)
	WriteCatalog([]CatalogEntry) error
}

// Init resolves ZENPM_HOME (or a platform default), creates all directories,
// and seeds empty databases if missing.
func Init(platform string) (*State, error) {
	StartupTrace("State initialization: resolving directories.")
	home := os.Getenv("ZENPM_HOME")
	explicitHome := home != ""
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

	// Persistent state lives in a dot-directory so it survives app updates.
	persistDir := resolvePersistDir(platform, home, explicitHome)

	s := &State{
		Home:       home,
		SQLiteDB:   filepath.Join(persistDir, "zenpm.sqlite3"),
		ScriptDir:  filepath.Join(persistDir, "scripts"),
		CacheDir:   filepath.Join(home, "cache"),
		TmpDir:     filepath.Join(home, "tmp"),
		LockDir:    filepath.Join(home, "locks"),
		JournalDir: filepath.Join(home, "journal"),
		CABundle:   filepath.Join(home, "cacert.pem"),
		LogFile:    filepath.Join(home, "ZenPM.log"),
	}

	for _, dir := range []string{
		s.CacheDir, s.ScriptDir, s.TmpDir, s.LockDir, s.JournalDir,
		persistDir,
	} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return nil, fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}
	if err := cabundle.WriteFile(s.CABundle); err != nil {
		return nil, fmt.Errorf("write CA bundle: %w", err)
	}
	StartupTrace("State initialization: directories ready.")

	store, err := newSQLiteStore(s)
	if err != nil {
		return nil, err
	}
	s.store = store
	StartupTrace("State initialization: SQLite ready.")

	if err := seedReposDB(s); err != nil {
		return nil, err
	}
	if err := reconcileDefaultRepos(s); err != nil {
		return nil, err
	}
	StartupTrace("State initialization: repositories ready.")

	// Clean up stale temp dirs and locks from interrupted operations.
	cleanupStaleDirs(platform, s.LockDir)

	return s, nil
}

func cleanupStaleDirs(platform, lockDir string) {
	// Remove stale lock directories from previous crashed runs.
	if entries, err := os.ReadDir(lockDir); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				_ = os.RemoveAll(filepath.Join(lockDir, e.Name()))
			}
		}
	}
	switch platform {
	case "kindle":
		_ = os.RemoveAll("/mnt/us/ZPM-Update-Temp")
	default:
	}
}

func resolvePersistDir(platform, home string, explicitHome bool) string {
	if explicitHome {
		return filepath.Join(home, "state")
	}
	switch platform {
	case "kindle":
		return kindlePersistDir
	case "kobo":
		return koboPersistDir
	default:
		return filepath.Join(home, "state") // host dev: keep in home/state
	}
}

func seedReposDB(s *State) error {
	repos, err := s.ReadRepos()
	if err != nil {
		return err
	}
	if len(repos) > 0 {
		return nil
	}

	// Default repos seeded on first run.
	defaults := []RepoEntry{
		{Name: DefaultZenLabsRepoName, URL: DefaultZenLabsRepoURL, Priority: 10, Trust: "trusted", Default: true},
		{Name: DefaultKindleForgeRepoName, URL: DefaultKindleForgeRepoURL, Priority: 10, Trust: "trusted", Default: true},
	}

	// Allow override via env var for custom setups.
	if url := os.Getenv("ZENPM_DEFAULT_REPO_URL"); url != "" {
		defaults = append(defaults, RepoEntry{
			Name: "default", URL: url, Priority: 10, Trust: "warn-unsigned", Default: true,
		})
	}

	s.SeededRepoURL = defaults[0].URL
	return s.WriteRepos(defaults)
}

func reconcileDefaultRepos(s *State) error {
	repos, err := s.ReadRepos()
	if err != nil {
		return err
	}
	changed := false
	hasZenLabs := false
	hasKindleForge := false

	for i := range repos {
		if repos[i].Name == DefaultZenLabsRepoName {
			hasZenLabs = true
			if repos[i].URL != DefaultZenLabsRepoURL || repos[i].Priority != 10 || repos[i].Trust != "trusted" || !repos[i].Default {
				repos[i].URL = DefaultZenLabsRepoURL
				repos[i].Priority = 10
				repos[i].Trust = "trusted"
				repos[i].Default = true
				changed = true
			}
		}
		if repos[i].Name == DefaultKindleForgeRepoName {
			hasKindleForge = true
			if repos[i].URL != DefaultKindleForgeRepoURL || repos[i].Priority != 10 || repos[i].Trust != "trusted" || !repos[i].Default {
				repos[i].URL = DefaultKindleForgeRepoURL
				repos[i].Priority = 10
				repos[i].Trust = "trusted"
				repos[i].Default = true
				changed = true
			}
		}
	}

	if !hasZenLabs {
		repos = append([]RepoEntry{{Name: DefaultZenLabsRepoName, URL: DefaultZenLabsRepoURL, Priority: 10, Trust: "trusted", Default: true}}, repos...)
		changed = true
	}
	if !hasKindleForge {
		repos = append(repos, RepoEntry{Name: DefaultKindleForgeRepoName, URL: DefaultKindleForgeRepoURL, Priority: 10, Trust: "trusted", Default: true})
		changed = true
	}
	if !changed {
		return nil
	}
	if err := s.WriteRepos(repos); err != nil {
		return err
	}
	_ = s.WriteCatalog(nil)
	s.SeededRepoURL = DefaultZenLabsRepoURL
	return nil
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
// Format: name|url|priority|trust|default
// The "default" field is "default" for built-in repos, "" for user-added.
type RepoEntry struct {
	Name     string
	URL      string
	Priority int
	Trust    string
	Default  bool
}

func (s *State) ReadRepos() ([]RepoEntry, error) {
	return s.store.ReadRepos()
}

func (s *State) WriteRepos(repos []RepoEntry) error {
	return s.store.WriteRepos(repos)
}

func (s *State) CachedUninstallScriptPath(id string) string {
	return filepath.Join(s.ScriptDir, safePackageID(id)+"-uninstall.sh")
}

func safePackageID(id string) string {
	var b strings.Builder
	for _, r := range id {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	if b.Len() == 0 {
		return "package"
	}
	return b.String()
}

// --- Installed entries ---

// InstalledEntry represents one line in installed.db.
// Format: id|version|repo|installed_at|name
// The name field was added later; old entries have only 4 fields.
type InstalledEntry struct {
	ID          string
	Name        string // display name (falls back to ID if empty)
	Version     string
	Repo        string
	Asset       string // selected release asset, empty when ZenPM did not install it
	AssetArch   string // selected release asset architecture
	InstalledAt string
}

// PatchFileEntry represents one installed patch file within a patch package.
type PatchFileEntry struct {
	PackageID   string
	Asset       string // patch file name, e.g. "2-menu-size.lua"
	Name        string // package display name
	Version     string
	Repo        string
	InstalledAt string
}

func (s *State) ReadInstalled() ([]InstalledEntry, error) {
	return s.store.ReadInstalled()
}

func (s *State) AppendInstalled(e InstalledEntry) error {
	return s.store.AppendInstalled(e)
}

func (s *State) RemoveInstalled(id string) error {
	return s.store.RemoveInstalled(id)
}

func (s *State) IsInstalled(id string) (bool, string) {
	return s.store.IsInstalled(id)
}

func (s *State) ReadInstalledPatchFiles() ([]PatchFileEntry, error) {
	return s.store.ReadInstalledPatchFiles()
}

func (s *State) AppendInstalledPatchFile(e PatchFileEntry) error {
	return s.store.AppendInstalledPatchFile(e)
}

func (s *State) RemoveInstalledPatchFile(packageID, asset string) error {
	return s.store.RemoveInstalledPatchFile(packageID, asset)
}

// ReadValue returns a small piece of persistent state by key. Missing keys
// return an empty value.
func (s *State) ReadValue(key string) (string, error) {
	return s.store.ReadValue(key)
}

// WriteValue persists a small piece of state by key.
func (s *State) WriteValue(key, value string) error {
	return s.store.WriteValue(key, value)
}

func (s *State) ReadCatalog() ([]CatalogEntry, error) {
	return s.store.ReadCatalog()
}

func (s *State) WriteCatalog(entries []CatalogEntry) error {
	return s.store.WriteCatalog(entries)
}
