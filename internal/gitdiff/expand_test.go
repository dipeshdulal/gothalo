package gitdiff

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// expandFixture writes a file whose content is its own line numbers, so an
// assertion can say exactly which slice came back.
func expandFixture(t *testing.T, lines int) string {
	t.Helper()
	dir := t.TempDir()
	var b strings.Builder
	for i := 1; i <= lines; i++ {
		b.WriteString("line ")
		b.WriteString(strconv.Itoa(i))
		b.WriteByte('\n')
	}
	mustWrite(t, dir, "file.txt", b.String())
	return dir
}

func TestExpandContext_Slice(t *testing.T) {
	dir := expandFixture(t, 100)

	exp, err := ExpandContext(dir, "file.txt", 10, 5)
	if err != nil {
		t.Fatalf("ExpandContext: %v", err)
	}
	if exp.Start != 10 || len(exp.Lines) != 5 {
		t.Fatalf("got start=%d len=%d, want 10/5: %+v", exp.Start, len(exp.Lines), exp)
	}
	if exp.Lines[0] != "line 10" || exp.Lines[4] != "line 14" {
		t.Errorf("Lines = %v, want line 10..14", exp.Lines)
	}
	if exp.EOF {
		t.Errorf("EOF set mid-file")
	}
	// A trailing newline ends line 100; it does not start a phantom line 101.
	if exp.Total != 100 {
		t.Errorf("Total = %d, want 100", exp.Total)
	}
}

func TestExpandContext_ClampsRatherThanErrors(t *testing.T) {
	dir := expandFixture(t, 20)

	t.Run("count past EOF returns the tail and sets EOF", func(t *testing.T) {
		exp, err := ExpandContext(dir, "file.txt", 18, 50)
		if err != nil {
			t.Fatalf("ExpandContext: %v", err)
		}
		if len(exp.Lines) != 3 || !exp.EOF {
			t.Errorf("got %d lines eof=%v, want 3 lines at EOF: %+v", len(exp.Lines), exp.EOF, exp)
		}
	})

	t.Run("start past EOF is empty, not an error", func(t *testing.T) {
		exp, err := ExpandContext(dir, "file.txt", 999, 10)
		if err != nil {
			t.Fatalf("ExpandContext: %v", err)
		}
		if len(exp.Lines) != 0 || !exp.EOF {
			t.Errorf("got %+v, want no lines at EOF", exp)
		}
	})

	t.Run("a nonsense start/count is floored, not rejected", func(t *testing.T) {
		exp, err := ExpandContext(dir, "file.txt", 0, 0)
		if err != nil {
			t.Fatalf("ExpandContext: %v", err)
		}
		if exp.Start != 1 || len(exp.Lines) != 1 {
			t.Errorf("got %+v, want line 1 alone", exp)
		}
	})

	t.Run("count is capped", func(t *testing.T) {
		big := expandFixture(t, expandMaxLines+50)
		exp, err := ExpandContext(big, "file.txt", 1, expandMaxLines*10)
		if err != nil {
			t.Fatalf("ExpandContext: %v", err)
		}
		if len(exp.Lines) != expandMaxLines {
			t.Errorf("got %d lines, want the %d cap", len(exp.Lines), expandMaxLines)
		}
	})
}

// The path arrives on a query string, so traversal is a request that will
// actually show up one day.
func TestExpandContext_RefusesEscapingPaths(t *testing.T) {
	dir := expandFixture(t, 5)
	secret := filepath.Join(filepath.Dir(dir), "secret.txt")
	if err := os.WriteFile(secret, []byte("nope\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	for _, path := range []string{"", "../secret.txt", "sub/../../secret.txt", secret} {
		if _, err := ExpandContext(dir, path, 1, 1); !errors.Is(err, ErrBadPath) {
			t.Errorf("ExpandContext(%q) err = %v, want ErrBadPath", path, err)
		}
	}
}

func TestExpandContext_MissingAndBinary(t *testing.T) {
	dir := expandFixture(t, 5)

	if _, err := ExpandContext(dir, "nope.txt", 1, 1); !errors.Is(err, ErrNoSuchFile) {
		t.Errorf("missing file err = %v, want ErrNoSuchFile", err)
	}
	if _, err := ExpandContext(dir, ".", 1, 1); !errors.Is(err, ErrNoSuchFile) {
		t.Errorf("directory err = %v, want ErrNoSuchFile", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "bin"), []byte{0xff, 0xfe, 0x00}, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ExpandContext(dir, "bin", 1, 1); !errors.Is(err, ErrNotText) {
		t.Errorf("binary file err = %v, want ErrNotText", err)
	}
}
