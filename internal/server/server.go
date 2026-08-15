package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/xZenLabs/zen-pm/internal/log"
	"github.com/xZenLabs/zen-pm/internal/maintenance"
	"github.com/xZenLabs/zen-pm/internal/pkg"
	"github.com/xZenLabs/zen-pm/internal/platform"
	"github.com/xZenLabs/zen-pm/internal/readmeimages"
	"github.com/xZenLabs/zen-pm/internal/releases"
	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/state"
)

// Version is injected at build time via ldflags or set by cmd/zenpm.
var Version = "dev"

// Server is the ZenPM HTTP API server.
type Server struct {
	st         *state.State
	repos      *repo.Manager
	pkgs       *pkg.Manager
	port       int
	unixSocket bool

	// IdleTimeout stops an otherwise idle server. It is used by the Android
	// companion so its foreground service does not remain alive indefinitely.
	IdleTimeout time.Duration

	mu             sync.Mutex
	httpServer     *http.Server
	listener       net.Listener
	closed         bool
	done           chan struct{}
	closeDone      sync.Once
	activeRequests atomic.Int32
	backgroundJobs atomic.Int32
	lastActivity   atomic.Int64
	StartedAt      time.Time
	readmeImages   readmeImagePreparer
}

type readmeImagePreparer interface {
	References(markdown, baseURL string) map[string]string
	Prepare(refs map[string]string) error
}

type pkgJSON struct {
	ID                    string            `json:"id"`
	Name                  string            `json:"name"`
	Version               string            `json:"version"`
	Description           string            `json:"description"`
	Author                string            `json:"author"`
	Tags                  []string          `json:"tags"`
	Category              string            `json:"category,omitempty"`
	Platforms             []string          `json:"platforms"`
	IncompatiblePlatforms []string          `json:"incompatible_platforms,omitempty"`
	Conflicts             []string          `json:"conflicts,omitempty"`
	Repo                  string            `json:"repo"`
	RepoTrust             string            `json:"repo_trust,omitempty"`
	RepoDefault           bool              `json:"repo_default,omitempty"`
	Installed             bool              `json:"installed"`
	InstalledVer          string            `json:"installed_version,omitempty"`
	InstalledAt           string            `json:"installed_at,omitempty"`
	InstalledAsset        string            `json:"installed_asset,omitempty"`
	UpdateIgnored         bool              `json:"update_ignored,omitempty"`
	InstalledAssets       []string          `json:"installed_assets,omitempty"`
	InstalledAssetDates   map[string]string `json:"installed_asset_dates,omitempty"`
	UnmanagedPatch        bool              `json:"unmanaged_patch,omitempty"`
	LatestVersion         string            `json:"latest_version,omitempty"`
	LatestRelease         string            `json:"latest_release,omitempty"`
	UpdateAvail           bool              `json:"update_available,omitempty"`
	IconURL               string            `json:"icon_url,omitempty"`
	RepoIconURL           string            `json:"repo_icon_url,omitempty"`
	ImageURL              string            `json:"image_url,omitempty"`
	Images                []string          `json:"images,omitempty"`
	Featured              bool              `json:"featured,omitempty"`
	FeaturedImage         string            `json:"featured_image,omitempty"`
	FeaturedOrder         *int              `json:"featured_order,omitempty"`
	Source                string            `json:"source,omitempty"`
	SourceAsset           string            `json:"source_asset,omitempty"`
	SourceType            string            `json:"source_type,omitempty"`
	SourceURL             string            `json:"source_url,omitempty"`
	ReadmeURL             string            `json:"readme_url,omitempty"`
	VersionsURL           string            `json:"versions_url,omitempty"`
	ReleaseNotesURL       string            `json:"release_notes_url,omitempty"`
	PrereleaseNotesURL    string            `json:"prerelease_notes_url,omitempty"`
	PrereleaseVersion     string            `json:"prerelease_version,omitempty"`
	PublishedAt           string            `json:"published_at,omitempty"`
	Stars                 string            `json:"stars,omitempty"`
	PluginModule          string            `json:"plugin_module,omitempty"`
	PluginModuleAliases   []string          `json:"plugin_module_aliases,omitempty"`
	SourceAssetAliases    []string          `json:"source_asset_aliases,omitempty"`
	Assets                json.RawMessage   `json:"assets,omitempty"`
	Constraints           json.RawMessage   `json:"constraints,omitempty"`
}

func New(st *state.State, repos *repo.Manager, pkgs *pkg.Manager, port int) *Server {
	srv := &Server{st: st, repos: repos, pkgs: pkgs, port: port, done: make(chan struct{})}
	if st != nil {
		srv.readmeImages = readmeimages.New(filepath.Join(st.CacheDir, "readme-images"))
	}
	return srv
}

func (s *Server) ListenAndServe() error {
	addr := fmt.Sprintf("127.0.0.1:%d", s.port)
	return s.listenAndServe(addr, func() (net.Listener, error) {
		return s.listen(addr)
	})
}

func (s *Server) ListenAndServeUnix(path string) error {
	s.unixSocket = true
	bound := false
	err := s.listenAndServe("unix:"+path, func() (net.Listener, error) {
		ln, listenErr := s.listenUnix(path)
		if listenErr == nil {
			bound = true
		}
		return ln, listenErr
	})
	if errors.Is(err, errServerAlreadyRunning) {
		return nil
	}
	if bound && !isAbstractUnixSocket(path) {
		_ = os.Remove(path)
	}
	return err
}

func (s *Server) listenAndServe(addr string, bind func() (net.Listener, error)) error {
	s.touch()
	defer s.signalDone()
	state.StartupTrace("HTTP server: configuring routes.")
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.wrap(s.handleHealth))
	mux.HandleFunc("/repos", s.wrap(s.handleRepos))
	mux.HandleFunc("/repos/", s.wrap(s.handleRepoByName))
	mux.HandleFunc("/repo/refresh", s.wrap(s.handleRepoRefresh))
	mux.HandleFunc("/koreader/plugins/scan", s.wrap(s.handleKOReaderPluginScan))
	mux.HandleFunc("/packages", s.wrap(s.handlePackageList))
	mux.HandleFunc("/packages/update", s.wrap(s.handlePackageUpdate))
	mux.HandleFunc("/packages/", s.wrap(s.handlePackageAction))
	mux.HandleFunc("/log", s.wrap(s.handleLog))
	mux.HandleFunc("/log/client", s.wrap(s.handleClientLog))
	mux.HandleFunc("/dialog", s.wrap(s.handleDialog))
	mux.HandleFunc("/foreground", s.wrap(s.handleForeground))
	mux.HandleFunc("/update", s.wrap(s.handleUpdate))
	mux.HandleFunc("/uninstall", s.wrap(s.handleUninstall))

	// Auto-refresh catalog on first start so the WAF has packages without manual refresh.
	state.StartupTrace("HTTP server: reading catalog state.")
	catalog, needsRefresh := s.initialCatalogState()
	state.StartupTrace("HTTP server: catalog state ready.")
	if needsRefresh {
		s.runBackground(func() {
			if err := s.repos.Refresh(); err != nil {
				log.Warnf("Initial refresh failed: %v", err)
				return
			}
			s.autoScanKOReaderPlugins()
		})
	} else {
		s.autoScanKOReaderPlugins()
		s.runBackground(func() {
			s.repos.CacheInstalledUninstallScripts(catalog)
		})
	}

	// Keep the catalog fresh in the background so the client never has to fetch
	// repo manifests itself: refresh once a day for long-running daemons.
	go s.periodicRefresh()

	state.StartupTrace("HTTP server: binding " + addr + ".")
	httpServer := &http.Server{Handler: mux}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.httpServer = httpServer
	s.mu.Unlock()

	ln, err := bind()
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.listener = ln
	closed := s.closed
	s.mu.Unlock()
	if closed {
		_ = ln.Close()
		return nil
	}
	state.StartupTrace("HTTP server: listening on " + addr + ".")
	if !s.StartedAt.IsZero() {
		log.Infof("Timing: server listening on %s, %dms after process start", addr, time.Since(s.StartedAt).Milliseconds())
	} else {
		log.Infof("ZenPM server listening on %s", addr)
	}
	if s.IdleTimeout > 0 {
		go s.stopWhenIdle()
	}
	err = httpServer.Serve(ln)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

var errServerAlreadyRunning = errors.New("ZenPM server already running")

// listen binds addr, resolving the two racy port-conflict cases that arise when
// the native installer daemon and the KOReader plugin both target port 18765:
//   - a healthy ZenPM already owns the port → duplicate launch, exit clean(0) so
//     the frontend keeps using the live daemon instead of seeing a crash.
//   - the port is held by a predecessor still shutting down (plugin pkill'd it a
//     moment ago) → retry the bind for a few seconds while the socket drains.
func (s *Server) listen(addr string) (net.Listener, error) {
	const attempts = 10
	for i := 0; ; i++ {
		ln, err := net.Listen("tcp", addr)
		if err == nil {
			return ln, nil
		}
		if !errors.Is(err, syscall.EADDRINUSE) {
			return nil, fmt.Errorf("listen %s: %w", addr, err)
		}
		if s.daemonAlreadyRunning(addr) {
			log.Infof("ZenPM already running on %s — this instance exiting", addr)
			os.Exit(0)
		}
		if i >= attempts {
			return nil, fmt.Errorf("listen %s: %w", addr, err)
		}
		log.Infof("Port %s busy but no healthy daemon — retrying bind (%d/%d)", addr, i+1, attempts)
		time.Sleep(500 * time.Millisecond)
	}
}

func (s *Server) listenUnix(path string) (net.Listener, error) {
	if path == "" {
		return nil, errors.New("Unix socket path is empty")
	}
	if isAbstractUnixSocket(path) {
		ln, err := net.Listen("unix", path)
		if err != nil {
			return nil, fmt.Errorf("listen unix:%s: %w", path, err)
		}
		return ln, nil
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("listen unix:%s: existing path is not a socket", path)
		}
		conn, dialErr := net.DialTimeout("unix", path, 200*time.Millisecond)
		if dialErr == nil {
			conn.Close()
			log.Infof("ZenPM already running on unix:%s — this instance exiting", path)
			return nil, errServerAlreadyRunning
		}
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("remove stale Unix socket %s: %w", path, err)
		}
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("inspect Unix socket %s: %w", path, err)
	}

	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("listen unix:%s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		_ = os.Remove(path)
		return nil, fmt.Errorf("secure Unix socket %s: %w", path, err)
	}
	return ln, nil
}

func isAbstractUnixSocket(path string) bool {
	return strings.HasPrefix(path, "@")
}

// Close stops a running server and any idle/background bookkeeping attached to
// it. It is safe to call before the listener is fully initialized.
func (s *Server) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	httpServer := s.httpServer
	listener := s.listener
	s.mu.Unlock()
	s.signalDone()
	if httpServer != nil {
		err := httpServer.Close()
		if err == nil || errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
	if listener != nil {
		return listener.Close()
	}
	return nil
}

func (s *Server) signalDone() {
	s.closeDone.Do(func() {
		if s.done == nil {
			s.done = make(chan struct{})
		}
		close(s.done)
	})
}

func (s *Server) touch() {
	s.lastActivity.Store(time.Now().UnixNano())
}

func (s *Server) runBackground(work func()) {
	s.backgroundJobs.Add(1)
	s.touch()
	go func() {
		defer func() {
			s.backgroundJobs.Add(-1)
			s.touch()
		}()
		work()
	}()
}

func (s *Server) stopWhenIdle() {
	interval := s.IdleTimeout / 10
	if interval < 25*time.Millisecond {
		interval = 25 * time.Millisecond
	}
	if interval > 5*time.Second {
		interval = 5 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-ticker.C:
			lastActivity := time.Unix(0, s.lastActivity.Load())
			if s.activeRequests.Load() != 0 || s.backgroundJobs.Load() != 0 || time.Since(lastActivity) < s.IdleTimeout {
				continue
			}
			log.Infof("ZenPM server idle for %s — stopping", s.IdleTimeout)
			_ = s.Close()
			return
		}
	}
}

// daemonAlreadyRunning probes /health to confirm a live ZenPM daemon owns addr,
// distinguishing a duplicate launch from a foreign process squatting the port.
func (s *Server) daemonAlreadyRunning(addr string) bool {
	client := http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://" + addr + "/health")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// catalogMaxAge is how stale the catalog may get before a refresh is forced.
const catalogMaxAge = 24 * time.Hour

func (s *Server) initialCatalogState() ([]*repo.CatalogEntry, bool) {
	catalog, err := s.repos.ReadCatalog()
	if err != nil {
		log.Info("No catalog found — running initial repo refresh")
		return nil, true
	}
	if len(catalog) == 0 {
		log.Info("Catalog is empty — running initial repo refresh")
		return nil, true
	}
	if refreshRequired, _ := s.st.ReadValue(state.CatalogPublishedAtRefreshKey); refreshRequired == "1" {
		log.Info("Catalog metadata needs refresh")
		return catalog, true
	}
	if age := s.repos.CatalogAge(); age >= catalogMaxAge {
		log.Infof("Catalog is %s old — running repo refresh", age.Round(time.Hour))
		return catalog, true
	}
	return catalog, false
}

// periodicRefresh refreshes the catalog once per catalogMaxAge for the lifetime
// of the daemon. Errors are logged and the loop continues.
func (s *Server) periodicRefresh() {
	ticker := time.NewTicker(catalogMaxAge)
	defer ticker.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-ticker.C:
			log.Info("Periodic catalog refresh")
			s.runBackground(func() {
				if err := s.repos.Refresh(); err != nil {
					log.Warnf("Periodic refresh failed: %v", err)
				}
			})
		}
	}
}

func (s *Server) autoScanKOReaderPlugins() {
	result, err := s.pkgs.ScanKOReaderPlugins(false)
	if err != nil {
		log.Infof("KOReader plugin auto-scan not completed: %v", err)
		return
	}
	if !result.Skipped {
		log.Infof("KOReader plugin scan: scanned=%d matched=%d added=%d updated=%d", result.Scanned, result.Matched, result.Added, result.Updated)
	}
}

const accessErrorBodyLimit = 1024

// responseRecorder captures the status code and a bounded error body written
// by a handler.
type responseRecorder struct {
	http.ResponseWriter
	status        int
	wroteHeader   bool
	errorBody     strings.Builder
	bodyTruncated bool
}

func (rec *responseRecorder) WriteHeader(code int) {
	if rec.wroteHeader {
		return
	}
	rec.wroteHeader = true
	rec.status = code
	rec.ResponseWriter.WriteHeader(code)
}

func (rec *responseRecorder) Write(data []byte) (int, error) {
	if !rec.wroteHeader {
		rec.WriteHeader(http.StatusOK)
	}
	if rec.status >= http.StatusBadRequest {
		remaining := accessErrorBodyLimit - rec.errorBody.Len()
		if remaining <= 0 {
			rec.bodyTruncated = true
		} else {
			capture := data
			if len(capture) > remaining {
				rec.bodyTruncated = true
				capture = capture[:remaining]
			}
			_, _ = rec.errorBody.Write(capture)
		}
	}
	return rec.ResponseWriter.Write(data)
}

func (rec *responseRecorder) errorDetail() string {
	detail := strings.Join(strings.Fields(rec.errorBody.String()), " ")
	if rec.bodyTruncated {
		detail += "..."
	}
	return detail
}

// wrap adds CORS headers, enforces local-only access, and logs every request.
func (s *Server) wrap(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.activeRequests.Add(1)
		s.touch()
		defer func() {
			s.activeRequests.Add(-1)
			s.touch()
		}()
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		rec := &responseRecorder{ResponseWriter: w, status: http.StatusOK}
		if !s.unixSocket {
			host, _, _ := net.SplitHostPort(r.RemoteAddr)
			if host != "127.0.0.1" && host != "::1" {
				http.Error(rec, "forbidden", http.StatusForbidden)
				logAccess(r, rec)
				return
			}
		}
		h(rec, r)
		logAccess(r, rec)
	}
}

func logAccess(r *http.Request, rec *responseRecorder) {
	if !shouldLogAccess(r, rec.status) {
		return
	}
	if rec.status >= http.StatusBadRequest {
		message := fmt.Sprintf("%s %s %d %s", r.Method, r.URL.RequestURI(), rec.status, http.StatusText(rec.status))
		if detail := rec.errorDetail(); detail != "" {
			message += fmt.Sprintf(" error=%q", detail)
		}
		log.Warn(message)
		return
	}
	log.Infof("%s %s %d", r.Method, r.URL.RequestURI(), rec.status)
}

func shouldLogAccess(r *http.Request, status int) bool {
	if status >= http.StatusBadRequest {
		return true
	}
	if r.URL.Path == "/log/client" {
		return false
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return true
	}
	switch r.URL.Path {
	case "/health", "/log", "/packages", "/repos":
		return false
	default:
		return true
	}
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	log.Infof("Health probe served")
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok":        true,
		"version":   Version,
		"home":      s.st.Home,
		"cache_dir": s.st.CacheDir,
	})
}

func (s *Server) handleRepos(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		repos, err := s.repos.List()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		type repoJSON struct {
			Name     string `json:"name"`
			URL      string `json:"url"`
			Priority int    `json:"priority"`
			Trust    string `json:"trust"`
			Default  bool   `json:"default"`
			IconURL  string `json:"icon_url,omitempty"`
		}
		repoIcons := make(map[string]string)
		if catalog, err := s.repos.ReadCatalog(); err == nil {
			for _, entry := range catalog {
				if entry.RepoIconURL != "" && repoIcons[entry.Repo] == "" {
					repoIcons[entry.Repo] = entry.RepoIconURL
				}
			}
		}
		result := make([]repoJSON, len(repos))
		for i, e := range repos {
			result[i] = repoJSON{Name: e.Name, URL: e.URL, Priority: e.Priority, Trust: e.Trust, Default: e.Default, IconURL: repoIcons[e.Name]}
		}
		writeJSON(w, http.StatusOK, result)
	case http.MethodPost:
		var body struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Name == "" || body.URL == "" {
			http.Error(w, "name and url required", http.StatusBadRequest)
			return
		}

		// Priority and trust are backend-determined — callers cannot set them.
		priority := repo.UserAddedPriority

		trust := "trusted"
		if repo.IsKindleForgeRepo(body.Name, body.URL) {
			log.Infof("Repo %s: KindleForge registry — trust=%s", body.Name, trust)
		} else {
			// Auto-detect trust via manifest.json.sig signature.
			var sigErr error
			trust, sigErr = repo.VerifyRepoSignature(body.URL)
			if sigErr != nil {
				trust = "warn-unsigned"
				log.Infof("Repo %s: %v — trust=%s", body.Name, sigErr, trust)
			} else {
				log.Infof("Repo %s signature: trust=%s", body.Name, trust)
			}
		}

		// Warn on plain-HTTP repos (signatures are meaningless over HTTP).
		var warning string
		if safety := repo.CheckRepoURLSafety(body.URL); safety != "" {
			log.Warnf("Repo %s: %s", body.Name, safety)
			warning = safety
			if trust == "signed" {
				trust = "warn-unsigned"
			}
		}

		if err := s.repos.Add(body.Name, body.URL, priority, trust); err != nil {
			writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
			return
		}
		// Bring ZenPM WAF to foreground so the user sees the newly added repo.
		s.foreground()
		resp := map[string]interface{}{"ok": true}
		if warning != "" {
			resp["warning"] = warning
		}
		writeJSON(w, http.StatusCreated, resp)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleRepoByName(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/repos/")
	if name == "" {
		http.Error(w, "missing name", http.StatusBadRequest)
		return
	}

	// Check if this is a default repo before allowing mutation.
	repos, _ := s.repos.List()
	isDefault := false
	for _, repo := range repos {
		if repo.Name == name && repo.Default {
			isDefault = true
			break
		}
	}

	switch r.Method {
	case http.MethodPut:
		if isDefault {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "cannot modify default repo"})
			return
		}
		var body struct {
			URL      string `json:"url"`
			Priority int    `json:"priority"`
			Trust    string `json:"trust"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.URL == "" {
			http.Error(w, "url required", http.StatusBadRequest)
			return
		}
		if body.Priority == 0 {
			body.Priority = 100
		}
		if body.Trust == "" {
			body.Trust = "warn-unsigned"
		}
		if err := s.repos.Remove(name); err != nil {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
			return
		}
		if err := s.repos.Add(name, body.URL, body.Priority, body.Trust); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	case http.MethodDelete:
		if isDefault {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "cannot remove default repo"})
			return
		}
		if err := s.repos.Remove(name); err != nil {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleRepoRefresh(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	err := s.repos.Refresh()
	logTail, _ := tailLog(s.st.LogFile, 200)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"ok": false, "error": err.Error(), "log": logTail,
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true, "log": logTail})
}

func (s *Server) handleKOReaderPluginScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	result, err := s.pkgs.ScanKOReaderPlugins(true)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]interface{}{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok": true, "scanned": result.Scanned, "matched": result.Matched,
		"added": result.Added, "updated": result.Updated,
	})
}

func (s *Server) handlePackageList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	plat := r.URL.Query().Get("platform")
	allowPrerelease := r.URL.Query().Get("beta") == "1" || r.URL.Query().Get("beta") == "true"
	catalog, err := s.repos.ReadCatalog()
	if err != nil {
		// Catalog doesn't exist yet — return empty list so WAF can show "no packages" instead of error.
		log.Warnf("GET /packages: catalog missing at %s (run repo refresh)", s.st.CacheDir)
		writeJSON(w, http.StatusOK, []struct{}{})
		return
	}
	if len(catalog) == 0 {
		log.Warn("GET /packages: catalog is empty — try repo refresh")
	}

	installed, _ := s.st.ReadInstalled()
	installedSet := make(map[string]bool, len(installed))
	installedVersion := make(map[string]string, len(installed))
	installedAt := make(map[string]string, len(installed))
	installedAsset := make(map[string]string, len(installed))
	updateIgnored := make(map[string]bool, len(installed))
	updateIgnoredVersion := make(map[string]string, len(installed))
	for _, e := range installed {
		installedSet[e.ID] = true
		installedVersion[e.ID] = e.Version
		installedAt[e.ID] = e.InstalledAt
		installedAsset[e.ID] = e.Asset
		updateIgnored[e.ID] = e.UpdateIgnored
		updateIgnoredVersion[e.ID] = e.UpdateIgnoredVersion
	}

	patchFiles, _ := s.st.ReadInstalledPatchFiles()
	installedAssets := make(map[string][]string)
	installedAssetDates := make(map[string]map[string]string)
	for _, f := range patchFiles {
		installedAssets[f.PackageID] = append(installedAssets[f.PackageID], f.Asset)
		if installedAssetDates[f.PackageID] == nil {
			installedAssetDates[f.PackageID] = make(map[string]string)
		}
		installedAssetDates[f.PackageID][f.Asset] = f.InstalledAt
	}

	filtered := repo.FilterByPlatform(catalog, plat)
	platformList := platformValues(plat)
	repoEntries, _ := s.repos.List()
	repoTrust := make(map[string]string, len(repoEntries))
	repoDefault := make(map[string]bool, len(repoEntries))
	for _, r := range repoEntries {
		repoTrust[r.Name] = r.Trust
		repoDefault[r.Name] = r.Default
	}
	seen := make(map[string]bool, len(filtered))
	result := make([]pkgJSON, 0, len(filtered)+len(installed))
	for _, e := range filtered {
		seen[e.ID] = true
		item := pkgJSON{
			ID: e.ID, Name: e.Name, Version: e.Version,
			Description: e.Description, Author: e.Author,
			Tags:      e.Tags,
			Category:  e.Category,
			Platforms: e.Platforms, Repo: e.Repo, RepoTrust: repoTrust[e.Repo], RepoDefault: repoDefault[e.Repo], Installed: installedSet[e.ID] || len(installedAssets[e.ID]) > 0,
			IncompatiblePlatforms: e.IncompatiblePlatforms,
			Conflicts:             e.Conflicts,
			IconURL:               e.IconURL,
			RepoIconURL:           e.RepoIconURL,
			ImageURL:              firstString(e.Images),
			Images:                e.Images,
			Featured:              e.Featured,
			FeaturedImage:         e.FeaturedImage,
			FeaturedOrder:         e.FeaturedOrder,
			Source:                e.Source,
			SourceAsset:           e.SourceAsset,
			SourceType:            e.SourceType,
			SourceURL:             e.SourceURL,
			ReadmeURL:             e.ReadmeURL,
			VersionsURL:           e.VersionsURL,
			ReleaseNotesURL:       e.ReleaseNotesURL,
			PrereleaseNotesURL:    e.PrereleaseNotesURL,
			PrereleaseVersion:     e.PrereleaseVersion,
			PublishedAt:           e.PublishedAt,
			Stars:                 e.Stars,
			PluginModule:          e.PluginModule,
			PluginModuleAliases:   e.PluginModuleAliases,
			SourceAssetAliases:    e.SourceAssetAliases,
			Assets:                rawJSON(e.Assets),
			Constraints:           rawJSON(e.Constraints),
		}
		if files := installedAssets[e.ID]; len(files) > 0 {
			item.InstalledAssets = files
			item.InstalledAssetDates = installedAssetDates[e.ID]
		}
		if item.Installed {
			item.InstalledVer = installedVersion[e.ID]
			item.InstalledAt = installedAt[e.ID]
			item.InstalledAsset = installedAsset[e.ID]
			applyUpdateInfo(&item, allowPrerelease)
			item.UpdateIgnored = updateIgnored[e.ID]
			if item.UpdateAvail && updateIgnoredVersion[e.ID] == item.LatestVersion {
				item.UpdateIgnored = true
			}
		}
		result = append(result, item)
	}

	// Include installed packages not in any catalog.
	for _, e := range installed {
		if !seen[e.ID] {
			name := e.Name
			if name == "" {
				name = e.ID
			}
			item := pkgJSON{
				ID: e.ID, Name: name, Version: e.Version,
				Repo: e.Repo, Installed: true,
				InstalledVer:   e.Version,
				InstalledAt:    e.InstalledAt,
				InstalledAsset: e.Asset,
				UpdateIgnored:  e.UpdateIgnored,
				Platforms:      platformList,
			}
			result = append(result, item)
		}
	}
	if patches, err := s.pkgs.UnmanagedKOReaderPatches(); err == nil {
		for _, patch := range patches {
			result = append(result, pkgJSON{
				ID:              "local-patch:" + patch.Asset,
				Name:            patch.Asset,
				Category:        "patches",
				Platforms:       []string{"koreader"},
				Installed:       true,
				InstalledAssets: []string{patch.Asset},
				UnmanagedPatch:  true,
			})
		}
	}

	writeJSON(w, http.StatusOK, result)
}

func platformValues(platform string) []string {
	var out []string
	for _, value := range strings.Split(platform, ",") {
		value = strings.TrimSpace(value)
		if value != "" {
			out = append(out, value)
		}
	}
	return out
}

func applyUpdateInfo(item *pkgJSON, allowPrerelease bool) {
	if item == nil {
		return
	}
	latest := item.Version
	if allowPrerelease && prereleaseIsNewer(item.Version, item.PrereleaseVersion) {
		latest = item.PrereleaseVersion
	}
	if latest == "" || !hasKnownVersion(item.InstalledVer) {
		return
	}
	item.LatestVersion = latest
	if sameReleaseWithCommitSuffix(latest, item.InstalledVer) {
		return
	}
	item.UpdateAvail = releases.VersionGreater(latest, item.InstalledVer)
	if item.UpdateAvail {
		item.LatestRelease = latest
	}
}

func sameReleaseWithCommitSuffix(latest, installed string) bool {
	latest = releases.NormalizeVersion(latest)
	installed = releases.NormalizeVersion(installed)
	prefix := installed + "-"
	if !strings.HasPrefix(latest, prefix) {
		return false
	}
	suffix := strings.TrimPrefix(latest, prefix)
	if len(suffix) != 40 {
		return false
	}
	for _, digit := range suffix {
		if !(digit >= '0' && digit <= '9') && !(digit >= 'a' && digit <= 'f') {
			return false
		}
	}
	return true
}

func prereleaseIsNewer(stable, prerelease string) bool {
	if strings.TrimSpace(prerelease) == "" {
		return false
	}
	if strings.TrimSpace(stable) == "" {
		return true
	}
	stableBase := strings.SplitN(releases.NormalizeVersion(stable), "-", 2)[0]
	prereleaseBase := strings.SplitN(releases.NormalizeVersion(prerelease), "-", 2)[0]
	return stableBase != prereleaseBase && releases.VersionGreater(prerelease, stable)
}

func hasKnownVersion(version string) bool {
	version = releases.NormalizeVersion(version)
	return version != "" && version != "0.0.0"
}

func firstString(values []string) string {
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

func rawJSON(value string) json.RawMessage {
	value = strings.TrimSpace(value)
	if value == "" || !json.Valid([]byte(value)) {
		return nil
	}
	return json.RawMessage(value)
}

func (s *Server) handlePackageAction(w http.ResponseWriter, r *http.Request) {
	// Expects: /packages/{id}/{install,reinstall,uninstall,assets,readme,release-notes,releases}
	path := strings.TrimPrefix(r.URL.Path, "/packages/")
	parts := strings.SplitN(path, "/", 2)
	if len(parts) < 2 || parts[0] == "" {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	id, action := parts[0], parts[1]
	if action == "assets" {
		s.handlePackageAssets(w, r, id)
		return
	}
	if action == "readme" {
		s.handlePackageReadme(w, r, id)
		return
	}
	if action == "release-notes" {
		s.handlePackageReleaseNotes(w, r, id)
		return
	}
	if action == "releases" {
		s.handlePackageReleases(w, r, id)
		return
	}
	if action == "update-ignored" {
		s.handlePackageUpdateIgnored(w, r, id)
		return
	}
	if action != "install" && action != "reinstall" && action != "uninstall" {
		http.Error(w, "unknown action: "+action, http.StatusBadRequest)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	asset := r.URL.Query().Get("asset")
	releaseTag := r.URL.Query().Get("release")

	if action == "install" || action == "reinstall" {
		if err := s.pkgs.CheckInstall(id); err != nil {
			log.Errorf("Package %s %s failed: %v", id, action, err)
			writeJSON(w, http.StatusConflict, map[string]interface{}{"ok": false, "error": err.Error()})
			return
		}
	}

	// Fire async; the WAF polls /log after a delay.
	log.Infof("Package %s: starting %s", id, action)
	s.runBackground(func() {
		var err error
		if action == "install" {
			if releaseTag != "" {
				err = s.pkgs.InstallRelease(id, releaseTag, asset)
			} else {
				err = s.pkgs.InstallAsset(id, asset)
			}
		} else if action == "reinstall" {
			err = s.pkgs.Reinstall(id, asset, releaseTag)
		} else {
			err = s.pkgs.Uninstall(id, asset)
		}
		if err != nil {
			log.Errorf("Package %s %s failed: %v", id, action, err)
		} else {
			log.Infof("Package %s: %s complete", id, action)
		}
	})

	writeJSON(w, http.StatusAccepted, map[string]interface{}{"ok": true, "started": true})
}

func (s *Server) handlePackageUpdateIgnored(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		UpdateIgnored        *bool   `json:"update_ignored"`
		UpdateIgnoredVersion *string `json:"update_ignored_version"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "update_ignored required", http.StatusBadRequest)
		return
	}
	if body.UpdateIgnoredVersion != nil {
		version := strings.TrimSpace(*body.UpdateIgnoredVersion)
		if version == "" || body.UpdateIgnored == nil || *body.UpdateIgnored {
			http.Error(w, "valid update_ignored_version required", http.StatusBadRequest)
			return
		}
		if err := s.st.SetInstalledUpdateIgnoredVersion(id, version); err != nil {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"ok": true, "update_ignored": true, "update_ignored_version": version,
		})
		return
	}
	if body.UpdateIgnored == nil {
		http.Error(w, "update_ignored required", http.StatusBadRequest)
		return
	}
	if err := s.st.SetInstalledUpdateIgnored(id, *body.UpdateIgnored); err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true, "update_ignored": *body.UpdateIgnored})
}

// handlePackageUpdate starts an update of every installed package. Like the
// per-package action endpoint, it returns immediately while the backend works.
func (s *Server) handlePackageUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	log.Info("Updating all installed packages")
	s.runBackground(func() {
		if err := s.pkgs.Update(""); err != nil {
			log.Errorf("Update all packages failed: %v", err)
			return
		}
		log.Info("Update all packages complete")
	})
	writeJSON(w, http.StatusAccepted, map[string]interface{}{"ok": true, "started": true})
}

func (s *Server) packageReleaseMetadata(id string) (string, string, string, []string, error) {
	catalog, err := s.repos.ReadCatalog()
	if err != nil {
		return "", "", "", nil, err
	}
	for _, entry := range catalog {
		if entry.ID == id {
			return strings.TrimSpace(entry.VersionsURL), strings.ToLower(strings.TrimSpace(entry.SourceType)), strings.TrimSpace(entry.SourceAsset), entry.SourceAssetAliases, nil
		}
	}
	return "", "", "", nil, fmt.Errorf("package %q not found", id)
}

func (s *Server) packageReadmeMetadata(id string) (string, string, error) {
	catalog, err := s.repos.ReadCatalog()
	if err != nil {
		return "", "", err
	}
	for _, entry := range catalog {
		if entry.ID == id {
			if entry.ReadmeURL != "" {
				return entry.ReadmeURL, repositoryImageBaseURL(entry.Source), nil
			}
			return "", "", fmt.Errorf("package %q has no README URL", id)
		}
	}
	return "", "", fmt.Errorf("package %q not found", id)
}

func repositoryImageBaseURL(source string) string {
	if repository, ok := releases.GitHubRepository(source); ok {
		return "https://github.com/" + repository + "/raw/HEAD/"
	}
	source = strings.TrimSpace(source)
	if source == "" {
		return ""
	}
	return strings.TrimRight(source, "/") + "/"
}

func (s *Server) handlePackageReadme(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	readmeURL, imageBaseURL, err := s.packageReadmeMetadata(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	document, err := releases.FetchReadmeDocument(readmeURL)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	response := map[string]interface{}{
		"readme":                document.Readme,
		"readme_base_url":       document.BaseURL,
		"readme_image_base_url": imageBaseURL,
	}
	var refs map[string]string
	if s.readmeImages != nil {
		refs = s.readmeImages.References(document.Readme, imageBaseURL)
		response["readme_image_refs"] = refs
	}
	writeJSON(w, http.StatusOK, response)
	if len(refs) > 0 {
		s.runBackground(func() {
			if err := s.readmeImages.Prepare(refs); err != nil {
				log.Warnf("Could not prepare README images for %s: %v", id, err)
			}
		})
	}
}

func (s *Server) packageReleaseNotesMetadata(id string, prerelease bool) (string, string, string, error) {
	catalog, err := s.repos.ReadCatalog()
	if err != nil {
		return "", "", "", err
	}
	for _, entry := range catalog {
		if entry.ID != id {
			continue
		}
		notesURL := entry.ReleaseNotesURL
		version := entry.Version
		if prerelease && entry.PrereleaseNotesURL != "" {
			notesURL = entry.PrereleaseNotesURL
			version = entry.PrereleaseVersion
		}
		if notesURL == "" {
			return "", "", "", fmt.Errorf("package %q has no release notes URL", id)
		}
		return notesURL, repositoryImageBaseURL(entry.Source), version, nil
	}
	return "", "", "", fmt.Errorf("package %q not found", id)
}

func (s *Server) handlePackageReleaseNotes(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	prerelease := r.URL.Query().Get("prerelease") == "1" || r.URL.Query().Get("prerelease") == "true"
	notesURL, imageBaseURL, version, err := s.packageReleaseNotesMetadata(id, prerelease)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	document, err := releases.FetchReadmeDocument(notesURL)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"release_notes":                document.Readme,
		"release_notes_base_url":       document.BaseURL,
		"release_notes_image_base_url": imageBaseURL,
		"version":                      version,
	})
}

func (s *Server) handlePackageReleases(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	versionsURL, sourceType, sourceAsset, sourceAssetAliases, err := s.packageReleaseMetadata(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	items := []releases.Release{}
	if versionsURL != "" {
		items, err = releases.FetchVersions(versionsURL)
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if sourceAsset != "" && len(sourceAssetAliases) > 0 {
		aliases := make(map[string]bool, len(sourceAssetAliases))
		for _, alias := range sourceAssetAliases {
			alias = strings.TrimSpace(alias)
			if alias != "" && alias != sourceAsset {
				aliases[alias] = true
			}
		}
		for index := range items {
			hasCanonical := false
			for _, asset := range items[index].Assets {
				if strings.TrimSpace(asset.Name) == sourceAsset {
					hasCanonical = true
					break
				}
			}
			if !hasCanonical {
				continue
			}
			visible := items[index].Assets[:0]
			for _, asset := range items[index].Assets {
				if !aliases[strings.TrimSpace(asset.Name)] {
					visible = append(visible, asset)
				}
			}
			items[index].Assets = visible
		}
	}
	if sourceType == "source" {
		installable := make([]releases.Release, 0, len(items))
		for _, item := range items {
			assets := make([]releases.ReleaseAsset, 0, len(item.Assets))
			for _, asset := range item.Assets {
				if strings.TrimSpace(asset.Name) != "" && strings.TrimSpace(asset.URL) != "" {
					assets = append(assets, asset)
				}
			}
			if len(assets) > 0 {
				item.Assets = assets
				installable = append(installable, item)
			}
		}
		items = installable
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"releases": items})
}

func (s *Server) handlePackageAssets(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	res, err := s.pkgs.SelectAsset(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"auto":         res.Auto,
		"needs_choice": res.NeedsChoice,
		"candidates":   res.Candidates,
	})
}

func (s *Server) handleLog(w http.ResponseWriter, r *http.Request) {
	n := 200
	if t := r.URL.Query().Get("tail"); t != "" {
		if parsed, err := strconv.Atoi(t); err == nil && parsed > 0 {
			n = parsed
		}
	}
	content, err := tailLog(s.st.LogFile, n)
	if err != nil {
		log.Warnf("GET /log: log file not found at %s", s.st.LogFile)
		http.Error(w, "log not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, content)
}

// handleClientLog receives frontend log messages and writes them to the server log file.
func (s *Server) handleClientLog(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Message string `json:"message"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Message == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if shouldLogClientMessage(body.Message) {
		log.Infof("[client] %s", body.Message)
	} else if os.Getenv("ZENPM_CLIENT_DEBUG") == "1" {
		log.Debugf("[client] %s", body.Message)
	}
	w.WriteHeader(http.StatusNoContent)
}

func shouldLogClientMessage(message string) bool {
	lower := strings.ToLower(message)
	if strings.Contains(message, "JS ERROR") {
		return true
	}
	for _, word := range []string{
		"error", "failed", "unreachable", "package action",
		"install started", "uninstall started", "reinstall started",
		"refreshsources", "update failed",
	} {
		if strings.Contains(lower, word) {
			return true
		}
	}
	return false
}

func tailLog(path string, n int) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n"), nil
}

// handleDialog shows a native Kindle UI alert dialog via LIPC pillowAlert.
// Uses the same shell-based approach as KindleForge's KFPM.
func (s *Server) handleDialog(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Title   string `json:"title"`
		Message string `json:"message"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Title == "" {
		http.Error(w, "title required", http.StatusBadRequest)
		return
	}

	log.Infof("Dialog requested: title=%q message=%q", body.Title, body.Message)

	titleEsc := strings.ReplaceAll(body.Title, `"`, `\"`)
	msgEsc := strings.ReplaceAll(body.Message, `\`, `\\`)
	msgEsc = strings.ReplaceAll(msgEsc, "\n", `\n`)
	msgEsc = strings.ReplaceAll(msgEsc, `"`, `\"`)

	script := fmt.Sprintf(
		`JSON='{"clientParams":{"alertId":"appAlert1","show":true,"customStrings":[{"matchStr":"alertTitle","replaceStr":"%s"},{"matchStr":"alertText","replaceStr":"%s"}]}}'
lipc-set-prop com.lab126.pillow pillowAlert "$JSON"`,
		titleEsc, msgEsc,
	)

	log.Infof("Running dialog script: %s", script)

	cmd := exec.Command("/bin/sh", "-c", script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Warnf("Native dialog failed: %v — output: %s", err, string(out))
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if len(out) > 0 {
		log.Infof("Dialog command output: %s", string(out))
	}
	log.Infof("Dialog shown successfully")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// handleForeground brings the ZenPM WAF to the foreground via LIPC.
func (s *Server) handleForeground(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	s.foreground()
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// foreground brings the ZenPM WAF to the foreground via LIPC.
func (s *Server) foreground() {
	if s.st == nil || !s.st.AllowsKindleWAF() {
		log.Info("Foreground skipped: Kindle WAF is unavailable on this device")
		return
	}
	cmd := exec.Command("lipc-set-prop", "com.lab126.appmgrd", "start", "app://com.zenlabs.zenpm")
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Warnf("Foreground failed: %v — output: %s", err, string(out))
		return
	}
	log.Info("Foreground requested")
}

// handleUpdate starts the standalone updater script. It replaces the payload
// outside the running daemon while keeping the WAF open for a manual restart.
func (s *Server) handleUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	if platform.Detect() != platform.Kindle || !s.st.AllowsKindleWAF() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "self-update is only available on compatible Kindle devices"})
		return
	}
	log.Info("Starting self-update")
	args := []string{"/mnt/us/ZenPM/update.sh"}
	if r.URL.Query().Get("beta") == "1" || r.URL.Query().Get("beta") == "true" {
		args = append(args, "--beta")
	}
	cmd := exec.Command("sh", args...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Errorf("Failed to start update: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"ok": true})
}

// handleUninstall starts a detached helper that removes the running Kindle app.
func (s *Server) handleUninstall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	if platform.Detect() != platform.Kindle {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "self-uninstall is only available on Kindle"})
		return
	}
	removeSettings := r.URL.Query().Get("remove_settings") == "1" || r.URL.Query().Get("remove_settings") == "true"
	if err := maintenance.Start("uninstall", removeSettings); err != nil {
		log.Errorf("Failed to start uninstall: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"ok": true})
}
