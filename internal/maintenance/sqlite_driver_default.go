//go:build !android

package maintenance

import _ "modernc.org/sqlite"

const maintenanceSQLiteDriver = "sqlite"
