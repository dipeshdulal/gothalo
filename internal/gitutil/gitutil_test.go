package gitutil

import (
	"errors"
	"os"
	"strings"
	"testing"
)

func TestEnvironmentDisablesOptionalLocks(t *testing.T) {
	old, had := os.LookupEnv("GIT_OPTIONAL_LOCKS")
	if err := os.Setenv("GIT_OPTIONAL_LOCKS", "1"); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if had {
			_ = os.Setenv("GIT_OPTIONAL_LOCKS", old)
		} else {
			_ = os.Unsetenv("GIT_OPTIONAL_LOCKS")
		}
	}()

	env := Environment()
	matches := 0
	for _, value := range env {
		if strings.HasPrefix(value, "GIT_OPTIONAL_LOCKS=") {
			matches++
			if value != "GIT_OPTIONAL_LOCKS=0" {
				t.Fatalf("GIT_OPTIONAL_LOCKS = %q, want 0", value)
			}
		}
	}
	if matches != 1 {
		t.Fatalf("found %d GIT_OPTIONAL_LOCKS entries, want exactly one", matches)
	}
}

func TestIndexLockError(t *testing.T) {
	err := IndexLockError("fatal: Unable to create '/repo/.git/index.lock': File exists.")
	if !errors.Is(err, ErrIndexLocked) {
		t.Fatalf("errors.Is(%v, ErrIndexLocked) = false", err)
	}
	if !strings.Contains(err.Error(), "index.lock") {
		t.Fatalf("error = %q, want git diagnostic", err)
	}
	if got := IndexLockError("fatal: not a git repository"); got != nil {
		t.Fatalf("non-lock diagnostic returned %v", got)
	}
}
