package pkg

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/xZenLabs/zen-pm/internal/repo"
)

var iconPackID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

func (m *Manager) installKOReaderIconPack(entry *repo.CatalogEntry, root, assetName string, asset *os.File) (string, error) {
	if !strings.HasSuffix(strings.ToLower(assetName), ".zip") {
		return "", fmt.Errorf("icon pack asset must be a ZIP archive")
	}
	info, err := asset.Stat()
	if err != nil {
		return "", err
	}
	if info.Size() > 25*1024*1024 {
		return "", fmt.Errorf("icon pack ZIP exceeds 25 MiB")
	}
	archive, err := zip.NewReader(asset, info.Size())
	if err != nil {
		return "", err
	}
	if len(archive.File) > 512 {
		return "", fmt.Errorf("icon pack ZIP exceeds 512 entries")
	}
	packID := ""
	var metadata []byte
	var total uint64
	icons := 0
	seen := make(map[string]bool)
	for _, file := range archive.File {
		name := strings.TrimSuffix(file.Name, "/")
		parts := strings.Split(name, "/")
		if !iconPackID.MatchString(parts[0]) || strings.Contains(name, "\\") {
			return "", fmt.Errorf("unsafe icon pack path %q", file.Name)
		}
		for _, part := range parts {
			if part == "" || part == "." || part == ".." {
				return "", fmt.Errorf("unsafe icon pack path %q", file.Name)
			}
		}
		if packID != "" && packID != parts[0] {
			return "", fmt.Errorf("icon pack ZIP must contain one pack folder")
		}
		packID = parts[0]
		key := strings.ToLower(name)
		if seen[key] || (!file.FileInfo().IsDir() && !file.Mode().IsRegular()) {
			return "", fmt.Errorf("duplicate or unsupported icon pack entry %q", file.Name)
		}
		seen[key] = true
		if file.FileInfo().IsDir() {
			continue
		}
		if len(parts) < 2 || file.UncompressedSize64 > 5*1024*1024 {
			return "", fmt.Errorf("invalid or oversized icon pack entry %q", file.Name)
		}
		total += file.UncompressedSize64
		if total > 50*1024*1024 {
			return "", fmt.Errorf("icon pack ZIP exceeds 50 MiB expanded")
		}
		if len(parts) == 2 && (strings.HasSuffix(name, ".svg") || strings.HasSuffix(name, ".png")) {
			if !iconPackID.MatchString(strings.TrimSuffix(parts[1], filepath.Ext(parts[1]))) {
				return "", fmt.Errorf("unsafe icon filename %q", parts[1])
			}
			input, err := file.Open()
			if err != nil {
				return "", fmt.Errorf("read icon %q: %w", parts[1], err)
			}
			data, err := io.ReadAll(io.LimitReader(input, 5*1024*1024+1))
			input.Close()
			if err != nil {
				return "", fmt.Errorf("read icon %q: %w", parts[1], err)
			}
			if len(data) > 5*1024*1024 {
				return "", fmt.Errorf("oversized icon %q", parts[1])
			}
			if err := validateIconPackIcon(parts[1], data); err != nil {
				return "", fmt.Errorf("invalid icon %q: %w", parts[1], err)
			}
			icons++
		}
		if name == packID+"/pack.json" {
			if file.UncompressedSize64 > 64*1024 {
				return "", fmt.Errorf("icon pack metadata exceeds 64 KiB")
			}
			input, err := file.Open()
			if err != nil {
				return "", err
			}
			metadata, err = io.ReadAll(io.LimitReader(input, 64*1024+1))
			input.Close()
			if err != nil || len(metadata) > 64*1024 {
				return "", fmt.Errorf("could not read icon pack metadata")
			}
		}
	}
	var pack map[string]json.RawMessage
	var schema float64
	var id, name string
	if err := json.Unmarshal(metadata, &pack); err != nil ||
		json.Unmarshal(pack["schema_version"], &schema) != nil || schema != 1 ||
		json.Unmarshal(pack["id"], &id) != nil || id != packID ||
		json.Unmarshal(pack["name"], &name) != nil || name == "" || len(name) > 160 || icons == 0 {
		return "", fmt.Errorf("invalid ZenOS icon pack metadata or missing root icons")
	}
	for _, field := range []json.RawMessage{pack["version"], pack["author"]} {
		if len(field) > 0 && field[0] != '"' {
			return "", fmt.Errorf("icon pack version and author must be strings when present")
		}
	}
	directory := filepath.Join(root, "icons", "zen")
	destination := filepath.Join(directory, packID)
	installed, err := m.st.ReadInstalledPatchFiles()
	if err != nil {
		return "", err
	}
	for _, item := range installed {
		if !strings.EqualFold(item.InstallPath, destination) || (item.PackageID == entry.ID && item.Asset == assetName) {
			continue
		}
		conflict := fmt.Errorf("icon pack %q is already managed by %s / %s", packID, item.PackageID, item.Asset)
		if item.Asset != assetName || item.Repo == "" || item.Repo != entry.Repo {
			return "", conflict
		}
		// A renamed catalog ID can leave the same repository asset tracked under its old ID.
		catalog, err := m.repos.ReadCatalog()
		if err != nil {
			return "", err
		}
		for _, owner := range catalog {
			if owner.ID == item.PackageID {
				return "", conflict
			}
		}
	}
	stage, source, err := m.extractArchive(asset)
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stage)
	if err := os.MkdirAll(directory, 0755); err != nil {
		return "", err
	}
	if err := replaceTree(source, destination); err != nil {
		return "", err
	}
	return destination, nil
}

func validateIconPackIcon(name string, data []byte) error {
	if strings.HasSuffix(name, ".png") {
		config, err := png.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			return err
		}
		if config.Width < 1 || config.Height < 1 || int64(config.Width)*int64(config.Height) > maxKOReaderImagePixels {
			return fmt.Errorf("unsafe image dimensions %dx%d", config.Width, config.Height)
		}
		_, err = png.Decode(bytes.NewReader(data))
		return err
	}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	decoder.CharsetReader = func(charset string, input io.Reader) (io.Reader, error) {
		if !strings.EqualFold(charset, "iso-8859-1") {
			return nil, fmt.Errorf("unsupported SVG encoding %q", charset)
		}
		latin1, err := io.ReadAll(input)
		if err != nil {
			return nil, err
		}
		var utf8 strings.Builder
		for _, value := range latin1 {
			utf8.WriteRune(rune(value))
		}
		return strings.NewReader(utf8.String()), nil
	}
	depth, roots := 0, 0
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			if roots != 1 {
				return fmt.Errorf("expected an SVG document")
			}
			return nil
		}
		if err != nil {
			return err
		}
		switch value := token.(type) {
		case xml.StartElement:
			if depth == 0 {
				if roots != 0 || value.Name.Local != "svg" || (value.Name.Space != "" && value.Name.Space != "http://www.w3.org/2000/svg") {
					return fmt.Errorf("expected a single SVG root element")
				}
				roots++
			}
			depth++
		case xml.EndElement:
			depth--
		case xml.CharData:
			if depth == 0 && len(bytes.TrimSpace(value)) > 0 {
				return fmt.Errorf("unexpected text outside the SVG root")
			}
		}
	}
}

func removeKOReaderIconPack(root, path string) error {
	directory := filepath.Join(root, "icons", "zen")
	if filepath.Dir(path) != directory || !iconPackID.MatchString(filepath.Base(path)) {
		return fmt.Errorf("invalid tracked icon pack path %q", path)
	}
	handle, err := os.OpenRoot(root)
	if err != nil {
		return err
	}
	defer handle.Close()
	return handle.RemoveAll(filepath.Join("icons", "zen", filepath.Base(path)))
}
