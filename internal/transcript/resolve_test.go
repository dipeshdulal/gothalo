package transcript

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEncodeProjectDir(t *testing.T) {
	cases := map[string]string{
		"/Users/x/projects/foo":         "-Users-x-projects-foo",
		"/Users/x/.herdr/worktrees/foo": "-Users-x--herdr-worktrees-foo", // "/." -> "--"
		"/Users/x/projects/a.b.c":       "-Users-x-projects-a-b-c",       // dots -> dashes
		"/Users/dev/projects/demo":      "-Users-dev-projects-demo",
		"/tmp/feat-agent-transcript":    "-tmp-feat-agent-transcript", // existing dashes kept
	}
	for in, want := range cases {
		if got := EncodeProjectDir(in); got != want {
			t.Errorf("EncodeProjectDir(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestLocateClaude builds a fake ~/.claude/projects tree under a temp HOME and
// exercises the three resolution paths: direct session-id hit, the newest-matching
// fallback, and no-transcript.
func TestLocateClaude(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/Users/dev/projects/demo"
	dir := filepath.Join(home, ".claude", "projects", EncodeProjectDir(cwd))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Two sessions in the same project dir; both record the project cwd.
	write := func(name, cwdField string) string {
		p := filepath.Join(dir, name)
		line := `{"type":"user","sessionId":"` + name + `","cwd":"` + cwdField + `","message":{"role":"user","content":"hi"}}` + "\n"
		if err := os.WriteFile(p, []byte(line), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	sess := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	direct := write(sess+".jsonl", cwd)
	write("00000000-0000-0000-0000-000000000000.jsonl", cwd)

	// 1. Direct session-id hit.
	got, err := Locate("claude", cwd, sess)
	if err != nil {
		t.Fatalf("Locate direct: %v", err)
	}
	if got != direct {
		t.Errorf("direct hit = %q, want %q", got, direct)
	}

	// 2. Unknown session id -> newest-matching-cwd fallback (a real file, not error).
	got, err = Locate("claude", cwd, "nonexistent-session")
	if err != nil {
		t.Fatalf("Locate fallback: %v", err)
	}
	if filepath.Dir(got) != dir {
		t.Errorf("fallback returned %q, want a file in %q", got, dir)
	}

	// 3. A cwd with no project dir at all -> ErrNoTranscript.
	if _, err := Locate("claude", "/Users/dev/projects/nope", ""); err == nil {
		t.Error("Locate for missing project dir: want error, got nil")
	}
}

func TestLocateUnsupportedKind(t *testing.T) {
	for _, k := range []string{"codex", "opencode", "some-future-agent"} {
		if _, err := Locate(k, "/tmp/x", "sid"); err == nil {
			t.Errorf("Locate(%q) err = nil, want ErrUnsupportedKind", k)
		}
	}
}
