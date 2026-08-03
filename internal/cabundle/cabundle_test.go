package cabundle

import (
	"crypto/x509"
	"encoding/pem"
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

func TestRSABundledCertificatesUseSupportedKeyAlgorithm(t *testing.T) {
	data := []byte(rsaPEMData)
	count := 0
	for len(data) > 0 {
		block, rest := pem.Decode(data)
		if block == nil {
			t.Fatal("RSA CA bundle contains invalid PEM data")
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			t.Fatal(err)
		}
		if cert.PublicKeyAlgorithm != x509.RSA {
			t.Fatalf("certificate %q uses %s, want RSA", cert.Subject.CommonName, cert.PublicKeyAlgorithm)
		}
		count++
		data = rest
	}
	if count == 0 {
		t.Fatal("RSA CA bundle contains no certificates")
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

func TestWriteRSAFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cacert-rsa.pem")
	if err := WriteRSAFile(path); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != rsaPEMData {
		t.Fatal("written RSA CA bundle differs from the bundled data")
	}
}
