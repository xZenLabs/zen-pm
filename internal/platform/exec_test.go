package platform

import (
	"os"
	"path/filepath"
	"testing"
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
