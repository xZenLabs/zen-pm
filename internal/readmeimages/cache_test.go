package readmeimages

import (
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReferencesResolvesMarkdownAndHTMLImages(t *testing.T) {
	cache := New(t.TempDir())
	refs := cache.References(`![First](images/first.png "title")
<img alt="Second" src='../shared/second.svg'>
![Ignored](http://example.invalid/insecure.png)
![Private](https://127.0.0.1/private.png)`, "https://example.invalid/packages/demo/")

	for _, rawURL := range []string{
		"https://example.invalid/packages/demo/images/first.png",
		"https://example.invalid/packages/shared/second.svg",
	} {
		ref := refs[rawURL]
		if filepath.Dir(ref) != cache.dir || filepath.Ext(ref) != ".ref" {
			t.Fatalf("reference for %s = %q", rawURL, ref)
		}
	}
	if len(refs) != 2 {
		t.Fatalf("references = %#v", refs)
	}
}

func TestPrepareDownloadsResizesAndCachesRasterImage(t *testing.T) {
	var downloads int
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		downloads++
		w.Header().Set("Content-Type", "image/png")
		input := image.NewNRGBA(image.Rect(0, 0, 2000, 1000))
		input.SetNRGBA(0, 0, color.NRGBA{R: 255, A: 255})
		if err := png.Encode(w, input); err != nil {
			t.Fatal(err)
		}
	}))
	defer server.Close()

	cache := New(filepath.Join(t.TempDir(), "cache with spaces"))
	cache.client = server.Client()
	cache.allowUnsafe = true
	refs := cache.References("![Large]("+server.URL+"/large.png)", "https://example.invalid/")
	if err := cache.Prepare(refs); err != nil {
		t.Fatal(err)
	}

	ref := refs[server.URL+"/large.png"]
	file, width, height, failed := readRef(ref)
	if failed || file == "" {
		t.Fatalf("prepared ref = %q, failed=%v", file, failed)
	}
	if width != 1200 || height != 600 {
		t.Fatalf("prepared ref dimensions = %dx%d", width, height)
	}
	handle, err := os.Open(file)
	if err != nil {
		t.Fatal(err)
	}
	config, format, err := image.DecodeConfig(handle)
	handle.Close()
	if err != nil {
		t.Fatal(err)
	}
	if format != "png" || config.Width != 1200 || config.Height != 600 {
		t.Fatalf("prepared image = %s %dx%d", format, config.Width, config.Height)
	}

	if err := cache.Prepare(refs); err != nil {
		t.Fatal(err)
	}
	if downloads != 1 {
		t.Fatalf("downloads = %d, want cached image to avoid second request", downloads)
	}
}

func TestPrepareReportsEveryFailureInURLOrder(t *testing.T) {
	cache := New(t.TempDir())
	refs := map[string]string{
		"http://example.invalid/second.png": filepath.Join(cache.dir, "second.ref"),
		"http://example.invalid/first.png":  filepath.Join(cache.dir, "first.ref"),
	}
	err := cache.Prepare(refs)
	if err == nil {
		t.Fatal("Prepare() error = nil")
	}
	want := strings.Join([]string{
		"http://example.invalid/first.png: unsafe image URL",
		"http://example.invalid/second.png: unsafe image URL",
	}, "\n")
	if err.Error() != want {
		t.Fatalf("Prepare() error = %q, want %q", err, want)
	}
}
