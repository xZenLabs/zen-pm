package platform

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ZPM/internal/log"
)

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

func TestDefaultHomeMatchesKOReaderPluginParents(t *testing.T) {
	tests := map[string]string{
		"kobo":       "/mnt/onboard/.adds",
		"kindle":     "/mnt/base-us",
		"pocketbook": "/mnt/ext1/applications",
		"android":    "/sdcard",
		"host":       "/tmp",
		"":           "/tmp",
	}
	for platform, want := range tests {
		t.Setenv("ZENPM_PLATFORM", platform)
		if got := defaultHome(); got != want {
			t.Fatalf("defaultHome() for %q = %q, want %q", platform, got, want)
		}
	}
}
