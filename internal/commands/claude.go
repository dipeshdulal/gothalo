package commands

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// claudeLister lists what Claude Code accepts after a "/": the user's own
// markdown commands and skills, discovered from disk, plus the built-ins that
// live inside the binary.
type claudeLister struct{}

func init() { Register(claudeLister{}) }

func (claudeLister) Kind() string { return "claude" }

// List walks the four discovery roots and appends the built-ins.
//
// Order of the walk is the display order before dedupe (project before user,
// commands before skills); sortForDisplay has the final say.
//
// A missing root is normal, not an error — most projects have no
// .claude/commands — so every step ignores fs.ErrNotExist and keeps going. The
// method only fails if it cannot even resolve the home directory, which would
// make every root meaningless.
func (claudeLister) List(cwd string) ([]Command, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}

	var out []Command
	if cwd != "" {
		out = append(out, walkCommands(filepath.Join(cwd, ".claude", "commands"), ScopeProject)...)
		out = append(out, walkSkills(filepath.Join(cwd, ".claude", "skills"), ScopeProject)...)
	}
	out = append(out, walkCommands(filepath.Join(home, ".claude", "commands"), ScopeUser)...)
	out = append(out, walkSkills(filepath.Join(home, ".claude", "skills"), ScopeUser)...)
	out = append(out, claudeBuiltins()...)

	return dedupe(out), nil
}

// walkCommands turns a .claude/commands tree into commands. A nested file is
// namespaced by its directories the way Claude Code invokes it —
// commands/frontend/component.md is /frontend:component — so the typeahead
// offers the string that actually works.
func walkCommands(root, scope string) []Command {
	var out []Command
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// Unreadable subtree (permissions, a broken link): skip it, keep the
			// rest. Never abort the whole walk over one bad entry.
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			if path == root {
				return nil
			}
			if depthBelow(root, path) >= maxDepth {
				return fs.SkipDir
			}
			return nil
		}
		if !strings.EqualFold(filepath.Ext(d.Name()), ".md") {
			return nil
		}
		rel, relErr := filepath.Rel(root, path)
		if relErr != nil {
			return nil
		}
		name := strings.TrimSuffix(filepath.ToSlash(rel), filepath.Ext(rel))
		name = strings.ReplaceAll(name, "/", ":")
		if name == "" {
			return nil
		}
		fm, _ := readFrontmatter(path)
		out = append(out, Command{
			Name:         name,
			Description:  fm["description"],
			ArgumentHint: fm["argument-hint"],
			Source:       SourceCommand,
			Scope:        scope,
		})
		return nil
	})
	return out
}

// walkSkills turns a .claude/skills directory into commands. A skill is one
// subdirectory holding a SKILL.md whose frontmatter carries the name and
// description; it is invoked as /<name>, so it belongs in the same typeahead as
// a markdown command even though it is a different thing underneath.
//
// Only one level down: skills nest their own supporting files (references/,
// scripts/) and none of those are invocable.
func walkSkills(root, scope string) []Command {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	var out []Command
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		path := filepath.Join(root, e.Name(), "SKILL.md")
		fm, err := readFrontmatter(path)
		if err != nil {
			continue // no SKILL.md — not a skill directory
		}
		// Frontmatter `name` is authoritative (it is what the agent registers),
		// with the directory name as the fallback when it is missing.
		name := fm["name"]
		if name == "" {
			name = e.Name()
		}
		out = append(out, Command{
			Name:        name,
			Description: fm["description"],
			Source:      SourceSkill,
			Scope:       scope,
		})
	}
	return out
}

// depthBelow reports how many directory levels path sits below root.
func depthBelow(root, path string) int {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return maxDepth
	}
	return len(strings.Split(filepath.ToSlash(rel), "/"))
}

// claudeBuiltins is the hand-maintained list of Claude Code's own slash
// commands.
//
// This is the ONE part of the package not derived from the host, and it can
// drift: built-ins are compiled into the CLI, there is no manifest on disk to
// read, and `claude --help` does not enumerate them. Treated accordingly —
// entries are marked SourceBuiltin so the app can badge them as "built-in", and
// the cost of a stale entry is a typeahead row that the agent answers with
// "unknown command", not a broken screen.
//
// Curated for a PHONE, not exhaustive. Commands that only make sense at the
// machine you are sitting at — terminal-setup, vim mode, statusline, login and
// logout, doctor — are left out on purpose: offering them on a remote composer
// is noise at best and a way to log your bridge's agent out at worst. Add one
// here if you find yourself wanting it from the phone.
func claudeBuiltins() []Command {
	// Source is stamped below rather than repeated on every line — twenty
	// identical fields is exactly where a copy-paste miss hides.
	out := []Command{
		{Name: "clear", Description: "Clear the conversation history and start fresh"},
		{Name: "compact", Description: "Summarize the conversation to free up context", ArgumentHint: "[instructions]"},
		{Name: "context", Description: "Show what is currently using the context window"},
		{Name: "cost", Description: "Show token usage and cost for this session"},
		{Name: "model", Description: "Change the model for this session", ArgumentHint: "[model]"},
		{Name: "status", Description: "Show account, model and connection status"},
		{Name: "usage", Description: "Show plan usage and rate limits"},
		{Name: "resume", Description: "Resume a previous conversation"},
		{Name: "rewind", Description: "Restore the conversation or code to an earlier point"},
		{Name: "todos", Description: "Show the current todo list"},
		{Name: "agents", Description: "View and manage subagents"},
		{Name: "memory", Description: "Edit memory files"},
		{Name: "permissions", Description: "View and edit tool permissions"},
		{Name: "hooks", Description: "View and manage hooks"},
		{Name: "mcp", Description: "View and manage MCP servers"},
		{Name: "config", Description: "Open the settings panel"},
		{Name: "init", Description: "Create or refresh CLAUDE.md for this repo"},
		{Name: "review", Description: "Review a pull request", ArgumentHint: "[pr]"},
		{Name: "export", Description: "Export the conversation"},
		{Name: "help", Description: "List the available commands"},
	}
	for i := range out {
		out[i].Source = SourceBuiltin
	}
	return out
}
