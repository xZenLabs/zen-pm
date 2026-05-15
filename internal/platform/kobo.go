package platform

import "os"

// KoboHasNickelMenu returns true if the NickelMenu config directory exists.
func KoboHasNickelMenu() bool {
	_, err := os.Stat("/mnt/onboard/.adds/nm")
	return err == nil
}
