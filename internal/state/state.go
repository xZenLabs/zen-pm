package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
	ReposDB       string
	InstalledDB   string
	SQLiteDB      string
	StateBackend  string
	CacheDir      string
	ScriptDir     string
	TmpDir        string
	LockDir       string
	JournalDir    string
	LogFile       string
	SeededRepoURL string // non-empty only when repos.db was just created
	store         Store
}

type Store interface {
	ReadRepos() ([]RepoEntry, error)
	WriteRepos([]RepoEntry) error
	ReadInstalled() ([]InstalledEntry, error)
	AppendInstalled(InstalledEntry) error
	RemoveInstalled(string) error
	IsInstalled(string) (bool, string)
	ReadCatalog() ([]CatalogEntry, error)
	WriteCatalog([]CatalogEntry) error
}

// Init resolves ZENPM_HOME (or a platform default), creates all directories,
// and seeds empty databases if missing.
func Init(platform string) (*State, error) {
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
		Home:        home,
		ReposDB:     filepath.Join(persistDir, "repos.db"),
		InstalledDB: filepath.Join(persistDir, "installed.db"),
		SQLiteDB:    filepath.Join(persistDir, "zenpm.sqlite3"),
		ScriptDir:   filepath.Join(persistDir, "scripts"),
		CacheDir:    filepath.Join(home, "cache"),
		TmpDir:      filepath.Join(home, "tmp"),
		LockDir:     filepath.Join(home, "locks"),
		JournalDir:  filepath.Join(home, "journal"),
		LogFile:     filepath.Join(home, "ZenPM.log"),
	}

	for _, dir := range []string{
		s.CacheDir, s.ScriptDir, s.TmpDir, s.LockDir, s.JournalDir,
		persistDir,
	} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return nil, fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}

	s.StateBackend = os.Getenv("ZENPM_STATE_BACKEND")
	if s.StateBackend == "" {
		s.StateBackend = "flat"
	}
	switch s.StateBackend {
	case "flat":
		// Migrate state DBs from old home/state/ to persistent location.
		oldStateDir := filepath.Join(home, "state")
		migrateDB(filepath.Join(oldStateDir, "repos.db"), s.ReposDB)
		migrateDB(filepath.Join(oldStateDir, "installed.db"), s.InstalledDB)
		s.store = &flatFileStore{s: s}
	case "sqlite":
		store, err := newSQLiteStore(s, platform)
		if err != nil {
			return nil, err
		}
		s.store = store
	default:
		return nil, fmt.Errorf("unsupported ZENPM_STATE_BACKEND %q", s.StateBackend)
	}

	if err := seedReposDB(s); err != nil {
		return nil, err
	}
	if err := reconcileDefaultRepos(s); err != nil {
		return nil, err
	}
	if err := seedInstalledDB(s); err != nil {
		return nil, err
	}
	if store, ok := s.store.(*sqliteStore); ok {
		if err := store.importStartupState(platform); err != nil {
			return nil, err
		}
	}

	// Scan for known apps already on the device and ensure they're tracked.
	scanKnownApps(s, platform)

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

func migrateDB(oldPath, newPath string) {
	if _, err := os.Stat(newPath); err == nil {
		return // new path already exists
	}
	if _, err := os.Stat(oldPath); err != nil {
		return // nothing to migrate
	}
	data, err := os.ReadFile(oldPath)
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(newPath), 0755)
	_ = os.WriteFile(newPath, data, 0644)
}

func seedReposDB(s *State) error {
	if s.StateBackend == "flat" {
		if _, err := os.Stat(s.ReposDB); err == nil {
			return nil // already exists
		}
	}
	if s.StateBackend == "sqlite" {
		repos, err := s.ReadRepos()
		if err != nil {
			return err
		}
		if len(repos) > 0 {
			return nil
		}
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
	if s.StateBackend == "sqlite" {
		_ = s.WriteCatalog(nil)
	} else {
		_ = os.Remove(filepath.Join(s.CacheDir, "catalog.merged"))
	}
	s.SeededRepoURL = DefaultZenLabsRepoURL
	return nil
}

func seedInstalledDB(s *State) error {
	if s.StateBackend == "sqlite" {
		return nil
	}
	return (&flatFileStore{s: s}).seedInstalled()
}

// knownApp describes an app that may be pre-installed outside of ZenPM.
type knownApp struct {
	ID          string
	DisplayName string
	CheckDir    string // directory or file that confirms installation
}

func scanKnownApps(s *State, platform string) {
	fmt.Fprintf(os.Stderr, "[zenpm] scanKnownApps: platform=%s\n", platform)
	if platform != "kindle" {
		fmt.Fprintf(os.Stderr, "[zenpm] scanKnownApps: skipping — not kindle\n")
		return
	}

	apps := []knownApp{
		{ID: "koreader-kindle", DisplayName: "KOReader", CheckDir: "/mnt/us/koreader"},
		{ID: "kual", DisplayName: "KUAL", CheckDir: "/mnt/us/extensions/kual"},
		{ID: "zen-reader", DisplayName: "ZenReader", CheckDir: "/mnt/us/documents/ZenReader.sh"},
		{ID: "zen-mtp", DisplayName: "ZenMTP", CheckDir: "/mnt/us/documents/ZenMTP"},
		{ID: "kindle-browser", DisplayName: "Kindle Browser", CheckDir: "/mnt/us/documents/Browser.sh"},
	}

	installed, err := s.ReadInstalled()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[zenpm] scanKnownApps: ReadInstalled error: %v\n", err)
	}
	installedSet := make(map[string]bool, len(installed))
	for _, e := range installed {
		installedSet[e.ID] = true
	}
	fmt.Fprintf(os.Stderr, "[zenpm] scanKnownApps: %d already tracked\n", len(installedSet))

	var added int
	for _, app := range apps {
		if installedSet[app.ID] {
			fmt.Fprintf(os.Stderr, "[zenpm] scanKnownApps: %s — already tracked, skip\n", app.ID)
			continue
		}
		if _, err := os.Stat(app.CheckDir); err == nil {
			fmt.Fprintf(os.Stderr, "[zenpm] scanKnownApps: %s — found at %s, adding\n", app.ID, app.CheckDir)
			if appendErr := s.AppendInstalled(InstalledEntry{
				ID:      app.ID,
				Name:    app.DisplayName,
				Version: "0.0.0",
				Repo:    "device",
			}); appendErr != nil {
				fmt.Fprintf(os.Stderr, "[zenpm] scanKnownApps: AppendInstalled %s failed: %v\n", app.ID, appendErr)
			} else {
				added++
			}
		} else {
			fmt.Fprintf(os.Stderr, "[zenpm] scanKnownApps: %s — not found at %s (%v)\n", app.ID, app.CheckDir, err)
		}
	}

	fmt.Fprintf(os.Stderr, "[zenpm] scanKnownApps: added %d new apps\n", added)

	if added > 0 {
		_ = os.WriteFile(
			filepath.Join(filepath.Dir(s.InstalledDB), ".known-apps-scanned"),
			[]byte("done"), 0644,
		)
	}
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

func (s *State) ReadCatalog() ([]CatalogEntry, error) {
	return s.store.ReadCatalog()
}

func (s *State) WriteCatalog(entries []CatalogEntry) error {
	return s.store.WriteCatalog(entries)
}
