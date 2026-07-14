package cabundle

import (
	"crypto/x509"
	"os"
	"path/filepath"
	"testing"
)

func TestBundledCertificatesAreValid(t *testing.T) {
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM([]byte(pemData)) {
		t.Fatal("bundled CA file contains no certificates")
	}
}

func TestWriteFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cacert.pem")
	if err := WriteFile(path); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != pemData {
		t.Fatal("written CA bundle differs from the bundled data")
	}
}
