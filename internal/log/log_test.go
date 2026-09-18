package log

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestBoundedLogsKeepRecentOutputAndOpenDescriptors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ZenPM.log")
	mirror := filepath.Join(t.TempDir(), "companion.log")
	t.Setenv("ZENPM_COMPANION_LOG", mirror)
	Init(path)
	defer Init("")
	for _, name := range []string{path, mirror} {
		if err := os.WriteFile(name, []byte(strings.Repeat("old\n", MaxBytes)+"recent\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	stderr, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		t.Fatal(err)
	}
	defer stderr.Close()
	Info("new message")
	stderr.WriteString("stderr still attached\n")
	for _, name := range []string{path, mirror} {
		data, err := os.ReadFile(name)
		if err != nil || len(data) > MaxBytes || !strings.Contains(string(data), "recent\n") || !strings.Contains(string(data), "new message\n") {
			t.Fatalf("log %s: bytes=%d error=%v", name, len(data), err)
		}
	}
	data, _ := os.ReadFile(path)
	if !strings.HasSuffix(string(data), "stderr still attached\n") {
		t.Fatal("compaction detached the launcher's log descriptor")
	}
	var writes sync.WaitGroup
	for range 4 {
		writes.Go(func() {
			for range 8 {
				Append(path, strings.Repeat("x", MaxBytes*2)+"\n")
			}
		})
	}
	writes.Wait()
	Info("last message")
	data, err = os.ReadFile(path)
	if err != nil || len(data) > MaxBytes || !strings.HasSuffix(string(data), "last message\n") {
		t.Fatalf("oversized/concurrent writes: bytes=%d error=%v", len(data), err)
	}
}
