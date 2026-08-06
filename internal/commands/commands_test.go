package commands

import (
	"os"
	"path/filepath"
	"testing"
)

// write creates path with content, making parents as needed.
func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// find returns the first command with name, or a zero Command.
func find(cmds []Command, name string) Command {
	for _, c := range cmds {
		if c.Name == name {
			return c
		}
	}
	return Command{}
}

func TestReadFrontmatter(t *testing.T) {
	dir := t.TempDir()

	cases := []struct {
		name    string
		body    string
		want    map[string]string
		absent  []string
		comment string
	}{
		{
			name: "plain",
			body: "---\ndescription: Commit, push, and open a PR\n---\n\nbody\n",
			want: map[string]string{"description": "Commit, push, and open a PR"},
		},
		{
			name: "double quoted, collapsed to one line",
			body: "---\nname: herdr\ndescription: \"Control Herdr, a  multiplexer.\"\n---\n",
			want: map[string]string{"name": "herdr", "description": "Control Herdr, a multiplexer."},
		},
		{
			// A real plugin command: the value itself contains colons, so a
			// naive split on every ":" would mangle it.
			name: "value containing colons",
			body: "---\nallowed-tools: Bash(git add:*), Bash(git push:*)\ndescription: Commit and push\n---\n",
			want: map[string]string{
				"allowed-tools": "Bash(git add:*), Bash(git push:*)",
				"description":   "Commit and push",
			},
		},
		{
			name:   "no frontmatter at all",
			body:   "# Just a prompt\n\ndescription: not frontmatter\n",
			want:   map[string]string{},
			absent: []string{"description"},
		},
		{
			name:   "nested keys are not top-level",
			body:   "---\nmetadata:\n  description: nested\nargument-hint: [pr]\n---\n",
			absent: []string{"description"},
			want:   map[string]string{"argument-hint": "[pr]"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(dir, tc.name+".md")
			write(t, path, tc.body)
			got, err := readFrontmatter(path)
			if err != nil {
				t.Fatalf("readFrontmatter: %v", err)
			}
			for k, want := range tc.want {
				if got[k] != want {
					t.Errorf("key %q = %q, want %q", k, got[k], want)
				}
			}
			for _, k := range tc.absent {
				if _, ok := got[k]; ok {
					t.Errorf("key %q should be absent, got %q", k, got[k])
				}
			}
		})
	}
}

func TestReadFrontmatterMissingFile(t *testing.T) {
	if _, err := readFrontmatter(filepath.Join(t.TempDir(), "nope.md")); err == nil {
		t.Fatal("want an error for a missing file (walkSkills uses it to detect a non-skill dir)")
	}
}

// A nested command file is invoked as /dir:name — the typeahead must offer the
// string that actually works, not the bare filename.
func TestWalkCommandsNamespacesNestedFiles(t *testing.T) {
	root := filepath.Join(t.TempDir(), "commands")
	write(t, filepath.Join(root, "deploy.md"), "---\ndescription: Ship it\nargument-hint: [env]\n---\n")
	write(t, filepath.Join(root, "frontend", "component.md"), "---\ndescription: New component\n---\n")
	write(t, filepath.Join(root, "notes.txt"), "not a command")

	got := walkCommands(root, ScopeProject)
	if len(got) != 2 {
		t.Fatalf("got %d commands, want 2 (the .txt must be ignored): %+v", len(got), got)
	}

	deploy := find(got, "deploy")
	if deploy.Description != "Ship it" || deploy.ArgumentHint != "[env]" {
		t.Errorf("deploy = %+v, want description and argument hint from frontmatter", deploy)
	}
	if deploy.Source != SourceCommand || deploy.Scope != ScopeProject {
		t.Errorf("deploy source/scope = %q/%q, want %q/%q",
			deploy.Source, deploy.Scope, SourceCommand, ScopeProject)
	}
	if c := find(got, "frontend:component"); c.Name == "" {
		t.Errorf("nested command not namespaced as frontend:component, got %+v", got)
	}
}

func TestWalkCommandsMissingRootIsNotAnError(t *testing.T) {
	if got := walkCommands(filepath.Join(t.TempDir(), "absent"), ScopeUser); len(got) != 0 {
		t.Fatalf("want no commands for a missing root, got %+v", got)
	}
}

func TestWalkSkills(t *testing.T) {
	root := filepath.Join(t.TempDir(), "skills")
	// Frontmatter name wins over the directory name.
	write(t, filepath.Join(root, "hr-dir-name", "SKILL.md"),
		"---\nname: hr-attendance\ndescription: Check in and out\n---\n")
	// No name key: fall back to the directory.
	write(t, filepath.Join(root, "herdr", "SKILL.md"), "---\ndescription: Control Herdr\n---\n")
	// A directory with no SKILL.md is not a skill.
	if err := os.MkdirAll(filepath.Join(root, "not-a-skill"), 0o755); err != nil {
		t.Fatal(err)
	}

	got := walkSkills(root, ScopeUser)
	if len(got) != 2 {
		t.Fatalf("got %d skills, want 2: %+v", len(got), got)
	}
	if c := find(got, "hr-attendance"); c.Description != "Check in and out" || c.Source != SourceSkill {
		t.Errorf("hr-attendance = %+v, want frontmatter name to win and source %q", c, SourceSkill)
	}
	if c := find(got, "herdr"); c.Name == "" {
		t.Error("skill with no frontmatter name should fall back to its directory name")
	}
}

// The host's own commands come first and built-ins last, so the list a user sees
// the instant they type "/" leads with what is specific to their machine.
//
// Scope beats source: a PROJECT skill outranks a USER command. The first cut
// bucketed by source and sank a repo's own skill below unrelated user skills —
// only visible in a live capture, hence this case.
func TestSortForDisplayScopeBeatsSource(t *testing.T) {
	got := sortForDisplay([]Command{
		{Name: "clear", Source: SourceBuiltin},
		{Name: "herdr", Source: SourceSkill, Scope: ScopeUser},
		{Name: "user-cmd", Source: SourceCommand, Scope: ScopeUser},
		{Name: "migrations", Source: SourceSkill, Scope: ScopeProject},
		{Name: "proj-cmd", Source: SourceCommand, Scope: ScopeProject},
	})
	want := []string{"proj-cmd", "migrations", "user-cmd", "herdr", "clear"}
	for i, name := range want {
		if got[i].Name != name {
			t.Fatalf("position %d = %q, want %q (full order: %+v)", i, got[i].Name, name, got)
		}
	}
}

// A user command and a project command of the same name are both real and both
// listed; an exact repeat of the same source+scope+name is not.
func TestDedupeKeepsSameNameAcrossScopes(t *testing.T) {
	got := dedupe([]Command{
		{Name: "test", Source: SourceCommand, Scope: ScopeProject},
		{Name: "test", Source: SourceCommand, Scope: ScopeUser},
		{Name: "test", Source: SourceCommand, Scope: ScopeUser},
	})
	if len(got) != 2 {
		t.Fatalf("got %d, want 2 (project + user kept, exact repeat dropped): %+v", len(got), got)
	}
}

func TestListUnknownKind(t *testing.T) {
	if _, err := List("gemini", t.TempDir()); err != ErrUnsupportedKind {
		t.Fatalf("List for an unregistered kind = %v, want ErrUnsupportedKind", err)
	}
}

// Stub kinds are registered — List resolves to their lister rather than
// reporting the kind unknown. This is the extensibility seam; promoting a stub
// must not require touching the endpoint.
func TestRegisteredStubKinds(t *testing.T) {
	for _, kind := range []string{"codex", "opencode"} {
		got, err := List(kind, t.TempDir())
		if err != nil {
			t.Errorf("List(%q) = %v, want no error (a stub reports nothing, it does not fail)", kind, err)
		}
		if len(got) != 0 {
			t.Errorf("List(%q) returned %d commands, want none from a stub", kind, len(got))
		}
	}
}

// The claude lister discovers a project's own commands and skills alongside the
// built-ins, all through the public entry point.
func TestClaudeListDiscoversProjectAndBuiltins(t *testing.T) {
	cwd := t.TempDir()
	write(t, filepath.Join(cwd, ".claude", "commands", "ship.md"), "---\ndescription: Ship it\n---\n")
	write(t, filepath.Join(cwd, ".claude", "skills", "deploy", "SKILL.md"), "---\nname: deploy\ndescription: Deploy\n---\n")

	got, err := List("claude", cwd)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if c := find(got, "ship"); c.Source != SourceCommand || c.Scope != ScopeProject {
		t.Errorf("project command not discovered: %+v", c)
	}
	if c := find(got, "deploy"); c.Source != SourceSkill {
		t.Errorf("project skill not discovered: %+v", c)
	}
	if c := find(got, "compact"); c.Source != SourceBuiltin {
		t.Errorf("built-in /compact missing or mis-sourced: %+v", c)
	}
	// The discovered ones lead.
	if got[0].Source == SourceBuiltin {
		t.Errorf("built-ins should not lead the list, got %+v", got[0])
	}
}

// Every built-in must carry the builtin source — the app badges on it, and an
// unstamped entry would render as a user command.
func TestBuiltinsAreStamped(t *testing.T) {
	for _, c := range claudeBuiltins() {
		if c.Source != SourceBuiltin {
			t.Errorf("built-in %q has source %q, want %q", c.Name, c.Source, SourceBuiltin)
		}
		if c.Scope != "" {
			t.Errorf("built-in %q has scope %q, want empty (it belongs to no directory)", c.Name, c.Scope)
		}
		if c.Description == "" {
			t.Errorf("built-in %q has no description — the typeahead row would be bare", c.Name)
		}
	}
}
