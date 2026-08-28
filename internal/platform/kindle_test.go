package platform

import (
	"os"
	"path/filepath"
	"testing"
)

func TestKindleHasKUALChecksConfigFile(t *testing.T) {
	old := kindleKUALConfigPath
	defer func() { kindleKUALConfigPath = old }()

	path := filepath.Join(t.TempDir(), "KUAL.cfg")
	kindleKUALConfigPath = path

	if KindleHasKUAL() {
		t.Fatal("KindleHasKUAL returned true before KUAL.cfg existed")
	}
	if err := os.WriteFile(path, []byte("kual"), 0644); err != nil {
		t.Fatal(err)
	}
	if !KindleHasKUAL() {
		t.Fatal("KindleHasKUAL returned false after KUAL.cfg was created")
	}
}

func TestKindleWAFAllowed(t *testing.T) {
	if KindleWAFAllowed(Host) {
		t.Fatal("KindleWAFAllowed returned true for host")
	}
	if !KindleWAFAllowed(Kindle) {
		t.Fatal("KindleWAFAllowed returned false for Kindle")
	}
	if !KindleWAFAllowed(Kindle + ",koreader") {
		t.Fatal("KindleWAFAllowed returned false for Kindle KOReader")
	}
}
