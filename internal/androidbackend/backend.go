// Package androidbackend runs ZenPM from the companion Android APK.
package androidbackend

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/xZenLabs/zen-pm/internal/log"
	"github.com/xZenLabs/zen-pm/internal/pkg"
	"github.com/xZenLabs/zen-pm/internal/platform"
	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/server"
	"github.com/xZenLabs/zen-pm/internal/state"
)

// Version is injected when the Android shared library is built.
var Version = "dev"

var serverMu sync.Mutex
var serverRunning bool

// Start launches the local HTTP API unless a running instance already owns it.
func Start(home, logHome, koreaderRoot string, port int) {
	home = strings.TrimSpace(home)
	if home == "" || port < 1 || port > 65535 {
		return
	}
	serverMu.Lock()
	if serverRunning {
		serverMu.Unlock()
		writeCompanionLog(logHome, "Native backend is already starting or running.")
		return
	}
	serverRunning = true
	_ = os.Setenv("ZENPM_PLATFORM", platform.AndroidKOReader)
	_ = os.Setenv("ZENPM_HOME", home)
	_ = os.Setenv("ZENPM_KOREADER_ROOT", strings.TrimSpace(koreaderRoot))
	_ = os.Setenv("ZENPM_STARTUP_LOG", strings.TrimSpace(logHome)+"/android-companion.log")
	_ = os.Setenv("ZENPM_COMPANION_LOG", strings.TrimSpace(logHome)+"/android-companion.log")
	serverMu.Unlock()
	writeCompanionLog(logHome, fmt.Sprintf("Native backend start accepted: goarch=%s port=%d.", runtime.GOARCH, port))
	go serve(home, logHome, port)
}

func serve(home, logHome string, port int) {
	defer func() {
		serverMu.Lock()
		serverRunning = false
		serverMu.Unlock()
		writeCompanionLog(logHome, "Native backend server exited.")
	}()
	startedAt := time.Now()
	writeCompanionLog(logHome, "Native backend initializing.")
	st, err := state.Init(platform.Android)
	if err != nil {
		writeCompanionLog(logHome, fmt.Sprintf("Native backend initialization failed: %v", err))
		fmt.Fprintf(os.Stderr, "Error initializing state: %v\n", err)
		return
	}
	writeCompanionLog(logHome, "Native backend state initialized.")
	log.Init(st.LogFile)
	log.Infof("ZenPM %s | platform=%s | home=%s | log=%s", Version, platform.AndroidKOReader, st.Home, st.LogFile)
	repos := repo.New(st)
	pkgs := pkg.New(st, repos, platform.AndroidKOReader)
	server.Version = Version
	srv := server.New(st, repos, pkgs, port)
	srv.StartedAt = startedAt
	if err := srv.ListenAndServe(); err != nil {
		log.Errorf("Server error: %v", err)
		writeCompanionLog(logHome, fmt.Sprintf("Native backend stopped: %v", err))
	}
}

func writeCompanionLog(home, message string) {
	f, err := os.OpenFile(filepath.Join(home, "android-companion.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s  %s\n", time.Now().UTC().Format("2006-01-02T15:04:05Z"), message)
}
