package state

import (
	"path/filepath"
	"testing"
)

func TestResolvePersistDirUsesExplicitHome(t *testing.T) {
	home := filepath.Join(t.TempDir(), "ZenPM")
	got := resolvePersistDir("kindle", home, true)
	want := filepath.Join(home, "state")
	if got != want {
		t.Fatalf("resolvePersistDir() = %q, want %q", got, want)
	}
}

func TestResolvePersistDirUsesPlatformDefaultWithoutExplicitHome(t *testing.T) {
	got := resolvePersistDir("kindle", defaultKindleHome, false)
	if got != kindlePersistDir {
		t.Fatalf("resolvePersistDir() = %q, want %q", got, kindlePersistDir)
	}
}
