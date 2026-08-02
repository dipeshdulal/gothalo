package transcript

// codexReader is the seam for OpenAI Codex CLI transcripts. Like agentstate's
// codex parser it is a thin, honest stub: it delegates to the generic reader (so a
// codex pane already streams safe Parsed=false rows) while documenting exactly
// what a full reader must do. This proves the registry wiring end to end —
// ReaderFor("codex") returns THIS reader, not the bare generic one — without
// shipping a half-guessed format.
//
// Codex does NOT use Claude Code's ~/.claude/projects/<enc-cwd>/<session>.jsonl
// layout. To promote this to a real reader (this file only):
//  1. Locate Codex's transcript/rollout files (Codex CLI writes session rollout
//     files under its own config dir, e.g. ~/.codex/… — confirm the exact path and
//     naming on a live machine, then teach resolve.go a codex branch: the resolver
//     is per-kind, keyed off the pane's agent_session, so only its claude-specific
//     path math needs a codex sibling).
//  2. Implement Normalize to map Codex's line/record format onto Entry: user and
//     assistant messages -> KindMessage, reasoning -> KindThinking, its
//     shell/command and patch/apply tool events -> KindToolCall (fill Command for
//     shell, Diff for patches via the diff.go helpers), and their outputs ->
//     KindToolResult (OK from exit status/error, OutputSummary from captured
//     output). Drop pure-metadata records; emit Parsed=false for anything
//     unrecognised so the tail never breaks.
//  3. Add codex_test.go against a scrubbed captured rollout fixture, like
//     claude_test.go.
//
// The normalized Entry schema and the WS framing do not change — only this file
// and resolve.go's codex path.
type codexReader struct{}

func init() { Register(codexReader{}) }

func (codexReader) Kind() string { return "codex" }

// Normalize currently defers to the generic reader (Parsed=false). Replace this
// body with real Codex normalization as described above.
func (codexReader) Normalize(line []byte) []Entry { return genericReader{}.Normalize(line) }
