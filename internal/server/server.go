package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"ZPM/internal/log"
	"ZPM/internal/pkg"
	"ZPM/internal/releases"
	"ZPM/internal/repo"
	"ZPM/internal/state"
)

// Version is injected at build time via ldflags or set by cmd/zenpm.
var Version = "dev"

// Server is the ZenPM HTTP API server.
type Server struct {
	st        *state.State
	repos     *repo.Manager
	pkgs      *pkg.Manager
	port      int
	StartedAt time.Time
}

type pkgJSON struct {
	ID              string          `json:"id"`
	Name            string          `json:"name"`
	Version         string          `json:"version"`
	Description     string          `json:"description"`
	Author          string          `json:"author"`
	Tags            []string        `json:"tags"`
	Category        string          `json:"category,omitempty"`
	Platforms       []string        `json:"platforms"`
	Repo            string          `json:"repo"`
	RepoTrust       string          `json:"repo_trust,omitempty"`
	RepoDefault     bool            `json:"repo_default,omitempty"`
	Installed       bool            `json:"installed"`
	InstalledVer    string          `json:"installed_version,omitempty"`
	InstalledAssets []string        `json:"installed_assets,omitempty"`
	LatestVersion   string          `json:"latest_version,omitempty"`
	UpdateAvail     bool            `json:"update_available,omitempty"`
	IconURL         string          `json:"icon_url,omitempty"`
	RepoIconURL     string          `json:"repo_icon_url,omitempty"`
	ImageURL        string          `json:"image_url,omitempty"`
	Images          []string        `json:"images,omitempty"`
	Featured        bool            `json:"featured,omitempty"`
	FeaturedImage   string          `json:"featured_image,omitempty"`
	Source          string          `json:"source,omitempty"`
	SourceType      string          `json:"source_type,omitempty"`
	SourceURL       string          `json:"source_url,omitempty"`
	Stars           string          `json:"stars,omitempty"`
	PluginModule    string          `json:"plugin_module,omitempty"`
	Assets          json.RawMessage `json:"assets,omitempty"`
	Constraints     json.RawMessage `json:"constraints,omitempty"`
}

func New(st *state.State, repos *repo.Manager, pkgs *pkg.Manager, port int) *Server {
	return &Server{st: st, repos: repos, pkgs: pkgs, port: port}
}

func (s *Server) ListenAndServe() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.wrap(s.handleHealth))
	mux.HandleFunc("/repos", s.wrap(s.handleRepos))
	mux.HandleFunc("/repos/", s.wrap(s.handleRepoByName))
	mux.HandleFunc("/repo/refresh", s.wrap(s.handleRepoRefresh))
	mux.HandleFunc("/packages", s.wrap(s.handlePackageList))
	mux.HandleFunc("/packages/", s.wrap(s.handlePackageAction))
	mux.HandleFunc("/log", s.wrap(s.handleLog))
	mux.HandleFunc("/log/client", s.wrap(s.handleClientLog))
	mux.HandleFunc("/dialog", s.wrap(s.handleDialog))
	mux.HandleFunc("/foreground", s.wrap(s.handleForeground))
	mux.HandleFunc("/update", s.wrap(s.handleUpdate))

	// Auto-refresh catalog on first start so the WAF has packages without manual refresh.
	catalog, needsRefresh := s.initialCatalogState()
	if needsRefresh {
		go func() {
			if err := s.repos.Refresh(); err != nil {
				log.Warnf("Initial refresh failed: %v", err)
			}
		}()
	} else {
		go func() {
			s.repos.CacheInstalledUninstallScripts(catalog)
		}()
	}

	// Keep the catalog fresh in the background so the client never has to fetch
	// repo manifests itself: refresh once a day for long-running daemons.
	go s.periodicRefresh()

	addr := fmt.Sprintf("127.0.0.1:%d", s.port)
	ln, err := s.listen(addr)
	if err != nil {
		return err
	}
	if !s.StartedAt.IsZero() {
		log.Infof("Timing: server listening on %s, %dms after process start", addr, time.Since(s.StartedAt).Milliseconds())
	} else {
		log.Infof("ZenPM server listening on %s", addr)
	}
	return http.Serve(ln, mux)
}

// listen binds addr, resolving the two racy port-conflict cases that arise when
// the native installer daemon and the KOReader plugin both target port 8080:
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
	for range ticker.C {
		log.Info("Periodic catalog refresh")
		if err := s.repos.Refresh(); err != nil {
			log.Warnf("Periodic refresh failed: %v", err)
		}
	}
}

// responseRecorder captures the status code written by a handler.
type responseRecorder struct {
	http.ResponseWriter
	status int
}

func (rec *responseRecorder) WriteHeader(code int) {
	rec.status = code
	rec.ResponseWriter.WriteHeader(code)
}

// wrap adds CORS headers, enforces loopback-only access, and logs every request.
func (s *Server) wrap(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		if host != "127.0.0.1" && host != "::1" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		rec := &responseRecorder{ResponseWriter: w, status: http.StatusOK}
		h(rec, r)
		if shouldLogAccess(r, rec.status) {
			log.Infof("%s %s %d", r.Method, r.URL.RequestURI(), rec.status)
		}
	}
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

func (s *Server) handlePackageList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	plat := r.URL.Query().Get("platform")
	checkUpdates := r.URL.Query().Get("check_updates") == "1" || r.URL.Query().Get("check_updates") == "true"
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
	for _, e := range installed {
		installedSet[e.ID] = true
		installedVersion[e.ID] = e.Version
	}

	patchFiles, _ := s.st.ReadInstalledPatchFiles()
	installedAssets := make(map[string][]string)
	for _, f := range patchFiles {
		installedAssets[f.PackageID] = append(installedAssets[f.PackageID], f.Asset)
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
			IconURL:       e.IconURL,
			RepoIconURL:   e.RepoIconURL,
			ImageURL:      firstString(e.Images),
			Images:        e.Images,
			Featured:      e.Featured,
			FeaturedImage: e.FeaturedImage,
			Source:        e.Source,
			SourceType:    e.SourceType,
			SourceURL:     e.SourceURL,
			Stars:         e.Stars,
			PluginModule:  e.PluginModule,
			Assets:        rawJSON(e.Assets),
			Constraints:   rawJSON(e.Constraints),
		}
		if files := installedAssets[e.ID]; len(files) > 0 {
			item.InstalledAssets = files
		}
		if item.Installed {
			item.InstalledVer = installedVersion[e.ID]
			if checkUpdates {
				applyUpdateInfo(&item)
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
				InstalledVer: e.Version,
				Platforms:    platformList,
			}
			result = append(result, item)
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

func applyUpdateInfo(item *pkgJSON) {
	if item == nil {
		return
	}
	latest := item.Version // catalog (repo) version
	if latest == "" {
		return
	}
	item.LatestVersion = latest
	base := item.InstalledVer
	if base == "" {
		base = item.Version
	}
	item.UpdateAvail = releases.VersionGreater(latest, base)
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
	// Expects: /packages/{id}/{install,uninstall,assets,readme,releases}
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
	if action == "releases" {
		s.handlePackageReleases(w, r, id)
		return
	}
	if action != "install" && action != "uninstall" {
		http.Error(w, "unknown action: "+action, http.StatusBadRequest)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	asset := r.URL.Query().Get("asset")
	releaseTag := r.URL.Query().Get("release")

	if action == "install" {
		if err := s.pkgs.CheckInstall(id); err != nil {
			log.Errorf("Package %s %s failed: %v", id, action, err)
			writeJSON(w, http.StatusConflict, map[string]interface{}{"ok": false, "error": err.Error()})
			return
		}
	}

	// Fire async; the WAF polls /log after a delay.
	log.Infof("Package %s: starting %s", id, action)
	go func() {
		var err error
		if action == "install" {
			if releaseTag != "" {
				err = s.pkgs.InstallRelease(id, releaseTag, asset)
			} else {
				err = s.pkgs.InstallAsset(id, asset)
			}
		} else {
			err = s.pkgs.Uninstall(id, asset)
		}
		if err != nil {
			log.Errorf("Package %s %s failed: %v", id, action, err)
		} else {
			log.Infof("Package %s: %s complete", id, action)
		}
	}()

	writeJSON(w, http.StatusAccepted, map[string]interface{}{"ok": true, "started": true})
}

func (s *Server) packageGitHubSource(id string) (string, error) {
	catalog, err := s.repos.ReadCatalog()
	if err != nil {
		return "", err
	}
	for _, entry := range catalog {
		if entry.ID == id {
			if _, ok := releases.GitHubRepository(entry.Source); !ok {
				return "", fmt.Errorf("package %q has no GitHub source", id)
			}
			return entry.Source, nil
		}
	}
	return "", fmt.Errorf("package %q not found", id)
}

func (s *Server) handlePackageReadme(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	source, err := s.packageGitHubSource(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	readme, err := releases.FetchGitHubReadme(source)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"readme": readme})
}

func (s *Server) handlePackageReleases(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET required", http.StatusMethodNotAllowed)
		return
	}
	source, err := s.packageGitHubSource(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	items, err := releases.FetchGitHubReleases(source, 15)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
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
	cmd := exec.Command("lipc-set-prop", "com.lab126.appmgrd", "start", "app://com.zenlabs.zenpm")
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Warnf("Foreground failed: %v — output: %s", err, string(out))
		return
	}
	log.Info("Foreground requested")
}

// handleUpdate spawns the self-update script. The script kills and restarts the
// daemon, so we fire-and-forget and return immediately.
func (s *Server) handleUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	script := "/mnt/us/ZenPM/installers/kindle/update.sh"
	if _, err := os.Stat(script); err != nil {
		log.Warnf("Update script not found: %s", script)
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "update script not found"})
		return
	}

	log.Info("Starting self-update")
	cmd := exec.Command("/bin/sh", script)
	// Detach — the script will kill and restart this process.
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Errorf("Failed to start update: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"ok": true})
}
