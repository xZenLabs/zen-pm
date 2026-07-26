// Package maintenance implements ZenPM's on-device maintenance operations.
package maintenance

import (
	"archive/zip"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/xZenLabs/zen-pm/internal/cabundle"
	"github.com/xZenLabs/zen-pm/internal/httpdiag"
	"github.com/xZenLabs/zen-pm/internal/platform"
	"github.com/xZenLabs/zen-pm/internal/releases"
)

const (
	kindlePayloadDir = "/mnt/us/ZenPM"
	kindlePersistDir = "/mnt/us/.ZenPM"
	kindleAppID      = "com.zenlabs.zenpm"
	zenPMRepository  = "https://github.com/xZenLabs/zen-pm"
)

// Start launches a detached maintenance helper. The helper must be a separate
// process because it replaces or removes the binary serving this request.
func Start(action string, removeSettings bool) error {
	binary, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locate executable: %w", err)
	}
	args := []string{"maintenance", action, "--parent-pid=" + strconv.Itoa(os.Getpid())}
	if removeSettings {
		args = append(args, "--remove-settings")
	}
	cmd := exec.Command(binary, args...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd.Start()
}

// Run executes a Kindle maintenance helper action.
func Run(action string, parentPID int, removeSettings bool) error {
	if platform.Detect() != platform.Kindle {
		return errors.New("Kindle maintenance is only available on Kindle")
	}
	switch action {
	case "update":
		if !platform.KindleWAFAllowed(platform.Kindle) {
			return errors.New("Kindle standalone is not supported on this device")
		}
		return update(parentPID)
	case "uninstall":
		return uninstall(parentPID, removeSettings)
	default:
		return fmt.Errorf("unknown maintenance action: %s", action)
	}
}

func update(parentPID int) error {
	currentVersion := readVersion(filepath.Join(kindlePayloadDir, "VERSION"))
	showAlert("Checking for Updates...", "Current: v"+currentVersion)

	release, asset, err := latestKindleRelease()
	if err != nil {
		showAlert("Update Failed!", err.Error())
		return err
	}
	latestVersion := releases.NormalizeVersion(release.TagName)
	if !releases.VersionGreater(latestVersion, currentVersion) {
		showAlert("ZenPM is up to date!", "You have v"+currentVersion+".\nLatest is v"+latestVersion+".")
		return nil
	}

	showAlert("Updating ZenPM...", "Downloading v"+latestVersion+"...")
	tempDir, err := os.MkdirTemp("/mnt/us", "ZPM-Update-")
	if err != nil {
		return fmt.Errorf("create update directory: %w", err)
	}
	defer os.RemoveAll(tempDir)

	archivePath := filepath.Join(tempDir, asset.Name)
	if err := downloadAsset(asset, archivePath); err != nil {
		showAlert("Update Failed!", err.Error())
		return err
	}
	if err := extractZip(archivePath, tempDir); err != nil {
		showAlert("Update Failed!", err.Error())
		return err
	}
	payload := filepath.Join(tempDir, "ZenPM")
	if info, err := os.Stat(payload); err != nil || !info.IsDir() {
		return errors.New("extracted payload missing ZenPM directory")
	}

	showAlert("Updating ZenPM...", "Installing v"+latestVersion+"...")
	stopApp(parentPID)
	if err := os.RemoveAll(kindlePayloadDir); err != nil {
		return fmt.Errorf("remove old payload: %w", err)
	}
	if err := copyTree(payload, kindlePayloadDir); err != nil {
		return fmt.Errorf("install payload: %w", err)
	}
	if err := prepareBackend(); err != nil {
		return err
	}
	if err := deployWAF(); err != nil {
		return err
	}
	if err := registerApp(); err != nil {
		return err
	}
	if err := startDaemon(); err != nil {
		return err
	}
	relaunchWAF()
	showAlert("Update Complete!", "Updated to v"+latestVersion+"!\nYou may now use ZenPM.")
	return nil
}

func uninstall(parentPID int, removeSettings bool) error {
	stopApp(parentPID)
	if err := unregisterApp(); err != nil {
		return err
	}
	if err := os.RemoveAll("/var/local/mesquite/ZenPM"); err != nil {
		return fmt.Errorf("remove WAF: %w", err)
	}
	if err := os.RemoveAll(kindlePayloadDir); err != nil {
		return fmt.Errorf("remove payload: %w", err)
	}
	if removeSettings {
		if err := os.RemoveAll(kindlePersistDir); err != nil {
			return fmt.Errorf("remove settings: %w", err)
		}
	}
	return runCommand("sync")
}

func latestKindleRelease() (releases.Release, releases.ReleaseAsset, error) {
	items, err := releases.FetchGitHubReleases(zenPMRepository, 30)
	if err != nil {
		return releases.Release{}, releases.ReleaseAsset{}, fmt.Errorf("fetch latest release: %w", err)
	}
	for _, item := range items {
		if item.Prerelease {
			continue
		}
		name := "ZenPM-kindle-standalone-" + releases.NormalizeVersion(item.TagName) + ".zip"
		for _, asset := range item.Assets {
			if asset.Name == name {
				return item, asset, nil
			}
		}
	}
	return releases.Release{}, releases.ReleaseAsset{}, errors.New("latest release has no Kindle standalone asset")
}

func downloadAsset(asset releases.ReleaseAsset, destination string) error {
	req, err := http.NewRequest(http.MethodGet, asset.URL, nil)
	if err != nil {
		return fmt.Errorf("create download request: %w", err)
	}
	req.Header.Set("User-Agent", "ZenPackageManager")
	resp, err := cabundle.Client(60 * time.Second).Do(req)
	if err != nil {
		return fmt.Errorf("download update: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("download update: %w", httpdiag.ResponseError(resp))
	}

	file, err := os.Create(destination)
	if err != nil {
		return fmt.Errorf("create update archive: %w", err)
	}
	defer file.Close()
	hash := sha256.New()
	limit := asset.Size
	if limit <= 0 {
		limit = 512 * 1024 * 1024
	}
	n, err := io.Copy(io.MultiWriter(file, hash), io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return fmt.Errorf("write update archive: %w", err)
	}
	if n == 0 || n > limit || (asset.Size > 0 && n != asset.Size) {
		return errors.New("download size mismatch")
	}
	digest := strings.TrimPrefix(strings.ToLower(asset.Digest), "sha256:")
	if digest != "" && fmt.Sprintf("%x", hash.Sum(nil)) != digest {
		return errors.New("download checksum mismatch")
	}
	return nil
}

func extractZip(archive, destination string) error {
	reader, err := zip.OpenReader(archive)
	if err != nil {
		return fmt.Errorf("open update archive: %w", err)
	}
	defer reader.Close()
	for _, entry := range reader.File {
		target := filepath.Join(destination, entry.Name)
		rel, err := filepath.Rel(destination, target)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return fmt.Errorf("unsafe archive path: %s", entry.Name)
		}
		if entry.FileInfo().IsDir() {
			if err := os.MkdirAll(target, entry.Mode()); err != nil {
				return err
			}
			continue
		}
		if !entry.Mode().IsRegular() {
			return fmt.Errorf("unsupported archive entry: %s", entry.Name)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		source, err := entry.Open()
		if err != nil {
			return err
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, entry.Mode())
		if err == nil {
			_, err = io.Copy(out, source)
			closeErr := out.Close()
			if err == nil {
				err = closeErr
			}
		}
		source.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func copyTree(source, destination string) error {
	return filepath.WalkDir(source, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, rel)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return os.MkdirAll(target, info.Mode().Perm())
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("unsupported payload entry: %s", rel)
		}
		in, err := os.Open(path)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
		if err != nil {
			return err
		}
		_, err = io.Copy(out, in)
		closeErr := out.Close()
		if err != nil {
			return err
		}
		return closeErr
	})
}

func readVersion(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return "0.0.0"
	}
	version := releases.NormalizeVersion(strings.SplitN(string(data), "\n", 2)[0])
	if version == "" {
		return "0.0.0"
	}
	return version
}

func prepareBackend() error {
	backend := filepath.Join(kindlePayloadDir, "backend", "zenpm")
	source := backend + "-" + platform.KindleABI()
	data, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("read backend: %w", err)
	}
	if err := os.WriteFile(backend, data, 0755); err != nil {
		return fmt.Errorf("write backend: %w", err)
	}
	return writeCLIWrappers(kindlePayloadDir)
}

func writeCLIWrappers(payloadDir string) error {
	cliDir := filepath.Join(payloadDir, "bin")
	if err := os.MkdirAll(cliDir, 0755); err != nil {
		return fmt.Errorf("create CLI directory: %w", err)
	}
	for _, name := range []string{"zenpm", "zpm"} {
		path := filepath.Join(cliDir, name)
		contents := "#!/bin/sh\nexport ZENPM_PLATFORM=kindle\nexec \"" + filepath.Join(payloadDir, "backend", "zenpm") + "\" \"$@\"\n"
		if err := os.WriteFile(path, []byte(contents), 0755); err != nil {
			return fmt.Errorf("write %s CLI wrapper: %w", name, err)
		}
	}
	return nil
}

func deployWAF() error {
	target := "/var/local/mesquite/ZenPM"
	if err := os.RemoveAll(target); err != nil {
		return err
	}
	return copyTree(filepath.Join(kindlePayloadDir, "frontend", "kindle"), target)
}

func registerApp() error {
	query := "INSERT OR IGNORE INTO interfaces(interface) VALUES('application');" +
		"INSERT OR IGNORE INTO handlerIds(handlerId) VALUES('" + kindleAppID + "');" +
		"INSERT OR REPLACE INTO properties(handlerId,name,value) VALUES('" + kindleAppID + "','command','/usr/bin/mesquite -l " + kindleAppID + " -c file:///var/local/mesquite/ZenPM/');"
	return runCommand("sqlite3", "/var/local/appreg.db", query)
}

func unregisterApp() error {
	if _, err := os.Stat("/var/local/appreg.db"); err != nil {
		return nil
	}
	query := "DELETE FROM properties WHERE handlerId = '" + kindleAppID + "';" +
		"DELETE FROM handlerIds WHERE handlerId = '" + kindleAppID + "';"
	return runCommand("sqlite3", "/var/local/appreg.db", query)
}

func startDaemon() error {
	logFile, err := os.OpenFile(filepath.Join(kindlePayloadDir, "ZenPM.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	cmd := exec.Command(filepath.Join(kindlePayloadDir, "backend", "zenpm"), "serve", "--port", "18765")
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		logFile.Close()
		return err
	}
	return logFile.Close()
}

func stopApp(parentPID int) {
	runCommand("lipc-set-prop", "com.lab126.appmgrd", "stop", "app://"+kindleAppID)
	runCommand("pkill", "-f", "mesquite.*"+kindleAppID)
	if parentPID > 0 {
		process, err := os.FindProcess(parentPID)
		if err == nil {
			_ = process.Signal(os.Interrupt)
		}
	}
	time.Sleep(2 * time.Second)
}

func relaunchWAF() {
	runCommand("lipc-set-prop", "com.lab126.appmgrd", "start", "app://com.lab126.booklet.home")
	time.Sleep(2 * time.Second)
	runCommand("killall", "mesquite")
	time.Sleep(2 * time.Second)
	runCommand("lipc-set-prop", "com.lab126.appmgrd", "start", "app://"+kindleAppID)
}

func showAlert(title, message string) {
	payload := fmt.Sprintf(`{"clientParams":{"alertId":"appAlert1","show":true,"customStrings":[{"matchStr":"alertTitle","replaceStr":%s},{"matchStr":"alertText","replaceStr":%s}]}}`, strconv.Quote(title), strconv.Quote(message))
	_ = runCommand("lipc-set-prop", "com.lab126.pillow", "pillowAlert", payload)
}

func runCommand(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}
