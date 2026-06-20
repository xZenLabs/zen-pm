package platform

import (
	"fmt"
	"os"
	"os/exec"
)

// ExecuteScript runs a shell script at the given path.
// Respects ZENPM_DRY_RUN=1 — prints intent without executing.
func ExecuteScript(scriptPath string) error {
	return ExecuteScriptWithEnv(scriptPath, nil)
}

func ExecuteScriptWithEnv(scriptPath string, env map[string]string) error {
	if os.Getenv("ZENPM_DRY_RUN") == "1" {
		fmt.Fprintf(os.Stderr, "[DRY RUN] would execute: %s\n", scriptPath)
		return nil
	}
	if err := os.Chmod(scriptPath, 0755); err != nil {
		return fmt.Errorf("chmod %s: %w", scriptPath, err)
	}
	cmd := exec.Command("/bin/sh", scriptPath)
	cmd.Stdout = os.Stderr // script stdout goes to our log stream
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	if home, ok := lookupEnv(cmd.Env, "HOME"); !ok || home == "" {
		cmd.Env = append(cmd.Env, "HOME="+defaultHome())
	}
	for key, value := range env {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	return cmd.Run()
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

func defaultHome() string {
	switch os.Getenv("ZENPM_PLATFORM") {
	case "kindle":
		return "/mnt/us"
	case "kobo":
		return "/mnt/onboard"
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return home
	}
	return "/tmp"
}
