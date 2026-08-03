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
	certificates := parseRSACertificates(t, []byte(rsaPEMData))
	for _, name := range []string{
		"Sectigo Public Server Authentication Root R46",
		"USERTrust RSA Certification Authority",
		"ISRG Root X1",
	} {
		if !certificates[name] {
			t.Fatalf("RSA CA bundle missing %q", name)
		}
	}
}

func parseRSACertificates(t *testing.T, data []byte) map[string]bool {
	t.Helper()
	certificates := make(map[string]bool)
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
		certificates[cert.Subject.CommonName] = true
		count++
		data = rest
	}
	if count == 0 {
		t.Fatal("RSA CA bundle contains no certificates")
	}
	return certificates
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
	certificates := parseRSACertificates(t, data)
	if !certificates["Sectigo Public Server Authentication Root R46"] {
		t.Fatal("written RSA CA bundle is missing a bundled root")
	}
}

func TestWriteRSAFileMergesOnlyCompatibleSystemCertificates(t *testing.T) {
	dir := t.TempDir()
	systemBundle := filepath.Join(dir, "system.pem")
	if err := os.WriteFile(systemBundle, []byte(pemData), 0644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "cacert-rsa.pem")
	if err := writeRSAFile(path, nil, []string{systemBundle}, nil); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	certificates := parseRSACertificates(t, data)
	if len(certificates) != 1 || !certificates["ISRG Root X1"] {
		t.Fatalf("filtered system certificates = %v, want only ISRG Root X1", certificates)
	}
}
