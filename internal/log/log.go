package log

import (
	"fmt"
	"os"
	"sync"
	"time"
)

var (
	mu      sync.Mutex
	logPath string
)

// Init sets the log file path. Must be called before any logging.
func Init(path string) {
	mu.Lock()
	logPath = path
	mu.Unlock()
}

func write(level, msg string) {
	ts := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	line := fmt.Sprintf("%s  %-4s  %s\n", ts, level, msg)
	mu.Lock()
	defer mu.Unlock()
	if logPath != "" {
		if f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644); err == nil {
			f.WriteString(line)
			f.Close()
		}
		return // file is canonical output; suppress stderr to avoid duplicates
	}
	fmt.Fprint(os.Stderr, line)
}

func Info(msg string)                              { write("INFO", msg) }
func Warn(msg string)                              { write("WARN", msg) }
func Infof(format string, args ...interface{})     { Info(fmt.Sprintf(format, args...)) }
func Warnf(format string, args ...interface{})     { Warn(fmt.Sprintf(format, args...)) }
func Errorf(format string, args ...interface{})    { write("ERR", fmt.Sprintf(format, args...)) }
