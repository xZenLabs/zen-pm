package repo

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"ZPM/internal/log"
)

// CatalogEntry is the internal merged-catalog representation.
// Pipe-separated on disk (15 fields): repo|priority|id|name|version|platforms|deps|install_url|uninstall_url|manifest_url|sha256|size|description|author|tags
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
	Description  string
	Author       string
	Tags         []string
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
		e.Description, e.Author,
		strings.Join(e.Tags, ","),
	}, "|")
}

func parseCatalogLine(line string) (*CatalogEntry, error) {
	parts := strings.SplitN(line, "|", 15)
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
	if len(parts) >= 13 {
		e.Description = parts[12]
	}
	if len(parts) >= 14 {
		e.Author = parts[13]
	}
	if len(parts) >= 15 && parts[14] != "" {
		e.Tags = strings.Split(parts[14], ",")
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
		Description  string   `json:"description"`
		Author       string   `json:"author"`
		Platforms    []string `json:"platforms"`
		Dependencies []string `json:"dependencies"`
		InstallURL   string   `json:"install_url"`
		UninstallURL string   `json:"uninstall_url"`
		SHA256       string   `json:"sha256"`
		Size         string   `json:"size"`
	} `json:"packages"`
}

// kfRegistryEntry mirrors the KindleForge registry.json format (flat JSON array).
type kfRegistryEntry struct {
	Name         string   `json:"name"`
	URI          string   `json:"uri"`
	Description  string   `json:"description"`
	Author       string   `json:"author"`
	ABI          []string `json:"ABI"`
	Dependencies []string `json:"dependencies"`
	Tags         []string `json:"tags"`
}

// FetchCatalog downloads the repo catalog, auto-detecting between ZenPM index.json
// and KindleForge registry.json formats.
func FetchCatalog(repoName, repoURL string, priority int, cacheDir string) ([]*CatalogEntry, error) {
	// Try ZenPM index.json first.
	indexURL := joinURL(repoURL, "index.json")
	log.Infof("Fetching %s", indexURL)
	data, err := fetchBytes(indexURL)
	if err != nil {
		// Fall back to KindleForge registry.json.
		log.Infof("index.json failed (%v), trying registry.json", err)
		return fetchKindleForgeCatalog(repoName, repoURL, priority, cacheDir)
	}

	// Cache raw index for debugging.
	os.WriteFile(filepath.Join(cacheDir, "index-"+repoName+".json"), data, 0644)

	// Try ZenPM format first (object with "packages" key).
	var idx indexJSON
	if err := json.Unmarshal(data, &idx); err == nil && len(idx.Packages) > 0 {
		return parseZenPMCatalog(repoName, repoURL, priority, idx), nil
	}

	// Try KindleForge format (top-level array).
	var kfEntries []kfRegistryEntry
	if err := json.Unmarshal(data, &kfEntries); err == nil && len(kfEntries) > 0 {
		return parseKindleForgeCatalog(repoName, repoURL, priority, kfEntries), nil
	}

	return nil, fmt.Errorf("unrecognized catalog format from %s", repoName)
}

// parseZenPMCatalog converts the ZenPM index.json format to CatalogEntry list.
func parseZenPMCatalog(repoName, repoURL string, priority int, idx indexJSON) []*CatalogEntry {
	var entries []*CatalogEntry
	for _, p := range idx.Packages {
		entries = append(entries, &CatalogEntry{
			Repo:         repoName,
			Priority:     priority,
			ID:           p.ID,
			Name:         p.Name,
			Version:      p.Version,
			Description:  p.Description,
			Author:       p.Author,
			Platforms:    p.Platforms,
			Deps:         p.Dependencies,
			InstallURL:   resolveURL(repoURL, p.InstallURL),
			UninstallURL: resolveURL(repoURL, p.UninstallURL),
			SHA256:       p.SHA256,
			Size:         p.Size,
		})
	}
	return entries
}

// parseKindleForgeCatalog converts the KindleForge registry.json flat array to CatalogEntry list.
func parseKindleForgeCatalog(repoName, repoURL string, priority int, entries []kfRegistryEntry) []*CatalogEntry {
	var result []*CatalogEntry
	for _, e := range entries {
		if e.URI == "" {
			continue
		}
		result = append(result, &CatalogEntry{
			Repo:         repoName,
			Priority:     priority,
			ID:           e.URI,
			Name:         e.Name,
			Version:      "0.0.0", // KindleForge registry has no version field
			Description:  e.Description,
			Author:       e.Author,
			Tags:         e.Tags,
			Platforms:    []string{"kindle"}, // KindleForge is Kindle-only
			Deps:         e.Dependencies,
			InstallURL:   resolveURL(repoURL, e.URI+"/install.sh"),
			UninstallURL: resolveURL(repoURL, e.URI+"/uninstall.sh"),
			ManifestURL:  "",
			SHA256:       "",
			Size:         "",
		})
	}
	return result
}

// fetchKindleForgeCatalog fetches registry.json from the repo URL.
func fetchKindleForgeCatalog(repoName, repoURL string, priority int, cacheDir string) ([]*CatalogEntry, error) {
	regURL := joinURL(repoURL, "registry.json")
	log.Infof("Fetching KindleForge registry: %s", regURL)
	data, err := fetchBytes(regURL)
	if err != nil {
		return nil, fmt.Errorf("fetch %s: %w", regURL, err)
	}

	os.WriteFile(filepath.Join(cacheDir, "index-"+repoName+".json"), data, 0644)

	var entries []kfRegistryEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("parse registry.json from %s: %w", repoName, err)
	}
	log.Infof("KindleForge registry %s: %d packages", repoName, len(entries))
	return parseKindleForgeCatalog(repoName, repoURL, priority, entries), nil
}
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

// KnownRepoPubKey is the Ed25519 public key used to verify index.json.sig.
// Defaults to the ZenLabs repo signing key. Override via ZENPM_REPO_PUBKEY env var
// (hex-encoded 32-byte Ed25519 key).
var KnownRepoPubKey = func() ed25519.PublicKey {
	if key := os.Getenv("ZENPM_REPO_PUBKEY"); key != "" {
		b, err := hex.DecodeString(key)
		if err == nil && len(b) == ed25519.PublicKeySize {
			return ed25519.PublicKey(b)
		}
	}
	return parsePEMPubKey(zenLabsPubKeyPEM)
}()

// zenLabsPubKeyPEM is the ZenLabs repo Ed25519 public key in PKIX/SPKI PEM format.
const zenLabsPubKeyPEM = `-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAsWdhAiVzFSIr8yYgFRHWWwAp2NAh/WKXMqaOkYXVN3k=
-----END PUBLIC KEY-----`

func parsePEMPubKey(pemData string) ed25519.PublicKey {
	block, _ := pem.Decode([]byte(pemData))
	if block == nil {
		return nil
	}
	pub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil
	}
	edKey, ok := pub.(ed25519.PublicKey)
	if !ok {
		return nil
	}
	return edKey
}

// VerifyRepoSignature fetches index.json and index.json.sig from repoURL and verifies
// the Ed25519 signature. Returns "signed" if valid, "warn-unsigned" otherwise.
func VerifyRepoSignature(repoURL string) (string, error) {
	if KnownRepoPubKey == nil {
		log.Warnf("VerifyRepoSignature: no public key configured")
		return "warn-unsigned", fmt.Errorf("no public key configured")
	}

	indexURL := joinURL(repoURL, "index.json")
	sigURL := joinURL(repoURL, "index.json.sig")

	indexData, err := fetchBytes(indexURL)
	if err != nil {
		log.Infof("VerifyRepoSignature: fetch index.json failed: %v", err)
		return "warn-unsigned", fmt.Errorf("fetch index.json: %w", err)
	}
	log.Infof("VerifyRepoSignature: fetched index.json (%d bytes)", len(indexData))

	sigHex, err := fetchBytes(sigURL)
	if err != nil {
		log.Infof("VerifyRepoSignature: no index.json.sig: %v", err)
		return "warn-unsigned", fmt.Errorf("no index.json.sig: %w", err)
	}
	log.Infof("VerifyRepoSignature: fetched index.json.sig (%d bytes)", len(sigHex))

	// The .sig file may be raw binary (64-byte Ed25519 signature) or hex-encoded.
	// Try raw binary first — it's the standard openssl pkeyutl output.
	var sig []byte
	raw := sigHex
	// Trim trailing newline that some editors add to binary files.
	if len(raw) > 0 && raw[len(raw)-1] == '\n' {
		raw = raw[:len(raw)-1]
	}
	if len(raw) == ed25519.SignatureSize {
		sig = raw
		log.Infof("VerifyRepoSignature: using raw binary signature")
	} else {
		// Fall back to hex-encoded.
		sigStr := strings.TrimSpace(string(sigHex))
		var err error
		sig, err = hex.DecodeString(sigStr)
		if err != nil {
			preview := sigStr
			if len(preview) > 40 {
				preview = preview[:40]
			}
			log.Warnf("VerifyRepoSignature: invalid sig (len=%d preview=%q): %v", len(sigStr), preview, err)
			return "warn-unsigned", fmt.Errorf("invalid signature: %w", err)
		}
		log.Infof("VerifyRepoSignature: using hex-encoded signature")
	}

	if len(sig) != ed25519.SignatureSize {
		log.Warnf("VerifyRepoSignature: sig wrong size: got %d, want %d", len(sig), ed25519.SignatureSize)
		return "warn-unsigned", fmt.Errorf("sig wrong size: %d", len(sig))
	}

	if !ed25519.Verify(KnownRepoPubKey, indexData, sig) {
		log.Warnf("VerifyRepoSignature: signature verification failed (index=%d bytes, sig=%d bytes, pubkey=%d bytes)", len(indexData), len(sig), len(KnownRepoPubKey))
		return "warn-unsigned", fmt.Errorf("signature verification failed")
	}

	log.Infof("VerifyRepoSignature: signature valid")
	return "signed", nil
}

// CheckRepoURLSafety verifies the repo URL uses HTTPS. Returns a warning message
// for plain-HTTP URLs (excluding localhost and file://), or empty string if safe.
func CheckRepoURLSafety(repoURL string) string {
	if strings.HasPrefix(repoURL, "https://") || strings.HasPrefix(repoURL, "file://") {
		return ""
	}
	if strings.HasPrefix(repoURL, "http://") {
		u, err := url.Parse(repoURL)
		if err != nil {
			return "cannot parse repo URL"
		}
		host := u.Hostname()
		if host == "127.0.0.1" || host == "localhost" || host == "::1" {
			return ""
		}
		return "repo URL uses plain HTTP — consider using HTTPS for security"
	}
	return ""
}
