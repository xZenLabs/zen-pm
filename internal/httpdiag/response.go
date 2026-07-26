package httpdiag

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

const (
	responseBodyReadLimit = 1024
	responseBodyLogLimit  = 400
)

// ResponseError builds a bounded diagnostic error for a failed HTTP response.
// Only non-sensitive response metadata is included.
func ResponseError(resp *http.Response) error {
	if resp == nil {
		return errors.New("HTTP request returned no response")
	}

	method, target := "", ""
	if resp.Request != nil {
		method = resp.Request.Method
		if resp.Request.URL != nil {
			target = resp.Request.URL.Redacted()
		}
	}
	if method == "" {
		method = "request"
	}
	if target == "" {
		target = "<unknown>"
	}

	status := strings.TrimSpace(resp.Status)
	if status == "" {
		status = fmt.Sprintf("%d %s", resp.StatusCode, http.StatusText(resp.StatusCode))
	}

	body, bodyErr := io.ReadAll(io.LimitReader(resp.Body, responseBodyReadLimit+1))
	truncated := len(body) > responseBodyReadLimit
	if truncated {
		body = body[:responseBodyReadLimit]
	}
	detail := strings.Join(strings.Fields(string(body)), " ")
	if len(detail) > responseBodyLogLimit {
		detail = detail[:responseBodyLogLimit]
		truncated = true
	}
	if truncated {
		detail += "..."
	}

	requestID := firstHeader(resp.Header, "CF-RAY", "X-GitHub-Request-Id", "X-Request-Id")
	message := fmt.Sprintf(
		"HTTP %s %s returned %s (protocol=%q server=%q request_id=%q content_type=%q",
		method, target, status, resp.Proto, resp.Header.Get("Server"), requestID, resp.Header.Get("Content-Type"),
	)
	if detail != "" {
		message += fmt.Sprintf(" body=%q", detail)
	}
	if bodyErr != nil {
		message += fmt.Sprintf(" body_read_error=%q", bodyErr.Error())
	}
	return errors.New(message + ")")
}

func firstHeader(header http.Header, names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(header.Get(name)); value != "" {
			return value
		}
	}
	return ""
}
