package platform

import (
	"os"
	"strings"
)

var (
	kindleKUALConfigPath = "/mnt/us/extensions/KUAL.cfg"
	kindleKPMDir         = "/mnt/us/kmc/kpm"
)

// KindleABI returns "hf" (hard-float) or "sf" (soft-float) based on the linker present.
func KindleABI() string {
	if _, err := os.Stat("/lib/ld-linux-armhf.so.3"); err == nil {
		return "hf"
	}
	return "sf"
}

// KindleIsCortexA9 reports whether the CPU is an ARM Cortex-A9, which needs the
// A9-optimized build (e.g. Kindle PW3/older, Voyage, KO 1st gen).
func KindleIsCortexA9() bool {
	data, err := os.ReadFile("/proc/cpuinfo")
	if err != nil {
		return false
	}
	text := strings.ToLower(string(data))
	return strings.Contains(text, "cortex-a9") || strings.Contains(text, "0xc09")
}

// KindleHasKUAL returns true if a KUAL installation is detected.
func KindleHasKUAL() bool {
	_, err := os.Stat(kindleKUALConfigPath)
	return err == nil
}

// KindleWAFAllowed reports whether the Kindle WAF may run on this device.
func KindleWAFAllowed(platformName string) bool {
	if platformName != Kindle {
		return false
	}
	if info, err := os.Stat(kindleKPMDir); err == nil && info.IsDir() {
		return false
	} else if err != nil && !os.IsNotExist(err) {
		return false
	}
	return true
}
