package platform

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xZenLabs/zen-pm/internal/log"
)

func TestScriptOutputStreamsBeforeExitAndStaysBounded(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "zenpm.log")
	log.Init(logPath)
	defer log.Init("")
	releasePath := filepath.Join(dir, "release")
	scriptPath := filepath.Join(dir, "script.sh")
	script := "#!/bin/sh\necho streaming\nwhile [ ! -f \"$ZENPM_TEST_RELEASE\" ]; do sleep 0.01; done\nhead -c 3145728 /dev/zero | tr '\\000' x\necho final-message >&2\nexit 7\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0644); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		done <- ExecuteScriptWithEnv(scriptPath, map[string]string{"ZENPM_TEST_RELEASE": releasePath})
	}()
	streamed := false
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		data, _ := os.ReadFile(logPath)
		if strings.Contains(string(data), "streaming") {
			streamed = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := os.WriteFile(releasePath, nil, 0644); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err == nil {
		t.Fatal("lost the script's nonzero exit status")
	}
	if !streamed {
		t.Fatal("output was buffered until the script exited")
	}
	data, err := os.ReadFile(logPath)
	if err != nil || len(data) > log.MaxBytes || !strings.Contains(string(data), "final-message") {
		t.Fatalf("log bytes=%d error=%v", len(data), err)
	}
}

func TestExecuteScriptWithEnvSetsFallbackHome(t *testing.T) {
	oldHome, hadHome := os.LookupEnv("HOME")
	os.Unsetenv("HOME")
	defer func() {
		if hadHome {
			os.Setenv("HOME", oldHome)
		} else {
			os.Unsetenv("HOME")
		}
	}()
	t.Setenv("ZENPM_PLATFORM", "kindle")

	scriptPath := filepath.Join(t.TempDir(), "script.sh")
	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\nset -eu\n: \"$HOME\"\n"), 0644); err != nil {
		t.Fatal(err)
	}

	if err := ExecuteScriptWithEnv(scriptPath, nil); err != nil {
		t.Fatalf("ExecuteScriptWithEnv() error = %v", err)
	}
}

func TestExecuteScriptWithEnvLogsScriptOutput(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "zenpm.log")
	log.Init(logPath)
	defer log.Init("")

	scriptPath := filepath.Join(t.TempDir(), "script.sh")
	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\necho uninstall detail\n"), 0644); err != nil {
		t.Fatal(err)
	}

	if err := ExecuteScriptWithEnv(scriptPath, nil); err != nil {
		t.Fatalf("ExecuteScriptWithEnv() error = %v", err)
	}

	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	got := string(data)
	if !strings.Contains(got, "[script script.sh] uninstall detail") {
		t.Fatalf("log = %q, want script output", got)
	}
}

func TestExecuteScriptWithEnvRoutesCurlThroughZenPM(t *testing.T) {
	dir := t.TempDir()
	argsPath := filepath.Join(dir, "args")
	fakeExecutable := filepath.Join(dir, "zenpm")
	if err := os.WriteFile(fakeExecutable, []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$ZENPM_TEST_ARGS\"\n"), 0755); err != nil {
		t.Fatal(err)
	}
	originalExecutablePath := executablePath
	executablePath = func() (string, error) { return fakeExecutable, nil }
	defer func() { executablePath = originalExecutablePath }()

	scriptPath := filepath.Join(dir, "script.sh")
	script := "#!/bin/sh\ncurl -fSL --progress-bar -o /tmp/output https://example.test/asset\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0644); err != nil {
		t.Fatal(err)
	}
	if err := ExecuteScriptWithEnv(scriptPath, map[string]string{
		"ZENPM_USE_GO_CURL": "1",
		"ZENPM_TEST_ARGS":   argsPath,
	}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	want := "script-curl -fSL --progress-bar -o /tmp/output https://example.test/asset"
	if got := strings.TrimSpace(string(data)); got != want {
		t.Fatalf("shim args = %q, want %q", got, want)
	}
}

func TestDefaultHomeMatchesKOReaderPluginParents(t *testing.T) {
	tests := map[string]string{
		"kobo":             "/mnt/onboard/.adds",
		"kindle":           "/mnt/base-us",
		"pocketbook":       "/mnt/ext1/applications",
		"android":          "/sdcard",
		"android,koreader": "/sdcard",
		"host":             "/tmp",
		"":                 "/tmp",
	}
	for platform, want := range tests {
		t.Setenv("ZENPM_PLATFORM", platform)
		if got := defaultHome(); got != want {
			t.Fatalf("defaultHome() for %q = %q, want %q", platform, got, want)
		}
	}
}
