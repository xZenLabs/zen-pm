//go:build !android

package state

import _ "modernc.org/sqlite"

const sqliteDriver = "sqlite"
