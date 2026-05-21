package server

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"

	"ZPM/internal/log"
	"ZPM/internal/pkg"
	"ZPM/internal/repo"
	"ZPM/internal/state"
)

// Version is injected at build time via ldflags or set by cmd/zenpm.
var Version = "dev"

// Server is the ZenPM HTTP API server.
type Server struct {
	st    *state.State
	repos *repo.Manager
	pkgs  *pkg.Manager
	port  int
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

	// Auto-refresh catalog on first start so the WAF has packages without manual refresh.
	if _, err := s.repos.ReadCatalog(); err != nil {
		log.Info("No catalog found — running initial repo refresh")
		go func() {
			if err := s.repos.Refresh(); err != nil {
				log.Warnf("Initial refresh failed: %v", err)
			}
		}()
	}

	addr := fmt.Sprintf("127.0.0.1:%d", s.port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", addr, err)
	}
	log.Infof("ZenPM server listening on %s", addr)
	return http.Serve(ln, mux)
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
		// Skip access logging for client log relay to avoid noise.
		if r.URL.Path != "/log/client" {
			log.Infof("%s %s %d", r.Method, r.URL.RequestURI(), rec.status)
		}
	}
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true, "version": Version})
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
		}
		result := make([]repoJSON, len(repos))
		for i, e := range repos {
			result[i] = repoJSON{Name: e.Name, URL: e.URL, Priority: e.Priority, Trust: e.Trust}
		}
		writeJSON(w, http.StatusOK, result)
	case http.MethodPost:
		var body struct {
			Name     string `json:"name"`
			URL      string `json:"url"`
			Priority int    `json:"priority"`
			Trust    string `json:"trust"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Name == "" || body.URL == "" {
			http.Error(w, "name and url required", http.StatusBadRequest)
			return
		}
		if body.Priority == 0 {
			body.Priority = 100
		}
		if body.Trust == "" {
			body.Trust = "warn-unsigned"
		}
		if err := s.repos.Add(body.Name, body.URL, body.Priority, body.Trust); err != nil {
			writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusCreated, map[string]bool{"ok": true})
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
	switch r.Method {
	case http.MethodPut:
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
	for _, e := range installed {
		installedSet[e.ID] = true
	}

	type pkgJSON struct {
		ID        string   `json:"id"`
		Name      string   `json:"name"`
		Version   string   `json:"version"`
		Platforms []string `json:"platforms"`
		Repo      string   `json:"repo"`
		Installed bool     `json:"installed"`
	}

	filtered := repo.FilterByPlatform(catalog, plat)
	result := make([]pkgJSON, 0, len(filtered))
	for _, e := range filtered {
		result = append(result, pkgJSON{
			ID: e.ID, Name: e.Name, Version: e.Version,
			Platforms: e.Platforms, Repo: e.Repo, Installed: installedSet[e.ID],
		})
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handlePackageAction(w http.ResponseWriter, r *http.Request) {
	// Expects: /packages/{id}/install  or  /packages/{id}/uninstall
	path := strings.TrimPrefix(r.URL.Path, "/packages/")
	parts := strings.SplitN(path, "/", 2)
	if len(parts) < 2 || parts[0] == "" {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	id, action := parts[0], parts[1]
	if action != "install" && action != "uninstall" {
		http.Error(w, "unknown action: "+action, http.StatusBadRequest)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	// Fire async; the WAF polls /log after a delay.
	log.Infof("Package %s: starting %s", id, action)
	go func() {
		var err error
		if action == "install" {
			err = s.pkgs.Install(id)
		} else {
			err = s.pkgs.Uninstall(id)
		}
		if err != nil {
			log.Errorf("Package %s %s failed: %v", id, action, err)
		} else {
			log.Infof("Package %s: %s complete", id, action)
		}
	}()

	writeJSON(w, http.StatusAccepted, map[string]interface{}{"ok": true, "started": true})
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

// handleClientLog receives a WAF JS log message and writes it to the server log file.
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
	log.Infof("[WAF] %s", body.Message)
	w.WriteHeader(http.StatusNoContent)
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
