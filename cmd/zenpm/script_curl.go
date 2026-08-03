package main

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/xZenLabs/zen-pm/internal/cabundle"
)

func runScriptCurl(args []string, stdout io.Writer) error {
	downloadURL, output, err := parseScriptCurlArgs(args)
	if err != nil {
		return err
	}
	parsed, err := url.Parse(downloadURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return fmt.Errorf("invalid URL %q", downloadURL)
	}

	req, err := http.NewRequest(http.MethodGet, downloadURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "ZenPM/1.0 (+https://github.com/xZenLabs/zen-pm)")
	resp, err := cabundle.Client(10 * time.Minute).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HTTP %s for %s", resp.Status, downloadURL)
	}
	if output == "" || output == "-" {
		_, err = io.Copy(stdout, resp.Body)
		return err
	}
	return writeDownload(output, resp.Body)
}

func parseScriptCurlArgs(args []string) (string, string, error) {
	downloadURL := ""
	output := ""
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "-o" || arg == "--output":
			i++
			if i >= len(args) {
				return "", "", fmt.Errorf("%s requires a path", arg)
			}
			output = args[i]
		case strings.HasPrefix(arg, "--output="):
			output = strings.TrimPrefix(arg, "--output=")
		case strings.HasPrefix(arg, "-o") && len(arg) > 2:
			output = arg[2:]
		case isSupportedCurlFlag(arg):
			continue
		case strings.HasPrefix(arg, "-"):
			return "", "", fmt.Errorf("unsupported installer option %q", arg)
		case downloadURL == "":
			downloadURL = arg
		default:
			return "", "", fmt.Errorf("multiple URLs are not supported")
		}
	}
	if downloadURL == "" {
		return "", "", fmt.Errorf("no URL provided")
	}
	return downloadURL, output, nil
}

func isSupportedCurlFlag(arg string) bool {
	switch arg {
	case "--fail", "--location", "--silent", "--show-error", "--progress-bar":
		return true
	}
	if len(arg) < 2 || arg[0] != '-' || arg[1] == '-' {
		return false
	}
	for _, flag := range arg[1:] {
		if !strings.ContainsRune("fsSL#", flag) {
			return false
		}
	}
	return true
}

func writeDownload(path string, body io.Reader) (retErr error) {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".zenpm-")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer func() {
		if retErr != nil {
			_ = os.Remove(tmpPath)
		}
	}()
	if _, err := io.Copy(tmp, body); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0644); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}
