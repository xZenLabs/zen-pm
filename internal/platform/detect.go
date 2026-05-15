package platform

import "os"

const (
	Kindle = "kindle"
	Kobo   = "kobo"
	Host   = "host"
)

// Detect returns the current platform. Can be overridden via ZENPM_PLATFORM env var.
func Detect() string {
	if p := os.Getenv("ZENPM_PLATFORM"); p != "" {
		return p
	}
	// Kindle: has /mnt/us and appreg.db
	if _, err := os.Stat("/mnt/us"); err == nil {
		if _, err := os.Stat("/var/local/appreg.db"); err == nil {
			return Kindle
		}
	}
	// Kobo: has .kobo marker
	if _, err := os.Stat("/mnt/onboard/.kobo"); err == nil {
		return Kobo
	}
	return Host
}
