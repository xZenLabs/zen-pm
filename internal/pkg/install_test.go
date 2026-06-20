package pkg

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ZPM/internal/repo"
	"ZPM/internal/state"
)

func TestInstallPassesPackageSourceEnv(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	out := filepath.Join(t.TempDir(), "env.out")
	t.Setenv("ZENPM_HOME", home)
	t.Setenv("ZENPM_STATE_BACKEND", "flat")
	t.Setenv("ZENPM_ENV_OUT", out)

	st, err := state.Init("host")
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "#!/bin/sh\n")
		io.WriteString(w, "printf '%s|%s|%s\\n' \"$ZENPM_PACKAGE_ID\" \"$ZENPM_PACKAGE_SOURCE\" \"$ZENPM_PACKAGE_SOURCE_ASSET\" > \"$ZENPM_ENV_OUT\"\n")
	}))
	defer srv.Close()

	if err := st.WriteCatalog([]state.CatalogEntry{{
		ID:          "zen-mtp-koplugin",
		Name:        "ZenMTP",
		Version:     "1.7",
		Repo:        "ZenLabs",
		InstallURL:  srv.URL,
		Source:      "https://github.com/xZenLabs/ZenMTP",
		SourceAsset: "zen_mtp.koplugin.zip",
	}}); err != nil {
		t.Fatal(err)
	}

	manager := New(st, repo.New(st), "host")
	if err := manager.Install("zen-mtp-koplugin"); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.TrimSpace(string(data))
	want := "zen-mtp-koplugin|https://github.com/xZenLabs/ZenMTP|zen_mtp.koplugin.zip"
	if got != want {
		t.Fatalf("env output = %q, want %q", got, want)
	}
}

func TestInstallEnvFallsBackToKopluginAssetPattern(t *testing.T) {
	m := &Manager{plat: "host"}
	env := m.installEnv(&repo.CatalogEntry{
		ID:         "zen-mtp-koplugin",
		InstallURL: "https://xzenlabs.github.io/repo/packages/koreader/install-plugin.sh",
		Platforms:  []string{"koreader", "kindle"},
		Source:     "https://github.com/xZenLabs/ZenMTP",
	}, "")

	got := env["ZENPM_PACKAGE_SOURCE_ASSET"]
	if got != ".koplugin.zip" {
		t.Fatalf("ZENPM_PACKAGE_SOURCE_ASSET = %q, want %q", got, ".koplugin.zip")
	}
}

func TestDisplayVersionDoesNotDoublePrefix(t *testing.T) {
	tests := map[string]string{
		"1.7":  "v1.7",
		"v1.7": "v1.7",
		"V1.7": "V1.7",
	}
	for input, want := range tests {
		if got := displayVersion(input); got != want {
			t.Fatalf("displayVersion(%q) = %q, want %q", input, got, want)
		}
	}
}
