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
	"sync"
	"time"

	"ZPM/internal/log"
	"ZPM/internal/releases"
)

// CatalogEntry is the internal merged-catalog representation.
// Pipe-separated on disk:
// repo|priority|id|name|version|platforms|deps|install_url|uninstall_url|size|description|author|tags|icon_url|repo_icon_url|images|featured|featured_image|category|source|v2
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
}

func (e *CatalogEntry) CompatibleWith(platforms map[string]bool) bool {
	required := 0
	for _, pl := range e.Platforms {
		pl = normalizePlatform(pl)
		if pl == "" {
			continue
		}
		required++
		if !platforms[pl] {
			return false
		}
	}
	return required > 0
}

func (e *CatalogEntry) serialize() string {
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
		boolField(e.Featured),
		e.FeaturedImage,
		e.Category,
		e.Source,
		"v2",
	}, "|")
}

func parseCatalogLine(line string) (*CatalogEntry, error) {
	parts := strings.Split(line, "|")
	if len(parts) >= 21 && parts[20] == "v2" {
		return parseModernCatalogLine(parts)
	}
	if len(parts) >= 20 {
		return parseLegacyCatalogLine(parts)
	}
	return parseModernCatalogLine(parts)
}

func parseModernCatalogLine(parts []string) (*CatalogEntry, error) {
	if len(parts) < 10 {
		return nil, fmt.Errorf("invalid catalog line (got %d fields)", len(parts))
	}
	var priority int
	fmt.Sscanf(parts[1], "%d", &priority)
	e := &CatalogEntry{
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
	return e, nil
}

func parseLegacyCatalogLine(parts []string) (*CatalogEntry, error) {
	var priority int
	fmt.Sscanf(parts[1], "%d", &priority)
	e := &CatalogEntry{
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

func boolField(value bool) string {
	if value {
		return "featured"
	}
	return ""
}

func isFaviconURL(value string) bool {
	value = strings.ToLower(value)
	return strings.Contains(value, "favicon") || strings.HasSuffix(value, ".ico")
}

// manifestJSON mirrors the repository manifest.json schema.
type manifestJSON struct {
	SchemaVersion string `json:"schema_version"`
	Repo          struct {
		ID      string `json:"id"`
		Name    string `json:"name"`
		URL     string `json:"url"`
		IconURL string `json:"icon_url,omitempty"`
	} `json:"repo"`
	Packages []struct {
		ID            string   `json:"id"`
		Name          string   `json:"name"`
		Version       string   `json:"version"`
		Description   string   `json:"description"`
		Author        string   `json:"author"`
		Platforms     []string `json:"platforms"`
		Dependencies  []string `json:"dependencies"`
		InstallURL    string   `json:"install_url"`
		UninstallURL  string   `json:"uninstall_url"`
		Size          string   `json:"size"`
		IconURL       string   `json:"icon_url,omitempty"`
		ImageURL      string   `json:"image_url,omitempty"`
		Source        string   `json:"source,omitempty"`
		SourceAsset   string   `json:"source_asset,omitempty"`
		Featured      bool     `json:"featured,omitempty"`
		FeaturedImage string   `json:"featured_image,omitempty"`
		Category      string   `json:"category,omitempty"`
		Images        []string `json:"images,omitempty"`
		Screenshots   []string `json:"screenshots,omitempty"`
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

// FetchCatalog downloads the repo catalog, auto-detecting between ZenPM manifest.json
// and KindleForge registry.json formats.
func FetchCatalog(repoName, repoURL string, priority int, cacheDir string) ([]*CatalogEntry, error) {
	// Try ZenPM manifest.json first.
	manifestURL := joinURL(repoURL, "manifest.json")
	log.Infof("Fetching %s", manifestURL)
	data, err := fetchBytes(manifestURL)
	if err != nil {
		// Fall back to KindleForge registry.json.
		log.Infof("manifest.json failed (%v), trying registry.json", err)
		return fetchKindleForgeCatalog(repoName, repoURL, priority, cacheDir)
	}

	// Cache raw manifest for debugging.
	os.WriteFile(filepath.Join(cacheDir, "manifest-"+repoName+".json"), data, 0644)

	// Try ZenPM format first (object with "packages" key).
	var manifest manifestJSON
	if err := json.Unmarshal(data, &manifest); err == nil && len(manifest.Packages) > 0 {
		return parseZenPMCatalog(repoName, repoURL, priority, manifest), nil
	}

	// Try KindleForge format (top-level array).
	var kfEntries []kfRegistryEntry
	if err := json.Unmarshal(data, &kfEntries); err == nil && len(kfEntries) > 0 {
		return parseKindleForgeCatalog(repoName, repoURL, priority, kfEntries), nil
	}

	return nil, fmt.Errorf("unrecognized catalog format from %s", repoName)
}

// parseZenPMCatalog converts the ZenPM manifest.json format to CatalogEntry list.
func parseZenPMCatalog(repoName, repoURL string, priority int, manifest manifestJSON) []*CatalogEntry {
	repoIcon := joinURL(repoURL, "favicon.svg")
	if manifest.Repo.IconURL != "" {
		resolvedRepoIcon := resolveURL(repoURL, manifest.Repo.IconURL)
		if !isFaviconURL(resolvedRepoIcon) {
			repoIcon = resolvedRepoIcon
		}
	}
	var entries []*CatalogEntry
	for _, p := range manifest.Packages {
		iconURL := p.IconURL
		if iconURL != "" {
			iconURL = resolveURL(repoURL, iconURL)
		}
		images := resolveURLList(repoURL, appendURLLists([]string{p.ImageURL}, p.Images, p.Screenshots))
		featuredImage := ""
		if p.FeaturedImage != "" {
			featuredImage = resolveURL(repoURL, p.FeaturedImage)
		}
		source := resolveURL(repoURL, p.Source)
		entries = append(entries, &CatalogEntry{
			Repo:          repoName,
			Priority:      priority,
			ID:            p.ID,
			Name:          p.Name,
			Version:       releaseVersion(source, p.Version),
			Description:   p.Description,
			Author:        p.Author,
			Platforms:     p.Platforms,
			Deps:          p.Dependencies,
			InstallURL:    resolveURL(repoURL, p.InstallURL),
			UninstallURL:  resolveURL(repoURL, p.UninstallURL),
			Size:          p.Size,
			IconURL:       iconURL,
			RepoIconURL:   repoIcon,
			Images:        images,
			Featured:      p.Featured,
			FeaturedImage: featuredImage,
			Category:      p.Category,
			Source:        source,
		})
	}
	return entries
}

func releaseVersion(source, fallback string) string {
	if latest, err := releases.LatestGitHubReleaseTag(source); err == nil && latest != "" {
		return latest
	}
	return fallback
}

// parseKindleForgeCatalog converts the KindleForge registry.json flat array to CatalogEntry list.
func parseKindleForgeCatalog(repoName, repoURL string, priority int, entries []kfRegistryEntry) []*CatalogEntry {
	repoIcon := joinURL(repoURL, "favicon.svg")
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
			Size:         "",
			IconURL:      repoIcon,
			RepoIconURL:  repoIcon,
			Category:     kindleForgeCategory(e.Tags),
		})
	}
	return result
}

func kindleForgeCategory(tags []string) string {
	for _, tag := range tags {
		if category := categoryFromTag(tag); category != "" {
			return category
		}
	}
	return ""
}

func categoryFromTag(tag string) string {
	tag = strings.ToLower(strings.TrimSpace(tag))
	tag = strings.ReplaceAll(tag, "-", "")
	tag = strings.ReplaceAll(tag, "_", "")
	tag = strings.ReplaceAll(tag, " ", "")
	switch tag {
	case "game", "games":
		return "games"
	case "media", "audio", "music", "video", "image", "images", "photo", "photos", "comic", "comics":
		return "media"
	case "productivity", "reader", "read", "book", "books", "notes", "note", "office", "writing", "write":
		return "productivity"
	case "utility", "utilities", "tool", "tools", "system", "network", "internet", "browser", "font", "fonts":
		return "utility"
	default:
		return ""
	}
}

func appendURLLists(first []string, rest ...[]string) []string {
	out := make([]string, 0)
	for _, value := range first {
		if value != "" {
			out = append(out, value)
		}
	}
	for _, values := range rest {
		for _, value := range values {
			if value != "" {
				out = append(out, value)
			}
		}
	}
	return out
}

func resolveURLList(base string, values []string) []string {
	if len(values) == 0 {
		return nil
	}
	out := make([]string, 0, len(values))
	for _, value := range values {
		if value != "" {
			out = append(out, resolveURL(base, value))
		}
	}
	return out
}

// fetchKindleForgeCatalog fetches registry.json from the repo URL.
func fetchKindleForgeCatalog(repoName, repoURL string, priority int, cacheDir string) ([]*CatalogEntry, error) {
	regURL := joinURL(repoURL, "registry.json")
	log.Infof("Fetching KindleForge registry: %s", regURL)
	data, err := fetchBytes(regURL)
	if err != nil {
		return nil, fmt.Errorf("fetch %s: %w", regURL, err)
	}

	os.WriteFile(filepath.Join(cacheDir, "manifest-"+repoName+".json"), data, 0644)

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

// FilterByPlatform returns entries whose required platforms are all present in
// the given comma-separated platform capability filter.
// An empty platform string returns all entries.
func FilterByPlatform(entries []*CatalogEntry, platform string) []*CatalogEntry {
	if platform == "" {
		return entries
	}
	platforms := parsePlatformFilter(platform)
	if len(platforms) == 0 {
		return entries
	}
	var out []*CatalogEntry
	for _, e := range entries {
		if e.CompatibleWith(platforms) {
			out = append(out, e)
		}
	}
	return out
}

func parsePlatformFilter(platform string) map[string]bool {
	platforms := make(map[string]bool)
	for _, value := range strings.Split(platform, ",") {
		value = normalizePlatform(value)
		if value != "" {
			platforms[value] = true
		}
	}
	return platforms
}

func normalizePlatform(platform string) string {
	return strings.ToLower(strings.TrimSpace(platform))
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

// KnownPubKeyURL is the URL where the ZenLabs Ed25519 public key is hosted.
const KnownPubKeyURL = "https://xzenlabs.github.io/zenpm-key.pub"

var (
	knownRepoPubKey     ed25519.PublicKey
	knownRepoPubKeyOnce sync.Once
)

// KnownRepoPubKey fetches and returns the Ed25519 public key from KnownPubKeyURL.
// Supports PEM and raw hex formats. Cached after first successful fetch.
func KnownRepoPubKey() ed25519.PublicKey {
	knownRepoPubKeyOnce.Do(func() {
		data, err := fetchBytes(KnownPubKeyURL)
		if err != nil {
			log.Warnf("KnownRepoPubKey: fetch %s failed: %v", KnownPubKeyURL, err)
			return
		}
		// Try PEM format first.
		if key := parsePEMPubKey(string(data)); key != nil {
			knownRepoPubKey = key
			log.Infof("KnownRepoPubKey: loaded key from %s (PEM)", KnownPubKeyURL)
			return
		}
		// Try raw hex.
		trimmed := strings.TrimSpace(string(data))
		if b, err := hex.DecodeString(trimmed); err == nil && len(b) == ed25519.PublicKeySize {
			knownRepoPubKey = ed25519.PublicKey(b)
			log.Infof("KnownRepoPubKey: loaded key from %s (hex)", KnownPubKeyURL)
			return
		}
		log.Warnf("KnownRepoPubKey: unrecognized key format from %s", KnownPubKeyURL)
	})
	return knownRepoPubKey
}

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

// VerifyRepoSignature fetches manifest.json and manifest.json.sig from repoURL and verifies
// the Ed25519 signature. Returns "signed" if valid, "warn-unsigned" otherwise.
func VerifyRepoSignature(repoURL string) (string, error) {
	pk := KnownRepoPubKey()
	if pk == nil {
		log.Warnf("VerifyRepoSignature: no public key configured")
		return "warn-unsigned", fmt.Errorf("no public key configured")
	}

	manifestURL := joinURL(repoURL, "manifest.json")
	sigURL := joinURL(repoURL, "manifest.json.sig")

	manifestData, err := fetchBytes(manifestURL)
	if err != nil {
		log.Infof("VerifyRepoSignature: fetch manifest.json failed: %v", err)
		return "warn-unsigned", fmt.Errorf("fetch manifest.json: %w", err)
	}
	log.Infof("VerifyRepoSignature: fetched manifest.json (%d bytes)", len(manifestData))

	sigHex, err := fetchBytes(sigURL)
	if err != nil {
		log.Infof("VerifyRepoSignature: no manifest.json.sig: %v", err)
		return "warn-unsigned", fmt.Errorf("no manifest.json.sig: %w", err)
	}
	log.Infof("VerifyRepoSignature: fetched manifest.json.sig (%d bytes)", len(sigHex))

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

	if !ed25519.Verify(pk, manifestData, sig) {
		log.Warnf("VerifyRepoSignature: signature verification failed (manifest=%d bytes, sig=%d bytes, pubkey=%d bytes)", len(manifestData), len(sig), len(pk))
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
