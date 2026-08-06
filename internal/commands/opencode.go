package commands

// opencodeLister is the seam for opencode, and is a stub for the same reason as
// codexLister: opencode has custom commands and its own built-in slash set, but
// where it keeps them on disk has not been verified against a live install.
//
// To promote it: locate opencode's command directory (its config lives outside
// ~/.claude, so it needs its own roots rather than a scope flag on the claude
// walk), map each file to a Command, and list the built-ins. Note that opencode
// models subagents as separate sessions in a SQLite store — if commands live
// there too, this becomes a database read rather than a directory walk, which
// the Lister interface already allows.
type opencodeLister struct{}

func init() { Register(opencodeLister{}) }

func (opencodeLister) Kind() string { return "opencode" }

// List reports no commands — see the type comment.
func (opencodeLister) List(string) ([]Command, error) { return nil, nil }
