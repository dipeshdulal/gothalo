package transcript

import (
	"errors"
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

	// 2. No session id at all -> newest-matching-cwd fallback (a real file, not error).
	got, err = Locate("claude", cwd, "")
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

// TestLocateClaudeKnownSessionNeverGuesses is the regression for the bug where a
// pane displayed a *different* pane's conversation.
//
// Claude writes a session's .jsonl lazily, so a freshly started agent has a real
// session id (herdr's integration hook reports it at SessionStart) and no file on
// disk yet. Before this fix the miss fell through to the newest-mtime fallback,
// which returned the neighbouring transcript in the same project dir — routing
// was never wrong, but the app rendered the wrong chat. Two agents in one repo
// directory is ordinary, so this fired in normal use.
func TestLocateClaudeKnownSessionNeverGuesses(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/Users/dev/projects/demo"
	dir := filepath.Join(home, ".claude", "projects", EncodeProjectDir(cwd))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// The decoy: another pane's conversation, already written, same project dir.
	decoy := filepath.Join(dir, "99999999-9999-9999-9999-999999999999.jsonl")
	line := `{"type":"user","cwd":"` + cwd + `","message":{"role":"user","content":"other pane"}}` + "\n"
	if err := os.WriteFile(decoy, []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}

	// Our pane: a known session id whose file Claude has not written yet.
	got, err := Locate("claude", cwd, "12345678-1234-1234-1234-123456789abc")
	if err == nil {
		t.Fatalf("want ErrNoTranscript, got path %q (that is the other pane's transcript)", got)
	}
	if !errors.Is(err, ErrNoTranscript) {
		t.Errorf("err = %v, want ErrNoTranscript", err)
	}
	if got == decoy {
		t.Error("returned the decoy transcript — a known session id must never fall back")
	}
}

// TestLocateClaudeMetadataPreamble covers newer Claude Code transcripts that open
// with cwd-less metadata lines (mode, permission-mode, file-history-snapshot)
// before the first cwd-bearing entry — the fallback must still match on cwd.
func TestLocateClaudeMetadataPreamble(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/Users/dev/projects/demo"
	dir := filepath.Join(home, ".claude", "projects", EncodeProjectDir(cwd))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "11111111-2222-3333-4444-555555555555.jsonl")
	content := `{"type":"mode","mode":"default"}
{"type":"permission-mode","mode":"acceptEdits"}
{"type":"file-history-snapshot","snapshot":{}}
{"type":"user","cwd":"` + cwd + `","message":{"role":"user","content":"hi"}}
`
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := Locate("claude", cwd, "")
	if err != nil {
		t.Fatalf("Locate with metadata preamble: %v", err)
	}
	if got != p {
		t.Errorf("Locate = %q, want %q", got, p)
	}
}

func TestLocateUnsupportedKind(t *testing.T) {
	for _, k := range []string{"codex", "opencode", "some-future-agent"} {
		if _, err := Locate(k, "/tmp/x", "sid"); err == nil {
			t.Errorf("Locate(%q) err = nil, want ErrUnsupportedKind", k)
		}
	}
}
