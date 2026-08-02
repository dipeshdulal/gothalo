package agentstate

// codexParser is the seam for OpenAI Codex CLI. It is intentionally a thin stub:
// it delegates to the generic fallback (so a codex pane already returns a safe,
// renderable card with Parsed=false) while documenting exactly what a full parser
// must fill in. This proves the registry wiring end to end — parserFor("codex")
// returns THIS parser, not the generic one — without shipping a half-tuned parser
// that guesses at Codex's layout.
//
// To promote it to a real parser, no endpoint/contract/other-parser change is
// needed — only this file:
//  1. Capture live output: `herdr agent read <codexPane> --source detection
//     --format text` and `--source recent-unwrapped`, across idle/working/
//     blocked/done (see how claude.go's testdata was captured).
//  2. Implement Parse to fill Headline, Detail, Blocked, Transcript and set
//     Parsed=true, using Codex's own markers:
//     - assistant/message lines and how Codex fences its tool calls,
//     - its in-progress spinner/working indicator,
//     - its approval prompt shape (Codex asks to run commands / apply patches):
//     map the question + choices onto Blocked{Question, Options}. Reuse
//     numberedOptionRE / scanBlocked if the choices are a numbered list;
//     otherwise add a codex-specific scanner here.
//  3. Add a codex_test.go table test against captured testdata, like claude_test.go.
//
// The confirm keystroke for approvals already exists separately in
// internal/server/approve.go (confirmKeys["codex"]); this parser only supplies
// the *presentation* of the blocked prompt.
type codexParser struct{}

func init() { Register(codexParser{}) }

func (codexParser) Kind() string { return "codex" }

// Parse currently defers to the generic fallback (Parsed=false). Replace this
// body with real Codex extraction as described above.
func (codexParser) Parse(in Input) State { return genericParser{}.Parse(in) }
