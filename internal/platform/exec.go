package platform

import (
	"fmt"
	"os"
	"os/exec"
)

// ExecuteScript runs a shell script at the given path.
// Respects ZENPM_DRY_RUN=1 — prints intent without executing.
func ExecuteScript(scriptPath string) error {
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
	return cmd.Run()
}
