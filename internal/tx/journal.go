package tx

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/xZenLabs/zen-pm/internal/state"
)

// Journal records a transaction as a TSV file in the journal directory.
// Format: timestamp\tstage\tstatus\tmessage
type Journal struct {
	st   *state.State
	path string
}

// Begin acquires the operation lock and opens a new journal file.
func Begin(st *state.State, op, target string) (*Journal, error) {
	if err := st.LockAcquire("operation"); err != nil {
		return nil, err
	}
	ts := time.Now().UTC().Format("20060102T150405Z")
	name := fmt.Sprintf("%s-%s-%s.tsv", ts, op, target)
	j := &Journal{st: st, path: filepath.Join(st.JournalDir, name)}
	return j, j.Record("begin", "ok", fmt.Sprintf("op=%s target=%s", op, target))
}

// Record appends a timestamped entry to the journal file.
func (j *Journal) Record(stage, status, message string) error {
	ts := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	line := fmt.Sprintf("%s\t%s\t%s\t%s\n", ts, stage, status, message)
	f, err := os.OpenFile(j.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(line)
	return err
}

// Commit records a successful completion and releases the lock.
func (j *Journal) Commit() {
	j.Record("commit", "ok", "transaction committed")
	j.st.LockRelease("operation")
}

// Abort records a failure reason and releases the lock.
func (j *Journal) Abort(reason string) {
	j.Record("abort", "fail", reason)
	j.st.LockRelease("operation")
}
