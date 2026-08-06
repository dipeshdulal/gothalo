package commands

// codexLister is the seam for OpenAI Codex CLI. Like transcript's and
// agentstate's codex parsers it is a thin, honest stub: registered, so
// List("codex", …) resolves to THIS lister rather than falling through to
// ErrUnsupportedKind, but reporting nothing rather than guessing.
//
// Codex does have a prompt/command surface — its CLI reads user prompt files
// from its own config dir (~/.codex/…) — but the exact directory, file
// extension and frontmatter keys must be read off a live machine before they are
// encoded here. Guessing produces a typeahead that offers commands the agent
// will reject, which is worse than no typeahead at all: the whole point of this
// endpoint is that what it lists actually works.
//
// To promote this to a real lister (this file only): confirm the prompts
// directory on a machine with Codex installed, walk it the way walkCommands
// walks .claude/commands, and add the built-ins Codex compiles in. The Command
// shape, the endpoint and the app do not change.
type codexLister struct{}

func init() { Register(codexLister{}) }

func (codexLister) Kind() string { return "codex" }

// List reports no commands. Not an error — a codex pane simply gets no
// typeahead, and the composer stays a plain text field.
func (codexLister) List(string) ([]Command, error) { return nil, nil }
