package launcher

import (
	"fmt"
	"os"
	"path/filepath"
)

func nickelMenuDir() string {
	if d := os.Getenv("ZENPM_NM_CONFIG_DIR"); d != "" {
		return d
	}
	return "/mnt/onboard/.adds/nm"
}

// NickelMenuEntryPath returns the config file path for a zenpm-managed NickelMenu entry.
func NickelMenuEntryPath(id string) string {
	return filepath.Join(nickelMenuDir(), "zenpm-"+safeName(id))
}

// NickelMenuWriteEntry writes a NickelMenu cmd_spawn entry.
// location is the menu location, e.g. "main" or "reader".
func NickelMenuWriteEntry(id, label, cmd, location string) error {
	if location == "" {
		location = "main"
	}
	path := NickelMenuEntryPath(id)
	content := fmt.Sprintf("menu_item:%s:%s:cmd_spawn:quiet:%s\n", location, label, cmd)
	return os.WriteFile(path, []byte(content), 0644)
}

// NickelMenuRemoveEntry deletes the NickelMenu entry for the given id.
func NickelMenuRemoveEntry(id string) error {
	return os.Remove(NickelMenuEntryPath(id))
}
