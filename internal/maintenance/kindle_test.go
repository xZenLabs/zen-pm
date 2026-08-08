package maintenance

import (
	"archive/zip"
	"database/sql"
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

func TestAppRegistration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "appreg.db")
	db, err := sql.Open(maintenanceSQLiteDriver, path)
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		"CREATE TABLE interfaces(interface TEXT PRIMARY KEY)",
		"CREATE TABLE handlerIds(handlerId TEXT PRIMARY KEY)",
		"CREATE TABLE properties(handlerId TEXT, name TEXT, value TEXT, PRIMARY KEY(handlerId, name))",
	} {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	if err := registerAppAt(path); err != nil {
		t.Fatal(err)
	}

	db, err = sql.Open(maintenanceSQLiteDriver, path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	properties := map[string]string{
		"lipcId":               kindleAppID,
		"command":              "/usr/bin/mesquite -l " + kindleAppID + " -c file://" + kindleMesquiteTarget + "/",
		"name":                 "Zen Package Manager",
		"description":          "Zen Package Manager WAF",
		"supportedOrientation": "U",
	}
	for name, want := range properties {
		var got string
		if err := db.QueryRow("SELECT value FROM properties WHERE handlerId = ? AND name = ?", kindleAppID, name).Scan(&got); err != nil {
			t.Fatalf("read property %s: %v", name, err)
		}
		if got != want {
			t.Fatalf("property %s = %q, want %q", name, got, want)
		}
	}

	if err := unregisterAppAt(path); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := db.QueryRow("SELECT COUNT(*) FROM handlerIds WHERE handlerId = ?", kindleAppID).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("handler remains after unregister: %d", count)
	}
}
