package releases

import (
	"regexp"
	"strings"
)

var releaseAssetVersion = regexp.MustCompile(`(?i)(^|[^a-z0-9])v?[0-9]+(?:[._-][0-9]+)+(?:[._-]?(?:alpha|beta|pre|preview|rc|dev|nightly)[0-9]*)?`)

type assetProfile struct {
	android bool
	desktop bool
	arch    string
}

// matchReleaseAsset first checks the exact filename (or suffix pattern), then
// accepts a version- and ABI-tolerant name match. A sole release asset is used
// as a last resort unless its name explicitly conflicts with the requested
// Android/desktop or CPU architecture build.
func matchReleaseAsset(assets []ReleaseAsset, wanted string) (ReleaseAsset, bool) {
	for _, candidate := range assets {
		if candidate.Name == wanted || (strings.HasPrefix(wanted, ".") && strings.HasSuffix(candidate.Name, wanted)) {
			return candidate, true
		}
	}

	var matches []ReleaseAsset
	for _, candidate := range assets {
		if !assetsConflict(wanted, candidate.Name) && releaseAssetIdentity(candidate.Name) == releaseAssetIdentity(wanted) {
			matches = append(matches, candidate)
		}
	}
	if len(matches) == 1 {
		return matches[0], true
	}

	if len(assets) == 1 && strings.TrimSpace(assets[0].Name) != "" && !assetsConflict(wanted, assets[0].Name) {
		return assets[0], true
	}
	return ReleaseAsset{}, false
}

func releaseAssetIdentity(name string) string {
	name = strings.ToLower(strings.TrimSpace(name))
	name = releaseAssetVersion.ReplaceAllString(name, "$1")
	name = strings.NewReplacer(
		"aarch64", "arm64",
		"armv7l", "armv7",
		"armhf", "armv7",
		"amd64", "x8664",
		"x86_64", "x8664",
		"x64", "x8664",
	).Replace(name)
	return strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			return r
		}
		return -1
	}, name)
}

func assetsConflict(wanted, candidate string) bool {
	want := profileAsset(wanted)
	got := profileAsset(candidate)

	if wantExt, gotExt := assetExtension(wanted), assetExtension(candidate); wantExt != "" && gotExt != "" && wantExt != gotExt {
		return true
	}
	if want.android != got.android {
		if (want.android && (got.desktop || got.arch != "")) || (got.android && (want.desktop || want.arch != "")) {
			return true
		}
	}
	if want.arch != "" && got.arch != "" && want.arch != got.arch {
		return true
	}
	if want.desktop != got.desktop && ((want.desktop && got.arch == "arm32") || (got.desktop && want.arch == "arm32")) {
		return true
	}
	return false
}

func assetExtension(name string) string {
	name = strings.TrimSpace(name)
	if dot := strings.LastIndex(name, "."); dot >= 0 {
		return strings.ToLower(name[dot:])
	}
	return ""
}

func profileAsset(name string) assetProfile {
	name = strings.ToLower(strings.TrimSpace(name))
	profile := assetProfile{
		android: strings.Contains(name, "android") || strings.HasSuffix(name, ".apk"),
		desktop: strings.Contains(name, "desktop") || strings.Contains(name, "windows") ||
			strings.Contains(name, "macos") || strings.Contains(name, "darwin"),
	}
	switch {
	case strings.Contains(name, "aarch64"), strings.Contains(name, "arm64"):
		profile.arch = "arm64"
	case strings.Contains(name, "armv"), strings.Contains(name, "armhf"), strings.Contains(name, "armeabi"), strings.Contains(name, "arm"):
		profile.arch = "arm32"
	case strings.Contains(name, "amd64"), strings.Contains(name, "x86_64"), strings.Contains(name, "x64"):
		profile.arch = "x8664"
	case strings.Contains(name, "i386"), strings.Contains(name, "i686"), strings.Contains(name, "x86"):
		profile.arch = "x8632"
	}
	if strings.HasPrefix(profile.arch, "x86") {
		profile.desktop = true
	}
	return profile
}
