package releases

import (
	"strconv"
	"strings"
	"unicode"
)

func NormalizeVersion(value string) string {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "refs/tags/")
	value = strings.TrimLeftFunc(value, func(r rune) bool {
		return r == 'v' || r == 'V' || (!unicode.IsDigit(r) && r != '.')
	})
	return strings.TrimSpace(value)
}

func VersionGreater(a, b string) bool {
	a = NormalizeVersion(a)
	b = NormalizeVersion(b)
	an := versionNumbers(a)
	bn := versionNumbers(b)
	if len(an) > 0 || len(bn) > 0 {
		max := len(an)
		if len(bn) > max {
			max = len(bn)
		}
		for i := 0; i < max; i++ {
			av, bv := 0, 0
			if i < len(an) {
				av = an[i]
			}
			if i < len(bn) {
				bv = bn[i]
			}
			if av > bv {
				return true
			}
			if av < bv {
				return false
			}
		}
		return false
	}
	return strings.Compare(a, b) > 0
}

func versionNumbers(value string) []int {
	var out []int
	start := -1
	for i, r := range value {
		if unicode.IsDigit(r) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			if n, err := strconv.Atoi(value[start:i]); err == nil {
				out = append(out, n)
			}
			start = -1
		}
	}
	if start >= 0 {
		if n, err := strconv.Atoi(value[start:]); err == nil {
			out = append(out, n)
		}
	}
	return out
}
