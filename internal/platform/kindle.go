package platform

import "os"

// KindleABI returns "hf" (hard-float) or "sf" (soft-float) based on the linker present.
func KindleABI() string {
	if _, err := os.Stat("/lib/ld-linux-armhf.so.3"); err == nil {
		return "hf"
	}
	return "sf"
}

// KindleHasKUAL returns true if a KUAL installation is detected.
func KindleHasKUAL() bool {
	probes := []string{
		"/mnt/us/extensions",
		"/mnt/us/documents/KUAL.sh",
		"/mnt/us/documents/KUAL-KDK-2.0.azw2",
	}
	for _, p := range probes {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}
