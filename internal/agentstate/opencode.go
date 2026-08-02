package agentstate

// opencodeParser is the seam for opencode. Like codexParser it is a thin stub
// that delegates to the generic fallback (Parsed=false) today, so an opencode
// pane already returns a safe card, while documenting the promotion path. It
// exists to demonstrate that adding an agent kind is exactly one new file plus
// its init() Register — the endpoint, the JSON contract, and the claude parser
// are untouched.
//
// To promote it to a real parser (this file only):
//  1. Capture live opencode output across idle/working/blocked/done via
//     `herdr agent read <pane> --source detection|recent-unwrapped --format text`.
//  2. Implement Parse to fill Headline, Detail, Blocked, Transcript and set
//     Parsed=true using opencode's markers:
//     - how it prints assistant messages vs tool/permission activity,
//     - its working indicator,
//     - its permission/confirm prompt shape -> Blocked{Question, Options}
//     (reuse scanBlocked/numberedOptionRE when the choices are numbered).
//  3. Add opencode_test.go against captured testdata.
//
// The approval confirm keystroke lives in internal/server/approve.go
// (confirmKeys["opencode"]); this parser only shapes the blocked presentation.
type opencodeParser struct{}

func init() { Register(opencodeParser{}) }

func (opencodeParser) Kind() string { return "opencode" }

// Parse currently defers to the generic fallback (Parsed=false). Replace this
// body with real opencode extraction as described above.
func (opencodeParser) Parse(in Input) State { return genericParser{}.Parse(in) }
