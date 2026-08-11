// Package gitutil contains the process-level safeguards shared by the bridge's
// direct git readers and writers.
package gitutil

import (
	"errors"
	"os"
	"strings"
)

// ErrIndexLocked identifies a git command that could not proceed because an
// index.lock is present. Callers can map this to a retryable conflict instead
// of presenting it as an unrelated server failure.
var ErrIndexLocked = errors.New("git index is locked")

// Environment returns the process environment with Git's optional index locks
// disabled. Commands such as `git status` can refresh the index as a side
// effect; that refresh is not needed for the bridge's read-only views and can
// otherwise contend with an agent running `git add` or `git commit`.
func Environment() []string {
	env := os.Environ()
	for i, value := range env {
		if strings.HasPrefix(value, "GIT_OPTIONAL_LOCKS=") {
			env[i] = "GIT_OPTIONAL_LOCKS=0"
			return env
		}
	}
	return append(env, "GIT_OPTIONAL_LOCKS=0")
}

// IndexLockError converts matching stderr into an errors.Is-compatible error.
// Git's wording varies slightly by version and platform, so the match is
// deliberately focused on the stable index.lock token.
func IndexLockError(stderr string) error {
	if !strings.Contains(strings.ToLower(stderr), "index.lock") {
		return nil
	}
	return &indexLockError{stderr: strings.TrimSpace(stderr)}
}

type indexLockError struct{ stderr string }

func (e *indexLockError) Error() string {
	if e.stderr == "" {
		return ErrIndexLocked.Error()
	}
	return ErrIndexLocked.Error() + ": " + e.stderr
}

func (e *indexLockError) Unwrap() error { return ErrIndexLocked }
