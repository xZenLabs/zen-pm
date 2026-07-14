package state

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// StartupTrace appends an Android startup diagnostic when ZENPM_STARTUP_LOG is set.
func StartupTrace(message string) {
	path := strings.TrimSpace(os.Getenv("ZENPM_STARTUP_LOG"))
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s  %s\n", time.Now().UTC().Format("2006-01-02T15:04:05Z"), message)
}
