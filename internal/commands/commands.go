// Package commands lists the slash commands an agent in a pane will actually
// accept, so the phone composer can offer a typeahead instead of asking the user
// to remember and thumb-type "/compact".
//
// The design mirrors internal/transcript and internal/agentstate: a per-kind
// Lister (claude today; codex and opencode are honest stubs) reports what its
// agent understands, and the endpoint, the JSON contract, and existing listers
// stay untouched when a kind is added. Adding an agent is one new file that
// implements Lister and calls Register in its init.
//
// Two sources, and the difference matters:
//
//   - DISCOVERED — read off the host's disk right now (custom commands under
//     .claude/commands, skills under .claude/skills). These are ground truth:
//     if the file is there the command exists, and if the user adds one it shows
//     up on the next fetch with no release of anything.
//   - BUILT-IN — compiled into the agent's own binary, so there is nothing on
//     disk to read. Unavoidably a hand-maintained list (see claude.go), and the
//     one part of this feature that can drift from reality.
//
// Listing is read-only and side-effect-free: it opens files under a known set of
// roots and never executes an agent or shells out.
package commands

import (
	"errors"
	"sort"
	"strings"
)

// Source says where a command came from, which is exactly the badge the app
// renders beside it. Kept as a small closed set rather than free text so the
// client can style it without string-matching.
const (
	// SourceBuiltin is compiled into the agent — no file backs it.
	SourceBuiltin = "builtin"
	// SourceCommand is a user-authored markdown command (.claude/commands/*.md).
	SourceCommand = "command"
	// SourceSkill is a skill directory (.claude/skills/<name>/SKILL.md).
	SourceSkill = "skill"
)

// Scope says which .claude directory a discovered command came from. Empty for
// SourceBuiltin, which belongs to no directory.
const (
	// ScopeUser is the home-directory config (~/.claude/…) — every project.
	ScopeUser = "user"
	// ScopeProject is the agent's own working directory (<cwd>/.claude/…).
	ScopeProject = "project"
)

// maxCommands caps one response. A .claude/commands tree is normally a handful
// of files, but this is a directory walk over a path the bridge does not
// control, so it is bounded rather than trusted. Hit only by something
// pathological, and a truncated list still beats a stalled composer.
const maxCommands = 500

// maxDepth bounds how deep the commands walk goes below .claude/commands.
// Claude Code namespaces a nested command by its directory (frontend/x.md ->
// /frontend:x); three levels is far past any real layout.
const maxDepth = 3

// Command is one entry in the composer's typeahead.
type Command struct {
	// Name is the invocation WITHOUT the leading slash — "compact",
	// "frontend:component". The app prepends "/" when it inserts.
	Name string `json:"name"`
	// Description is the one-line summary shown beside the name. From the file's
	// frontmatter for discovered commands; hand-written for built-ins. May be
	// empty — a command with no description is still perfectly invocable, so an
	// empty string must not be treated as a parse failure.
	Description string `json:"description,omitempty"`
	// ArgumentHint is the frontmatter `argument-hint`, e.g. "[pr-number]", shown
	// dimmed after the name so the user knows the command wants an argument.
	ArgumentHint string `json:"argument_hint,omitempty"`
	// Source is builtin | command | skill.
	Source string `json:"source"`
	// Scope is user | project for discovered commands, empty for built-ins.
	Scope string `json:"scope,omitempty"`
}

// Lister reports the slash commands one agent kind accepts in a given working
// directory. Implementations are pure reads and must never return a partial
// error for a missing directory — a project with no .claude/commands simply has
// no project commands, which is not a failure.
type Lister interface {
	// Kind is the herdr agent kind this lister serves ("claude", "codex", …).
	Kind() string
	// List returns the commands available to an agent running in cwd.
	List(cwd string) ([]Command, error)
}

// ErrUnsupportedKind means the agent kind has a lister stub but no known command
// surface yet. Callers render it as "no typeahead here", not as an error — see
// the handler, which answers 200 with an empty list.
var ErrUnsupportedKind = errors.New("slash commands not known for this agent kind")

var registry = map[string]Lister{}

// Register wires a Lister into the per-kind registry. Called from each lister's
// init; panics on a duplicate kind, which can only be a programming error.
func Register(l Lister) {
	if _, dup := registry[l.Kind()]; dup {
		panic("commands: duplicate lister for kind " + l.Kind())
	}
	registry[l.Kind()] = l
}

// List returns the slash commands for an agent of kind running in cwd, sorted
// for display. An unregistered kind yields ErrUnsupportedKind — the caller
// decides whether that is worth surfacing (it is not; the app just hides the
// typeahead).
func List(kind, cwd string) ([]Command, error) {
	l, ok := registry[strings.ToLower(strings.TrimSpace(kind))]
	if !ok {
		return nil, ErrUnsupportedKind
	}
	cmds, err := l.List(cwd)
	if err != nil {
		return nil, err
	}
	return sortForDisplay(cmds), nil
}

// Kinds returns the registered kinds, sorted. Used by tests to prove the
// registry wiring rather than by the endpoint.
func Kinds() []string {
	out := make([]string, 0, len(registry))
	for k := range registry {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// sortForDisplay orders the list the way the composer shows it before the user
// has typed anything past "/":
//
//	project commands, project skills, user commands, user skills, built-ins
//
// SCOPE is the primary key, source only the tiebreak. A thing installed in the
// repo the agent is working in is more likely to be what you want than a generic
// one from your home directory, whichever kind it is — sorting by source first
// buried a project's own skill under unrelated user skills, which is exactly
// backwards. (Caught by the live capture in CONTRACT-commands.md, not by the
// first round of tests.)
//
// Built-ins come last throughout: they are many and generic, and burying them
// costs nothing because the moment a letter is typed the client re-ranks by
// prefix anyway.
func sortForDisplay(cmds []Command) []Command {
	scopeRank := func(c Command) int {
		switch c.Scope {
		case ScopeProject:
			return 0
		case ScopeUser:
			return 1
		default: // built-in — belongs to no directory
			return 2
		}
	}
	sourceRank := func(c Command) int {
		if c.Source == SourceSkill {
			return 1
		}
		return 0
	}
	out := append([]Command(nil), cmds...)
	sort.SliceStable(out, func(i, j int) bool {
		if ri, rj := scopeRank(out[i]), scopeRank(out[j]); ri != rj {
			return ri < rj
		}
		if ri, rj := sourceRank(out[i]), sourceRank(out[j]); ri != rj {
			return ri < rj
		}
		return out[i].Name < out[j].Name
	})
	if len(out) > maxCommands {
		out = out[:maxCommands]
	}
	return out
}

// dedupe drops a later command whose name AND source already appeared. A user
// command and a project command of the same name are BOTH kept: Claude Code
// resolves that collision itself, and hiding one would misrepresent what the
// host has.
func dedupe(cmds []Command) []Command {
	seen := make(map[string]bool, len(cmds))
	out := cmds[:0]
	for _, c := range cmds {
		key := c.Source + "\x00" + c.Scope + "\x00" + c.Name
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, c)
	}
	return out
}
