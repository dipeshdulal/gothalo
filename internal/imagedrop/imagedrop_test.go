package imagedrop

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Minimal byte sequences that http.DetectContentType recognises — the magic
// numbers are all the sniffer looks at, so a real encoded image would test
// nothing extra.
var (
	pngBytes  = append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, 32)...)
	jpegBytes = append([]byte("\xff\xd8\xff"), bytes.Repeat([]byte{0}, 32)...)
	gifBytes  = append([]byte("GIF89a"), bytes.Repeat([]byte{0}, 32)...)
	// RIFF, four size bytes the sniffer masks out, then WEBPVP.
	webpBytes = append([]byte("RIFF\x00\x00\x00\x00WEBPVP"), bytes.Repeat([]byte{0}, 32)...)
)

var fixedClock = time.Date(2026, 8, 5, 14, 25, 30, 0, time.UTC)

// TestDetectAllowsOnlyImages pins the allowlist and, more importantly, that the
// extension follows from the SNIFFED type — the property that makes a
// client-supplied filename unnecessary.
func TestDetectAllowsOnlyImages(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		ct   string
		ext  string
	}{
		{"png", pngBytes, "image/png", ".png"},
		{"jpeg", jpegBytes, "image/jpeg", ".jpg"},
		{"gif", gifBytes, "image/gif", ".gif"},
		{"webp", webpBytes, "image/webp", ".webp"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ct, ext, err := Detect(c.data)
			if err != nil {
				t.Fatalf("Detect: %v", err)
			}
			if ct != c.ct || ext != c.ext {
				t.Errorf("got (%q, %q), want (%q, %q)", ct, ext, c.ct, c.ext)
			}
		})
	}
}

// TestDetectRejects covers every way an upload can be refused before it is
// allowed anywhere near someone's repository.
func TestDetectRejects(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want error
	}{
		{"empty", nil, ErrEmpty},
		{"too-large", bytes.Repeat([]byte{0x41}, MaxBytes+1), ErrTooLarge},
		{"plain-text", []byte("#!/bin/sh\nrm -rf /\n"), ErrUnsupported},
		{"pdf", []byte("%PDF-1.7\n%\xe2\xe3\xcf\xd3\n"), ErrUnsupported},
		// A shell script named "screenshot.png" by the client is still a shell
		// script here: the name never reaches this package.
		{"svg", []byte(`<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>`), ErrUnsupported},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, _, err := Detect(c.data); !errors.Is(err, c.want) {
				t.Errorf("err = %v, want %v", err, c.want)
			}
		})
	}
}

// TestDetectAcceptsExactlyMaxBytes asserts the cap is inclusive — an upload of
// exactly MaxBytes is legal, only one byte more is not.
func TestDetectAcceptsExactlyMaxBytes(t *testing.T) {
	data := append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, MaxBytes-8)...)
	if len(data) != MaxBytes {
		t.Fatalf("fixture is %d bytes, want %d", len(data), MaxBytes)
	}
	if _, _, err := Detect(data); err != nil {
		t.Errorf("Detect at the cap: %v", err)
	}
}

// TestSaveWritesUnderCwd is the core contract: the file lands inside the agent's
// tree, at the documented path, and the returned path is absolute and readable.
func TestSaveWritesUnderCwd(t *testing.T) {
	cwd := t.TempDir()
	res, err := Save(cwd, pngBytes, fixedClock)
	if err != nil {
		t.Fatalf("Save: %v", err)
	}
	if !filepath.IsAbs(res.Path) {
		t.Errorf("path %q is not absolute", res.Path)
	}
	wantDir := filepath.Join(cwd, ".gothalo", "images")
	if filepath.Dir(res.Path) != wantDir {
		t.Errorf("dir = %q, want %q", filepath.Dir(res.Path), wantDir)
	}
	if res.RelativePath != ".gothalo/images/"+filepath.Base(res.Path) {
		t.Errorf("relative_path = %q", res.RelativePath)
	}
	if res.ContentType != "image/png" || res.Bytes != len(pngBytes) {
		t.Errorf("got (%q, %d)", res.ContentType, res.Bytes)
	}
	got, err := os.ReadFile(res.Path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if !bytes.Equal(got, pngBytes) {
		t.Error("written bytes differ from the upload")
	}
}

// TestSaveNameIsDeterministic asserts the injected clock plus the content hash
// fully determine the name — which is what makes every other test here able to
// assert on paths, and makes re-uploading the same screenshot idempotent rather
// than duplicating it.
func TestSaveNameIsDeterministic(t *testing.T) {
	cwd := t.TempDir()
	first, err := Save(cwd, pngBytes, fixedClock)
	if err != nil {
		t.Fatalf("Save: %v", err)
	}
	if want := "20260805-142530-"; !strings.HasPrefix(filepath.Base(first.Path), want) {
		t.Errorf("name %q does not start with %q", filepath.Base(first.Path), want)
	}
	second, err := Save(cwd, pngBytes, fixedClock)
	if err != nil {
		t.Fatalf("Save again: %v", err)
	}
	if second.Path != first.Path {
		t.Errorf("same bytes at the same instant produced %q then %q", first.Path, second.Path)
	}
	// Different bytes at the same instant must NOT collide.
	other, err := Save(cwd, jpegBytes, fixedClock)
	if err != nil {
		t.Fatalf("Save other: %v", err)
	}
	if other.Path == first.Path {
		t.Error("different images collided on one path")
	}
}

// TestSaveIgnoresDirectory asserts the .gothalo/ root is made invisible to the
// repo it lives in — without this every attached screenshot turns up as an
// untracked file in `git status` and in gothalo's own /diff screen.
func TestSaveWritesGitignore(t *testing.T) {
	cwd := t.TempDir()
	if _, err := Save(cwd, pngBytes, fixedClock); err != nil {
		t.Fatalf("Save: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(cwd, ".gothalo", ".gitignore"))
	if err != nil {
		t.Fatalf("read .gitignore: %v", err)
	}
	if strings.TrimSpace(string(body)) != "*" {
		t.Errorf(".gitignore = %q, want \"*\"", body)
	}
}

// TestSaveRejectsRelativeCwd guards the one way a bad cwd could send writes
// somewhere arbitrary: an agent Herdr reports with no (or a relative) directory.
func TestSaveRejectsRelativeCwd(t *testing.T) {
	for _, cwd := range []string{"", "relative/dir", "../up"} {
		if _, err := Save(cwd, pngBytes, fixedClock); err == nil {
			t.Errorf("Save(%q) succeeded, want an error", cwd)
		}
	}
}

// TestSaveLeavesNoTempFiles asserts the write-then-rename leaves the directory
// containing exactly the image (a stray .upload-* would be visible to the user).
func TestSaveLeavesNoTempFiles(t *testing.T) {
	cwd := t.TempDir()
	res, err := Save(cwd, pngBytes, fixedClock)
	if err != nil {
		t.Fatalf("Save: %v", err)
	}
	entries, err := os.ReadDir(filepath.Dir(res.Path))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != filepath.Base(res.Path) {
		t.Errorf("drop dir holds %d entries, want just the image", len(entries))
	}
}

// TestPruneByAge asserts retention drops images past retainAge — measured from
// the name, so the sweep is a pure function of the injected clock.
func TestPruneByAge(t *testing.T) {
	cwd := t.TempDir()
	old, err := Save(cwd, pngBytes, fixedClock.Add(-retainAge-time.Hour))
	if err != nil {
		t.Fatalf("Save old: %v", err)
	}
	fresh, err := Save(cwd, jpegBytes, fixedClock)
	if err != nil {
		t.Fatalf("Save fresh: %v", err)
	}
	if _, err := os.Stat(old.Path); !os.IsNotExist(err) {
		t.Errorf("stale image survived the sweep: %v", err)
	}
	if _, err := os.Stat(fresh.Path); err != nil {
		t.Errorf("fresh image was swept: %v", err)
	}
}

// TestPruneByCount asserts the second bound: a burst inside the age window is
// still capped, so a busy session can't leave hundreds of files in a repo.
func TestPruneByCount(t *testing.T) {
	cwd := t.TempDir()
	dir := filepath.Join(cwd, ".gothalo", "images")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// One image per second, all recent — more than the cap allows.
	total := retainCount + 10
	var paths []string
	for i := range total {
		at := fixedClock.Add(time.Duration(i-total) * time.Second)
		name := at.Format(nameTimeLayout) + "-deadbeef.png"
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, pngBytes, 0o644); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}

	Prune(dir, fixedClock)

	for i, p := range paths {
		_, err := os.Stat(p)
		survived := err == nil
		wantSurvive := i >= total-retainCount
		if survived != wantSurvive {
			t.Errorf("file %d survived=%v, want %v", i, survived, wantSurvive)
		}
	}
}

// TestPruneLeavesForeignFiles is the conservative half of retention: this code
// deletes from inside someone's repository, so anything it did not write — a
// name that doesn't parse — is left strictly alone, however old it looks.
func TestPruneLeavesForeignFiles(t *testing.T) {
	cwd := t.TempDir()
	dir := filepath.Join(cwd, ".gothalo", "images")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	foreign := []string{"notes.png", "19990101-000000.png", "keep-me.txt"}
	for _, n := range foreign {
		if err := os.WriteFile(filepath.Join(dir, n), pngBytes, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	Prune(dir, fixedClock.Add(10*365*24*time.Hour))

	for _, n := range foreign {
		if _, err := os.Stat(filepath.Join(dir, n)); err != nil {
			t.Errorf("%s was deleted: %v", n, err)
		}
	}
}
