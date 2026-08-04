package platform

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/xZenLabs/zen-pm/internal/log"
)

var executablePath = os.Executable

const curlShim = `#!/bin/sh
exec "$ZENPM_EXECUTABLE" script-curl "$@"
`

// ExecuteScript runs a shell script at the given path.
// Respects ZENPM_DRY_RUN=1 — prints intent without executing.
func ExecuteScript(scriptPath string) error {
	return ExecuteScriptWithEnv(scriptPath, nil)
}

func ExecuteScriptWithEnv(scriptPath string, env map[string]string) error {
	return ExecuteScriptWithEnvArgs(scriptPath, env, nil)
}

func ExecuteScriptWithEnvArgs(scriptPath string, env map[string]string, args []string) error {
	return ExecuteScriptWithEnvArgsAtDir(scriptPath, env, args, "")
}

// ExecuteScriptWithEnvAtDir runs scriptPath with dir as its working directory.
func ExecuteScriptWithEnvAtDir(scriptPath string, env map[string]string, dir string) error {
	return ExecuteScriptWithEnvArgsAtDir(scriptPath, env, nil, dir)
}

func ExecuteScriptWithEnvArgsAtDir(scriptPath string, env map[string]string, args []string, dir string) error {
	if os.Getenv("ZENPM_DRY_RUN") == "1" {
		fmt.Fprintf(os.Stderr, "[DRY RUN] would execute: %s\n", scriptPath)
		return nil
	}
	if err := os.Chmod(scriptPath, 0755); err != nil {
		return fmt.Errorf("chmod %s: %w", scriptPath, err)
	}
	cmdArgs := append([]string{scriptPath}, args...)
	cmd := exec.Command("/bin/sh", cmdArgs...)
	cmd.Dir = dir
	cmd.Env = os.Environ()
	if home, ok := lookupEnv(cmd.Env, "HOME"); !ok || home == "" {
		cmd.Env = setEnv(cmd.Env, "HOME", defaultHome())
	}
	for key, value := range env {
		cmd.Env = setEnv(cmd.Env, key, value)
	}
	if enabled, _ := lookupEnv(cmd.Env, "ZENPM_USE_GO_CURL"); enabled == "1" {
		shimEnv, cleanup, err := addCurlShim(scriptPath, cmd.Env)
		if err != nil {
			return err
		}
		defer cleanup()
		cmd.Env = shimEnv
	}
	output, err := cmd.CombinedOutput()
	logScriptOutput(scriptPath, output)
	return err
}

func addCurlShim(scriptPath string, env []string) ([]string, func(), error) {
	executable, err := executablePath()
	if err != nil {
		return nil, nil, fmt.Errorf("resolve ZenPM executable for curl shim: %w", err)
	}
	shimDir, err := os.MkdirTemp(filepath.Dir(scriptPath), ".zenpm-curl-")
	if err != nil {
		return nil, nil, fmt.Errorf("create curl shim directory: %w", err)
	}
	cleanup := func() { _ = os.RemoveAll(shimDir) }
	if err := os.WriteFile(filepath.Join(shimDir, "curl"), []byte(curlShim), 0755); err != nil {
		cleanup()
		return nil, nil, fmt.Errorf("write curl shim: %w", err)
	}
	path, _ := lookupEnv(env, "PATH")
	if path == "" {
		path = shimDir
	} else {
		path = shimDir + string(os.PathListSeparator) + path
	}
	env = setEnv(env, "PATH", path)
	env = setEnv(env, "ZENPM_EXECUTABLE", executable)
	return env, cleanup, nil
}

func logScriptOutput(scriptPath string, output []byte) {
	output = bytes.TrimSpace(output)
	if len(output) == 0 {
		return
	}
	name := filepath.Base(scriptPath)
	for _, line := range strings.Split(string(output), "\n") {
		log.Infof("[script %s] %s", name, line)
	}
}

func lookupEnv(env []string, key string) (string, bool) {
	prefix := key + "="
	for _, item := range env {
		if len(item) >= len(prefix) && item[:len(prefix)] == prefix {
			return item[len(prefix):], true
		}
	}
	return "", false
}

func setEnv(env []string, key, value string) []string {
	prefix := key + "="
	for i, item := range env {
		if strings.HasPrefix(item, prefix) {
			env[i] = prefix + value
			return env
		}
	}
	return append(env, prefix+value)
}

func defaultHome() string {
	switch strings.SplitN(os.Getenv("ZENPM_PLATFORM"), ",", 2)[0] {
	case "kindle":
		return "/mnt/base-us"
	case "kobo":
		return "/mnt/onboard/.adds"
	case "pocketbook":
		return "/mnt/ext1/applications"
	case "android":
		return "/sdcard"
	}
	return "/tmp"
}
