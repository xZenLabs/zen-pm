package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/xZenLabs/zen-pm/internal/log"
	"github.com/xZenLabs/zen-pm/internal/maintenance"
	"github.com/xZenLabs/zen-pm/internal/pkg"
	"github.com/xZenLabs/zen-pm/internal/platform"
	"github.com/xZenLabs/zen-pm/internal/repo"
	"github.com/xZenLabs/zen-pm/internal/server"
	"github.com/xZenLabs/zen-pm/internal/state"
)

// version is injected via -ldflags "-X main.version=X.Y.Z" at build time.
var version = "dev"

func main() {
	startedAt := time.Now()
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	plat := platform.Detect()
	initStart := time.Now()
	st, err := state.Init(plat)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error initializing state: %v\n", err)
		os.Exit(1)
	}
	log.Init(st.LogFile)
	log.Infof("ZenPM %s | platform=%s | home=%s | log=%s", version, plat, st.Home, st.LogFile)
	log.Infof("Timing: state.Init took %dms (process %dms in)", time.Since(initStart).Milliseconds(), time.Since(startedAt).Milliseconds())
	if st.SeededRepoURL != "" {
		log.Infof("Seeded default repo: %s", st.SeededRepoURL)
	}

	repos := repo.New(st)
	pkgs := pkg.New(st, repos, plat)

	switch os.Args[1] {
	case "maintenance":
		runMaintenance(os.Args[2:])
	case "repo":
		runRepo(repos, os.Args[2:])
	case "list", "info", "install", "uninstall", "update":
		runPackage(st, repos, pkgs, plat, os.Args[1:])
	case "package":
		runPackage(st, repos, pkgs, plat, os.Args[2:])
	case "doctor":
		runDoctor(st, plat)
	case "logs":
		runLogs(st, os.Args[2:])
	case "serve":
		runServe(st, repos, pkgs, startedAt, os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", os.Args[1])
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "Usage: zenpm <command> [args]")
	fmt.Fprintln(os.Stderr, "Commands:")
	fmt.Fprintln(os.Stderr, "  repo    list|add|remove|refresh")
	fmt.Fprintln(os.Stderr, "  list    [platform|installed]")
	fmt.Fprintln(os.Stderr, "  info    <id>")
	fmt.Fprintln(os.Stderr, "  install <id>")
	fmt.Fprintln(os.Stderr, "  uninstall <id> [patch-file]")
	fmt.Fprintln(os.Stderr, "  update  [id]")
	fmt.Fprintln(os.Stderr, "  doctor")
	fmt.Fprintln(os.Stderr, "  logs    [--tail N]")
	fmt.Fprintln(os.Stderr, "  serve   [--port PORT]")
	fmt.Fprintln(os.Stderr, "  maintenance update|uninstall [--parent-pid PID] [--remove-settings]")
}

func runMaintenance(args []string) {
	if len(args) == 0 {
		die("Usage: zenpm maintenance <update|uninstall> [--parent-pid PID] [--remove-settings]")
	}
	parentPID := 0
	removeSettings := false
	for _, arg := range args[1:] {
		switch {
		case arg == "--remove-settings":
			removeSettings = true
		case strings.HasPrefix(arg, "--parent-pid="):
			value := strings.TrimPrefix(arg, "--parent-pid=")
			var err error
			parentPID, err = strconv.Atoi(value)
			if err != nil || parentPID < 1 {
				die("--parent-pid must be a positive integer")
			}
		default:
			die("Unknown maintenance option: " + arg)
		}
	}
	dieOnErr(maintenance.Run(args[0], parentPID, removeSettings))
}

func runRepo(repos *repo.Manager, args []string) {
	if len(args) == 0 {
		die("Usage: zenpm repo <list|add|remove|refresh>")
	}
	switch args[0] {
	case "list":
		entries, err := repos.List()
		dieOnErr(err)
		for _, r := range entries {
			fmt.Printf("%s\t%s\t%d\t%s\n", r.Name, r.URL, r.Priority, r.Trust)
		}
	case "add":
		if len(args) < 3 {
			die("Usage: zenpm repo add <name> <url>")
		}
		// Priority and trust are backend-determined.
		priority := repo.UserAddedPriority
		trust := "trusted"
		if !repo.IsKindleForgeRepo(args[1], args[2]) {
			var sigErr error
			trust, sigErr = repo.VerifyRepoSignature(args[2])
			if sigErr != nil {
				trust = "warn-unsigned"
			}
		}
		// Warn on plain-HTTP repos.
		if safety := repo.CheckRepoURLSafety(args[2]); safety != "" {
			fmt.Fprintf(os.Stderr, "WARNING: %s\n", safety)
			if trust == "signed" {
				trust = "warn-unsigned"
			}
		}
		dieOnErr(repos.Add(args[1], args[2], priority, trust))
		fmt.Printf("Added repo: %s (trust: %s)\n", args[1], trust)
	case "remove":
		if len(args) < 2 {
			die("Usage: zenpm repo remove <name>")
		}
		dieOnErr(repos.Remove(args[1]))
		fmt.Printf("Removed repo: %s\n", args[1])
	case "refresh":
		dieOnErr(repos.Refresh())
		fmt.Println("Repositories refreshed.")
	default:
		die("Unknown repo command: " + args[0])
	}
}

func runPackage(st *state.State, repos *repo.Manager, pkgs *pkg.Manager, plat string, args []string) {
	if len(args) == 0 {
		die("Usage: zenpm <list|info|install|uninstall|update>")
	}
	switch args[0] {
	case "list":
		if len(args) > 1 && args[1] == "installed" {
			installed, err := st.ReadInstalled()
			dieOnErr(err)
			for _, e := range installed {
				name := e.Name
				if name == "" {
					name = e.ID
				}
				fmt.Printf("%s | %s | %s\n", e.ID, name, e.Version)
			}
			return
		}
		targetPlat := plat
		if len(args) > 1 {
			targetPlat = args[1]
		}
		catalog, err := repos.ReadCatalog()
		dieOnErr(err)
		if len(catalog) == 0 {
			dieOnErr(repos.Refresh())
			catalog, err = repos.ReadCatalog()
			dieOnErr(err)
		}
		filtered := repo.FilterByPlatform(catalog, targetPlat)
		for _, e := range filtered {
			name := e.Name
			if name == "" {
				name = e.ID
			}
			fmt.Printf("%s | %s | %s\n", e.ID, name, e.Version)
		}
	case "info":
		if len(args) < 2 {
			die("Usage: zenpm info <id>")
		}
		catalog, err := repos.ReadCatalog()
		dieOnErr(err)
		for _, e := range catalog {
			if e.ID == args[1] {
				fmt.Printf("ID:        %s\n", e.ID)
				fmt.Printf("Name:      %s\n", e.Name)
				fmt.Printf("Version:   %s\n", e.Version)
				fmt.Printf("Repo:      %s\n", e.Repo)
				fmt.Printf("Platforms: %s\n", strings.Join(e.Platforms, ", "))
				fmt.Printf("Deps:      %s\n", strings.Join(e.Deps, ", "))
				return
			}
		}
		die("Package not found: " + args[1])
	case "install":
		if len(args) < 2 {
			die("Usage: zenpm install <id>")
		}
		dieOnErr(pkgs.Install(args[1]))
		fmt.Printf("Installed: %s\n", args[1])
	case "uninstall":
		if len(args) < 2 {
			die("Usage: zenpm uninstall <id> [patch-file]")
		}
		asset := ""
		if len(args) > 2 {
			asset = args[2]
		}
		dieOnErr(pkgs.Uninstall(args[1], asset))
		fmt.Printf("Uninstalled: %s\n", args[1])
	case "update":
		target := ""
		if len(args) > 1 {
			target = args[1]
		}
		dieOnErr(pkgs.Update(target))
	default:
		die("Unknown package command: " + args[0])
	}
}

func runDoctor(st *state.State, plat string) {
	fmt.Printf("Platform:   %s\n", plat)
	fmt.Printf("ZENPM_HOME: %s\n", st.Home)

	check := func(label, path string) {
		if _, err := os.Stat(path); err == nil {
			fmt.Printf("  [OK] %s: %s\n", label, path)
		} else {
			fmt.Printf("  [!!] %s: %s (missing)\n", label, path)
		}
	}
	check("zenpm.sqlite3", st.SQLiteDB)
	check("cache dir", st.CacheDir)
	check("log file", st.LogFile)

	switch plat {
	case platform.Kindle:
		check("appreg.db", "/var/local/appreg.db")
		fmt.Printf("  ABI: %s\n", platform.KindleABI())
		if platform.KindleHasKUAL() {
			fmt.Println("  [OK] KUAL: found")
		} else {
			fmt.Println("  [--] KUAL: not found")
		}
	case platform.Kobo:
		if platform.KoboHasNickelMenu() {
			fmt.Println("  [OK] NickelMenu: found")
		} else {
			fmt.Println("  [--] NickelMenu: not found")
		}
	}
}

func runLogs(st *state.State, args []string) {
	tail := 50
	fs := flag.NewFlagSet("logs", flag.ExitOnError)
	fs.IntVar(&tail, "tail", 50, "number of lines to show")
	fs.Parse(args)

	data, err := os.ReadFile(st.LogFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "No log file at %s\n", st.LogFile)
		return
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > tail {
		lines = lines[len(lines)-tail:]
	}
	fmt.Println(strings.Join(lines, "\n"))
}

func runServe(st *state.State, repos *repo.Manager, pkgs *pkg.Manager, startedAt time.Time, args []string) {
	port := 8080
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	fs.IntVar(&port, "port", 8080, "port to bind on 127.0.0.1")
	fs.Parse(args)

	server.Version = version
	srv := server.New(st, repos, pkgs, port)
	srv.StartedAt = startedAt
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}

func die(msg string) {
	fmt.Fprintln(os.Stderr, "[ZenPM] "+msg)
	os.Exit(1)
}

func dieOnErr(err error) {
	if err != nil {
		die(err.Error())
	}
}
