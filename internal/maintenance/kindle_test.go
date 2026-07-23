package maintenance

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExtractZipRejectsPathTraversal(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "update.zip")
	file, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	entry, err := writer.Create("../outside")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte("bad")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	if err := extractZip(archive, filepath.Join(t.TempDir(), "payload")); err == nil {
		t.Fatal("extractZip accepted a path traversal entry")
	}
}

func TestReadVersion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "VERSION")
	if err := os.WriteFile(path, []byte("v1.2.3\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if got := readVersion(path); got != "1.2.3" {
		t.Fatalf("readVersion = %q, want 1.2.3", got)
	}
}

func TestWriteCLIWrappers(t *testing.T) {
	payload := filepath.Join(t.TempDir(), "ZenPM")
	if err := writeCLIWrappers(payload); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"zenpm", "zpm"} {
		path := filepath.Join(payload, "bin", name)
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		want := "exec \"" + filepath.Join(payload, "backend", "zenpm") + "\" \"$@\""
		if !strings.Contains(string(data), want) {
			t.Fatalf("%s = %q, want %q", name, data, want)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode()&0111 == 0 {
			t.Fatalf("%s is not executable: %v", name, info.Mode())
		}
	}
}
