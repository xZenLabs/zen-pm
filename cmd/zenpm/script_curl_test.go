package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunScriptCurlDownloadsRedirectToFile(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/release" {
			http.Redirect(w, r, "/asset", http.StatusFound)
			return
		}
		io.WriteString(w, "script contents")
	}))
	defer server.Close()

	output := filepath.Join(t.TempDir(), "ZenReader.sh")
	err := runScriptCurl([]string{"-fSL", "--progress-bar", "-o", output, server.URL + "/release"}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "script contents" {
		t.Fatalf("download = %q", data)
	}
}

func TestRunScriptCurlWritesStdout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, "response")
	}))
	defer server.Close()

	var output bytes.Buffer
	if err := runScriptCurl([]string{"-fsSL", server.URL}, &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "response" {
		t.Fatalf("stdout = %q", output.String())
	}
}

func TestParseScriptCurlArgsRejectsUnsupportedOptions(t *testing.T) {
	_, _, err := parseScriptCurlArgs([]string{"-X", "POST", "https://example.test"})
	if err == nil || !strings.Contains(err.Error(), "unsupported") {
		t.Fatalf("error = %v, want unsupported option", err)
	}
}
