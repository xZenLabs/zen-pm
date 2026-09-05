package state

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/xZenLabs/zen-pm/internal/log"
)

// StartupTrace appends an Android startup diagnostic when ZENPM_STARTUP_LOG is set.
func StartupTrace(message string) {
	path := strings.TrimSpace(os.Getenv("ZENPM_STARTUP_LOG"))
	if path == "" {
		return
	}
	log.Append(path, fmt.Sprintf("%s  %s\n", time.Now().UTC().Format("2006-01-02T15:04:05Z"), message))
}
