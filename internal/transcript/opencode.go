package transcript

// opencodeReader is the seam for opencode transcripts. Like codexReader it is a
// thin stub delegating to the generic reader (Parsed=false) today, so an opencode
// pane already streams safe rows, while documenting the promotion path. It exists
// to demonstrate that adding an agent kind is exactly one new file plus its init()
// Register — the endpoint, the JSON contract, and the claude reader are untouched.
//
// opencode stores sessions differently from Claude Code (it keeps per-session
// message/part records in its own app-data directory rather than a single JSONL
// per session). To promote this to a real reader:
//  1. Locate opencode's session storage on a live machine (its data dir, e.g.
//     under ~/.local/share/opencode/… or the platform data dir) and teach
//     resolve.go an opencode branch keyed off the pane's agent_session — the
//     resolver is per-kind precisely so a non-JSONL layout slots in here.
//  2. Implement Normalize to map opencode's message/part records onto Entry: user
//     and assistant text -> KindMessage, reasoning -> KindThinking, its tool
//     invocations -> KindToolCall (Command/File/Diff via diff.go), and tool
//     outputs -> KindToolResult. Drop metadata; emit Parsed=false for anything
//     unrecognised.
//  3. Add opencode_test.go against a scrubbed captured fixture.
//
// The normalized Entry schema and WS framing do not change — only this file and
// resolve.go's opencode path.
type opencodeReader struct{}

func init() { Register(opencodeReader{}) }

func (opencodeReader) Kind() string { return "opencode" }

// Normalize currently defers to the generic reader (Parsed=false). Replace this
// body with real opencode normalization as described above.
func (opencodeReader) Normalize(line []byte) []Entry { return genericReader{}.Normalize(line) }
