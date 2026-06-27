package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"ZPM/internal/log"
	"ZPM/internal/pkg"
	"ZPM/internal/platform"
	"ZPM/internal/repo"
	"ZPM/internal/server"
	"ZPM/internal/state"
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
	case "repo":
		runRepo(repos, os.Args[2:])
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
	fmt.Fprintln(os.Stderr, "  package list [platform]|info <id>|install <id>|uninstall <id>|update [id]")
	fmt.Fprintln(os.Stderr, "  doctor")
	fmt.Fprintln(os.Stderr, "  logs    [--tail N]")
	fmt.Fprintln(os.Stderr, "  serve   [--port PORT]")
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
		die("Usage: zenpm package <list|info|install|uninstall|update>")
	}
	switch args[0] {
	case "list":
		targetPlat := plat
		if len(args) > 1 {
			targetPlat = args[1]
		}
		catalog, err := repos.ReadCatalog()
		dieOnErr(err)
		installed, _ := st.ReadInstalled()
		installedSet := make(map[string]bool)
		for _, e := range installed {
			installedSet[e.ID] = true
		}
		filtered := repo.FilterByPlatform(catalog, targetPlat)
		fmt.Println("ID\tNAME\tVERSION\tPLATFORM\tREPO\tINSTALLED")
		for _, e := range filtered {
			inst := "no"
			if installedSet[e.ID] {
				inst = "yes"
			}
			fmt.Printf("%s\t%s\t%s\t%s\t%s\t%s\n",
				e.ID, e.Name, e.Version, strings.Join(e.Platforms, ","), e.Repo, inst)
		}
	case "info":
		if len(args) < 2 {
			die("Usage: zenpm package info <id>")
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
			die("Usage: zenpm package install <id>")
		}
		dieOnErr(pkgs.Install(args[1]))
		fmt.Printf("Installed: %s\n", args[1])
	case "uninstall":
		if len(args) < 2 {
			die("Usage: zenpm package uninstall <id>")
		}
		dieOnErr(pkgs.Uninstall(args[1]))
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
