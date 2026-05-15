package launcher

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var unsafeRe = regexp.MustCompile(`[^a-zA-Z0-9_-]`)

func safeName(s string) string {
	return unsafeRe.ReplaceAllString(strings.ToLower(s), "_")
}

// KUALScriptletPath returns the path for a KUAL scriptlet.
func KUALScriptletPath(entryName string) string {
	return filepath.Join("/mnt/us/documents", safeName(entryName)+".sh")
}

// KUALInstallEntry writes a KUAL launcher scriptlet.
// The scriptlet must live in /mnt/us/documents/ to be visible in KUAL.
func KUALInstallEntry(name, cmd string) error {
	path := KUALScriptletPath(name)
	content := fmt.Sprintf("#!/bin/sh\n# Name: %s\n# Author: ZenPackageManager\n# DontUseFBInk\n%s\n", name, cmd)
	return os.WriteFile(path, []byte(content), 0755)
}

// KUALRemoveEntry deletes the KUAL scriptlet for the given entry name.
func KUALRemoveEntry(name string) error {
	return os.Remove(KUALScriptletPath(name))
}
