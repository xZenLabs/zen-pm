package readmeimages

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"image"
	"image/color"
	_ "image/gif"
	_ "image/jpeg"
	"image/png"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xZenLabs/zen-pm/internal/cabundle"
)

const (
	maxDownloadBytes = 32 * 1024 * 1024
	maxCacheBytes    = 32 * 1024 * 1024
	maxCacheFiles    = 256
	maxSourcePixels  = 12 * 1024 * 1024
	maxImageWidth    = 1200
	maxImageHeight   = 600
)

var (
	markdownImagePattern = regexp.MustCompile(`!\[[^\]]*\]\(([^\)]*)\)`)
	htmlImagePattern     = regexp.MustCompile(`(?i)<img\s+[^>]*>`)
	htmlImageSrcPattern  = regexp.MustCompile(`(?i)\bsrc\s*=\s*(?:"([^"]+)"|'([^']+)')`)
)

// Cache downloads and prepares README images outside the frontend process.
type Cache struct {
	dir         string
	client      *http.Client
	mu          sync.Mutex
	pending     map[string]bool
	allowUnsafe bool
}

func New(dir string) *Cache {
	client := cabundle.Client(20 * time.Second)
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return fmt.Errorf("stopped after 10 redirects")
		}
		if !safeHTTPSURL(req.URL) {
			return fmt.Errorf("redirect to an unsafe URL")
		}
		return nil
	}
	return &Cache{
		dir:     dir,
		client:  client,
		pending: make(map[string]bool),
	}
}

// References returns resolved HTTPS image URLs and the local ref files that
// will point at their prepared cache entries.
func (c *Cache) References(markdown, baseURL string) map[string]string {
	refs := make(map[string]string)
	for _, match := range markdownImagePattern.FindAllStringSubmatch(markdown, -1) {
		c.addReference(refs, baseURL, imageTarget(match[1]))
	}
	for _, tag := range htmlImagePattern.FindAllString(markdown, -1) {
		match := htmlImageSrcPattern.FindStringSubmatch(tag)
		if len(match) == 3 {
			target := match[1]
			if target == "" {
				target = match[2]
			}
			c.addReference(refs, baseURL, target)
		}
	}
	return refs
}

func imageTarget(value string) string {
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, "<") {
		if end := strings.Index(value, ">"); end > 1 {
			return strings.TrimSpace(value[1:end])
		}
	}
	if fields := strings.Fields(value); len(fields) > 0 {
		return fields[0]
	}
	return ""
}

func (c *Cache) addReference(refs map[string]string, baseURL, target string) {
	targetURL, err := url.Parse(strings.TrimSpace(target))
	if err != nil || targetURL.String() == "" {
		return
	}
	if !targetURL.IsAbs() {
		base, baseErr := url.Parse(strings.TrimSpace(baseURL))
		if baseErr != nil || base.Scheme == "" || base.Host == "" {
			return
		}
		targetURL = base.ResolveReference(targetURL)
	}
	if !c.urlAllowed(targetURL) {
		return
	}
	resolved := targetURL.String()
	ref := filepath.Join(c.dir, "url-"+hashString(resolved)+".ref")
	if value, _, _, failed := readRef(ref); failed {
		_ = os.Remove(ref)
	} else if value != "" && !pathWithin(c.dir, value) {
		_ = os.Remove(ref)
	}
	refs[resolved] = ref
}

func (c *Cache) urlAllowed(value *url.URL) bool {
	return c.allowUnsafe || safeHTTPSURL(value)
}

func safeHTTPSURL(value *url.URL) bool {
	if value == nil || !strings.EqualFold(value.Scheme, "https") || value.Host == "" {
		return false
	}
	host := strings.ToLower(value.Hostname())
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return !ip.IsLoopback() && !ip.IsPrivate() && !ip.IsLinkLocalUnicast() && !ip.IsUnspecified()
	}
	return true
}

// Prepare downloads and caches every unresolved reference. It is safe to call
// concurrently; a URL already being prepared is skipped.
func (c *Cache) Prepare(refs map[string]string) error {
	urls := make([]string, 0, len(refs))
	for rawURL := range refs {
		urls = append(urls, rawURL)
	}
	sort.Strings(urls)

	var failures []error
	for _, rawURL := range urls {
		ref := refs[rawURL]
		if !c.claim(rawURL, ref) {
			continue
		}
		err := c.prepareOne(rawURL, ref)
		c.release(rawURL)
		if err != nil {
			_ = writeAtomic(ref, []byte("failed\n"))
			failures = append(failures, fmt.Errorf("%s: %w", rawURL, err))
		}
	}
	c.prune()
	return errors.Join(failures...)
}

func (c *Cache) claim(rawURL, ref string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pending[rawURL] || c.cached(ref) {
		return false
	}
	c.pending[rawURL] = true
	return true
}

func (c *Cache) release(rawURL string) {
	c.mu.Lock()
	delete(c.pending, rawURL)
	c.mu.Unlock()
}

func (c *Cache) cached(ref string) bool {
	file, _, _, failed := readRef(ref)
	if failed || file == "" || !pathWithin(c.dir, file) {
		return false
	}
	info, err := os.Stat(file)
	return err == nil && info.Mode().IsRegular()
}

func (c *Cache) prepareOne(rawURL, ref string) error {
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		return fmt.Errorf("create cache: %w", err)
	}
	data, contentType, err := c.download(rawURL)
	if err != nil {
		return err
	}

	extension := ".png"
	output := data
	width, height := 0, 0
	if isSVG(data, contentType) {
		extension = ".svg"
	} else {
		output, width, height, err = resizeRaster(data)
		if err != nil {
			return err
		}
	}

	urlHash := hashString(rawURL)
	file := filepath.Join(c.dir, "image-"+urlHash+"-"+hashBytes(output)+extension)
	if _, err := os.Stat(file); os.IsNotExist(err) {
		if err := writeAtomic(file, output); err != nil {
			return fmt.Errorf("write image: %w", err)
		}
	} else if err != nil {
		return fmt.Errorf("inspect image: %w", err)
	}
	old, _, _, _ := readRef(ref)
	refValue := fmt.Sprintf("%s\t%d\t%d\n", file, width, height)
	if err := writeAtomic(ref, []byte(refValue)); err != nil {
		return fmt.Errorf("write image ref: %w", err)
	}
	if old != "" && old != file && pathWithin(c.dir, old) {
		_ = os.Remove(old)
	}
	return nil
}

func (c *Cache) download(rawURL string) ([]byte, string, error) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, "", fmt.Errorf("create request: %w", err)
	}
	if !c.urlAllowed(req.URL) {
		return nil, "", fmt.Errorf("unsafe image URL")
	}
	req.Header.Set("Accept", "image/svg+xml,image/png,image/jpeg,image/gif,*/*")
	req.Header.Set("User-Agent", "ZenPackageManager")
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("download: %w", err)
	}
	defer resp.Body.Close()
	if !c.urlAllowed(resp.Request.URL) {
		return nil, "", fmt.Errorf("download redirected to an unsafe URL")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, "", fmt.Errorf("download returned HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxDownloadBytes+1))
	if err != nil {
		return nil, "", fmt.Errorf("read image: %w", err)
	}
	if len(data) == 0 {
		return nil, "", fmt.Errorf("image is empty")
	}
	if len(data) > maxDownloadBytes {
		return nil, "", fmt.Errorf("image exceeds %d bytes", maxDownloadBytes)
	}
	return data, resp.Header.Get("Content-Type"), nil
}

func isSVG(data []byte, contentType string) bool {
	if strings.Contains(strings.ToLower(contentType), "svg") {
		return true
	}
	prefix := data
	if len(prefix) > 1024 {
		prefix = prefix[:1024]
	}
	return strings.Contains(strings.ToLower(string(prefix)), "<svg")
}

func resizeRaster(data []byte) ([]byte, int, int, error) {
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, fmt.Errorf("decode image metadata: %w", err)
	}
	if config.Width < 1 || config.Height < 1 || int64(config.Width)*int64(config.Height) > maxSourcePixels {
		return nil, 0, 0, fmt.Errorf("unsafe image dimensions %dx%d", config.Width, config.Height)
	}
	source, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, fmt.Errorf("decode image: %w", err)
	}
	width, height := boundedSize(config.Width, config.Height)
	prepared := source
	if width != config.Width || height != config.Height {
		prepared = resizeBilinear(source, width, height)
	}
	var output bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestSpeed}
	if err := encoder.Encode(&output, prepared); err != nil {
		return nil, 0, 0, fmt.Errorf("encode image: %w", err)
	}
	return output.Bytes(), width, height, nil
}

func boundedSize(width, height int) (int, int) {
	scale := math.Min(float64(maxImageWidth)/float64(width), float64(maxImageHeight)/float64(height))
	if scale >= 1 {
		return width, height
	}
	return atLeastOne(int(math.Round(float64(width) * scale))), atLeastOne(int(math.Round(float64(height) * scale)))
}

func atLeastOne(value int) int {
	if value < 1 {
		return 1
	}
	return value
}

func resizeBilinear(source image.Image, width, height int) *image.NRGBA {
	bounds := source.Bounds()
	output := image.NewNRGBA(image.Rect(0, 0, width, height))
	xScale := float64(bounds.Dx()) / float64(width)
	yScale := float64(bounds.Dy()) / float64(height)
	for y := 0; y < height; y++ {
		sy := (float64(y)+0.5)*yScale - 0.5
		y0, y1, yWeight := sampleAxis(sy, bounds.Min.Y, bounds.Max.Y-1)
		for x := 0; x < width; x++ {
			sx := (float64(x)+0.5)*xScale - 0.5
			x0, x1, xWeight := sampleAxis(sx, bounds.Min.X, bounds.Max.X-1)
			output.SetNRGBA(x, y, interpolate(
				color.NRGBAModel.Convert(source.At(x0, y0)).(color.NRGBA),
				color.NRGBAModel.Convert(source.At(x1, y0)).(color.NRGBA),
				color.NRGBAModel.Convert(source.At(x0, y1)).(color.NRGBA),
				color.NRGBAModel.Convert(source.At(x1, y1)).(color.NRGBA),
				xWeight, yWeight,
			))
		}
	}
	return output
}

func sampleAxis(value float64, minimum, maximum int) (int, int, float64) {
	if value <= float64(minimum) {
		return minimum, minimum, 0
	}
	if value >= float64(maximum) {
		return maximum, maximum, 0
	}
	lower := int(math.Floor(value))
	return lower, lower + 1, value - float64(lower)
}

func interpolate(topLeft, topRight, bottomLeft, bottomRight color.NRGBA, xWeight, yWeight float64) color.NRGBA {
	channel := func(a, b, c, d uint8) uint8 {
		top := float64(a) + (float64(b)-float64(a))*xWeight
		bottom := float64(c) + (float64(d)-float64(c))*xWeight
		return uint8(math.Round(top + (bottom-top)*yWeight))
	}
	return color.NRGBA{
		R: channel(topLeft.R, topRight.R, bottomLeft.R, bottomRight.R),
		G: channel(topLeft.G, topRight.G, bottomLeft.G, bottomRight.G),
		B: channel(topLeft.B, topRight.B, bottomLeft.B, bottomRight.B),
		A: channel(topLeft.A, topRight.A, bottomLeft.A, bottomRight.A),
	}
}

func hashString(value string) string {
	return hashBytes([]byte(value))
}

func hashBytes(value []byte) string {
	return fmt.Sprintf("%x", sha256.Sum256(value))
}

func readRef(path string) (string, int, int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", 0, 0, false
	}
	value := strings.TrimSpace(string(data))
	if value == "failed" {
		return "", 0, 0, true
	}
	parts := strings.Split(value, "\t")
	if len(parts) == 3 {
		width, widthErr := strconv.Atoi(parts[1])
		height, heightErr := strconv.Atoi(parts[2])
		if parts[0] != "" && widthErr == nil && heightErr == nil {
			return parts[0], width, height, false
		}
	}
	return value, 0, 0, false
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func pathWithin(dir, path string) bool {
	dir = filepath.Clean(dir)
	path = filepath.Clean(path)
	return path != dir && strings.HasPrefix(path, dir+string(os.PathSeparator))
}

func (c *Cache) prune() {
	entries, err := os.ReadDir(c.dir)
	if err != nil {
		return
	}
	type cachedFile struct {
		path    string
		size    int64
		modTime time.Time
	}
	var files []cachedFile
	var total int64
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "image-") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files = append(files, cachedFile{path: filepath.Join(c.dir, entry.Name()), size: info.Size(), modTime: info.ModTime()})
		total += info.Size()
	}
	sort.Slice(files, func(i, j int) bool { return files[i].modTime.Before(files[j].modTime) })
	for len(files) > maxCacheFiles || total > maxCacheBytes {
		file := files[0]
		files = files[1:]
		if os.Remove(file.path) == nil {
			total -= file.size
		}
	}
}
