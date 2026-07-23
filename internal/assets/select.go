// Package assets chooses the right release asset for the current device.
package assets

import (
	"encoding/json"
	"strings"
)

// Asset mirrors one entry of a catalog package's "assets" array.
type Asset struct {
	Arch  string `json:"arch"`
	Asset string `json:"asset"`
	URL   string `json:"url"`
	Size  string `json:"size"`
}

// Device describes the running hardware used to pick an asset.
type Device struct {
	Platform string // "kindle", "kobo", "pocketbook", "remarkable", "android", "host", ...
	OS       string // host OS, for example "darwin" (only meaningful on host)
	KindleHF bool   // hard-float linker present (only meaningful on kindle)
	CortexA9 bool   // ARM Cortex-A9 CPU (needs A9-optimized build)
}

// Result is the outcome of asset selection.
type Result struct {
	Auto        string  // chosen asset filename, "" when undecided
	Candidates  []Asset // assets to offer the user when NeedsChoice
	NeedsChoice bool    // true when the user must pick
}

// Parse decodes the raw "assets" JSON. Returns nil for empty/invalid input.
func Parse(raw string) []Asset {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "null" {
		return nil
	}
	var out []Asset
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil
	}
	cleaned := out[:0]
	for _, a := range out {
		if strings.TrimSpace(a.Asset) != "" {
			cleaned = append(cleaned, a)
		}
	}
	return cleaned
}

func name(a Asset) string { return strings.ToLower(strings.TrimSpace(a.Asset)) }

func isMacOS(n string) bool {
	return strings.Contains(n, "macos") || strings.Contains(n, "darwin")
}

// excluded filters assets that do not apply to the current device.
func excluded(dev Device, a Asset) bool {
	n := name(a)
	for _, bad := range []string{".apk", ".exe", ".dmg", "windows"} {
		if strings.Contains(n, bad) {
			return true
		}
	}
	if dev.OS != "darwin" && isMacOS(n) {
		return true
	}
	if dev.Platform != "host" && (strings.Contains(n, "desktop") || strings.Contains(n, "linux-x86")) {
		return true
	}
	// Only Android devices want the android build.
	if dev.Platform != "android" && strings.Contains(n, "android") {
		return true
	}
	return false
}

func isPlainKindle(n string) bool {
	return strings.Contains(n, "kindle") &&
		!strings.Contains(n, "a9") &&
		!strings.Contains(n, "hf") &&
		!strings.Contains(n, "android")
}

// Select picks the best asset for dev, or flags that the user must choose.
func Select(raw string, dev Device) Result {
	all := Parse(raw)
	if len(all) == 0 {
		return Result{}
	}

	var cands []Asset
	for _, a := range all {
		if !excluded(dev, a) {
			cands = append(cands, a)
		}
	}
	if len(cands) == 0 {
		cands = all
	}
	if len(cands) == 1 {
		return Result{Auto: cands[0].Asset}
	}

	find := func(pred func(string) bool) string {
		for _, a := range cands {
			if pred(name(a)) {
				return a.Asset
			}
		}
		return ""
	}

	var pick string
	switch dev.Platform {
	case "kindle":
		if dev.CortexA9 {
			pick = find(func(n string) bool { return strings.Contains(n, "a9") })
		}
		if pick == "" && dev.KindleHF {
			pick = find(func(n string) bool { return strings.Contains(n, "hf") })
		}
		if pick == "" {
			pick = find(isPlainKindle)
		}
	case "android":
		pick = find(func(n string) bool { return strings.Contains(n, "android") })
	case "host":
		if dev.OS == "darwin" {
			pick = find(isMacOS)
		}
		if pick == "" {
			pick = find(func(n string) bool { return strings.Contains(n, "desktop") })
		}
	default:
		// Kobo, PocketBook, reMarkable and other ARM e-readers use the plain Kindle build.
		pick = find(isPlainKindle)
	}

	if pick != "" {
		return Result{Auto: pick}
	}
	return Result{Candidates: cands, NeedsChoice: true}
}
