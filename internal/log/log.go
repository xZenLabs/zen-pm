package log

import (
	"bytes"
	"fmt"
	"os"
	"sync"
	"time"
)

const MaxBytes = 1024 * 1024

var (
	mu            sync.Mutex
	logPath       string
	mirrorLogPath string
)

// Init sets the log file path. Must be called before any logging.
func Init(path string) {
	mu.Lock()
	logPath = path
	mirrorLogPath = os.Getenv("ZENPM_COMPANION_LOG")
	mu.Unlock()
}

func write(level, msg string) {
	ts := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	line := fmt.Sprintf("%s  %-4s  %s\n", ts, level, msg)
	mu.Lock()
	defer mu.Unlock()
	if logPath != "" {
		appendFile(logPath, line)
		if mirrorLogPath != "" && mirrorLogPath != logPath {
			appendFile(mirrorLogPath, line)
		}
		return // file is canonical output; suppress stderr to avoid duplicates
	}
	fmt.Fprint(os.Stderr, line)
}

// Append writes a bounded diagnostic file, including before Init is called.
func Append(path, line string) {
	mu.Lock()
	defer mu.Unlock()
	appendFile(path, line)
}

func appendFile(path, line string) {
	if len(line) > MaxBytes/2 {
		line = "[truncated] " + line[len(line)-MaxBytes/2+12:]
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return
	}
	if info.Size()+int64(len(line)) > MaxBytes {
		// Compact in place: launchers may still have stderr open on this inode.
		tail := make([]byte, min(info.Size(), MaxBytes/2))
		if _, err := f.ReadAt(tail, info.Size()-int64(len(tail))); err != nil {
			return
		}
		if end := bytes.IndexByte(tail, '\n'); end >= 0 {
			tail = tail[end+1:]
		}
		if err := f.Truncate(0); err != nil {
			return
		}
		if _, err := f.Write(tail); err != nil {
			return
		}
	}
	f.WriteString(line)
}

func Info(msg string)                           { write("INFO", msg) }
func Warn(msg string)                           { write("WARN", msg) }
func Debug(msg string)                          { write("DBG", msg) }
func Infof(format string, args ...interface{})  { Info(fmt.Sprintf(format, args...)) }
func Warnf(format string, args ...interface{})  { Warn(fmt.Sprintf(format, args...)) }
func Debugf(format string, args ...interface{}) { Debug(fmt.Sprintf(format, args...)) }
func Errorf(format string, args ...interface{}) { write("ERR", fmt.Sprintf(format, args...)) }
