// Package androidbackend runs ZenPM from the companion Android APK.
package androidbackend

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"ZPM/internal/log"
	"ZPM/internal/pkg"
	"ZPM/internal/platform"
	"ZPM/internal/repo"
	"ZPM/internal/server"
	"ZPM/internal/state"
)

// Version is injected when the Android shared library is built.
var Version = "dev"

var startOnce sync.Once

// Start launches the local HTTP API once for the lifetime of the Android app.
func Start(home, koreaderRoot string, port int) {
	home = strings.TrimSpace(home)
	if home == "" || port < 1 || port > 65535 {
		return
	}
	startOnce.Do(func() {
		_ = os.Setenv("ZENPM_PLATFORM", platform.Host)
		_ = os.Setenv("ZENPM_HOME", home)
		_ = os.Setenv("ZENPM_KOREADER_ROOT", strings.TrimSpace(koreaderRoot))
		go serve(port)
	})
}

func serve(port int) {
	startedAt := time.Now()
	st, err := state.Init(platform.Host)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error initializing state: %v\n", err)
		return
	}
	log.Init(st.LogFile)
	log.Infof("ZenPM %s | platform=%s | home=%s | log=%s", Version, platform.Host, st.Home, st.LogFile)
	repos := repo.New(st)
	pkgs := pkg.New(st, repos, platform.Host)
	server.Version = Version
	srv := server.New(st, repos, pkgs, port)
	srv.StartedAt = startedAt
	if err := srv.ListenAndServe(); err != nil {
		log.Errorf("Server error: %v", err)
	}
}
