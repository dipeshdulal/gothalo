package transcript

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// piReader normalizes a pi coding-agent JSONL transcript. pi writes one JSON
// object per line into ~/.pi/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl.
// The record types are `session` (metadata: cwd, version), `model_change` and
// `thinking_level_change` (session plumbing), `custom` (extension events such as
// web-search results, with no role/parent), and `message` — the conversation.
//
// A message line carries its own id/parentId/timestamp plus a `message` object:
//
//	{"type":"message","id":"54fce58a","parentId":"29eb3d71",
//	 "timestamp":"2026-08-09T05:40:41.637Z",
//	 "message":{"role":"user","content":[{"type":"text","text":"read one image."}],"timestamp":1786254041634}}
//
// Assistant content is an array of typed blocks (text, thinking, toolCall,
// image); user content is the same. Unlike Claude, tool results are NOT blocks
// inside a user message — they are their own message with role "toolResult",
// keyed to the tool call by toolCallId, and carrying isError plus (for edit /
// write) a `details.diff` unified diff of the applied change.
//
// Metadata-only records are dropped; anything we can't place becomes a
// Parsed=false passthrough so the tail never breaks. See CONTRACT.md for the
// wire shape and captured examples.
type piReader struct{}

func init() { Register(piReader{}); RegisterOpener(piOpener{}) }

func (piReader) Kind() string { return "pi" }

// piOpener resolves a pi pane to its session file (see locatePi) and serves it
// as a fileSource. The path math lives in resolve.go; this is only the registry
// wiring plus the not-yet-written session case.
type piOpener struct{}

func (piOpener) Kind() string { return "pi" }

func (piOpener) Open(cwd, sessionID string) (Source, error) {
	path, err := Locate("pi", cwd, sessionID)
	if err == nil {
		return newFileSource(path, piReader{}), nil
	}
	if !errors.Is(err, ErrNoTranscript) || sessionID == "" {
		return nil, err
	}

	// A session we can NAME but whose file is not on disk yet is a real, healthy
	// agent that simply has not spoken — pi creates the .jsonl when the first
	// message lands (verified: session files carry a `session` header from the
	// start, but the file itself only appears once the agent turns). Failing
	// here would 404 a brand-new pane, which the app can only render as an
	// error. Point a source at where the file WILL be instead: it reports an
	// empty transcript now and streams entries the moment pi writes it.
	if pending := pendingPiPath(cwd, sessionID); pending != "" {
		return newFileSource(pending, piReader{}), nil
	}
	return nil, err
}

// pendingPiPath is where pi will write this session once it has something to
// record. The session id herdr reports IS the full path, so that path is
// returned directly. A bare uuid names no file pi will ever write (filenames are
// <timestamp>_<uuid>.jsonl), so only the full-path case is answerable.
func pendingPiPath(cwd, sessionID string) string {
	if strings.HasSuffix(sessionID, ".jsonl") {
		return sessionID
	}
	return ""
}

// piDropped are record types that are pure session metadata / plumbing — not
// part of the conversation. `custom` is dropped too: verified against live
// transcripts it carries extension events (web-search results) with no role and
// no conversation position — useful context, but it has no place in a threaded
// chat and rendering it would need a schema of its own.
var piDropped = map[string]bool{
	"session":               true,
	"model_change":          true,
	"thinking_level_change": true,
	"custom":                true,
}

// piLine is the subset of a transcript line the reader reads.
type piLine struct {
	Type      string     `json:"type"`
	ID        string     `json:"id"`
	ParentID  string     `json:"parentId"`
	Timestamp string     `json:"timestamp"`
	Message   *piMessage `json:"message"`
}

// piMessage is the nested `message` object. Tool results (role "toolResult")
// fill ToolCallID/ToolName/IsError/Details; the others leave them zero.
type piMessage struct {
	Role       string          `json:"role"`
	ToolCallID string          `json:"toolCallId"`
	ToolName   string          `json:"toolName"`
	Content    json.RawMessage `json:"content"` // []piBlock
	IsError    bool            `json:"isError"`
	Details    json.RawMessage `json:"details"`
}

// piBlock is one content block (assistant or user). Only the fields relevant to
// a given block Type are populated.
type piBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`      // text
	Thinking  string          `json:"thinking"`  // thinking
	ID        string          `json:"id"`        // toolCall
	Name      string          `json:"name"`      // toolCall
	Arguments json.RawMessage `json:"arguments"` // toolCall
}

func (piReader) Normalize(line []byte) []Entry {
	var l piLine
	if err := json.Unmarshal(line, &l); err != nil {
		// Not JSON we understand — never drop the stream, pass through minimally.
		return []Entry{{ID: "", Role: RoleSystem, Kind: KindMessage, Parsed: false}}
	}
	if piDropped[l.Type] {
		return nil
	}

	switch l.Type {
	case "message":
		if l.Message == nil {
			return []Entry{l.base(0, RoleSystem, KindMessage, false)}
		}
		switch l.Message.Role {
		case "user":
			return l.userEntries()
		case "assistant":
			return l.assistantEntries()
		case "toolResult":
			return l.toolResultEntries()
		}
		return []Entry{l.base(0, piRole(l.Message.Role), KindMessage, false)}
	default:
		// A known-shaped but unhandled type: emit a minimal passthrough so the
		// app learns something arrived, without guessing its meaning.
		return []Entry{l.base(0, RoleSystem, KindMessage, false)}
	}
}

// base builds an Entry pre-filled with the shared identity/threading fields. idx
// is the block index within the line (for a unique id when a line expands into
// several entries).
func (l piLine) base(idx int, role, kind string, parsed bool) Entry {
	id := l.ID
	if id != "" {
		id = fmt.Sprintf("%s#%d", l.ID, idx)
	}
	return Entry{
		ID:       id,
		ParentID: l.ParentID,
		TS:       l.Timestamp,
		Role:     role,
		Kind:     kind,
		Parsed:   parsed,
	}
}

// piRole maps a message role onto the contract's role enum. Tool results are
// part of the user turn, like Claude's inline tool_result blocks.
func piRole(role string) string {
	switch role {
	case "user":
		return RoleUser
	case "assistant":
		return RoleAssistant
	case "toolResult":
		return RoleUser
	}
	return RoleSystem
}

func (l piLine) userEntries() []Entry {
	if l.Message == nil {
		return []Entry{l.base(0, RoleUser, KindMessage, false)}
	}
	var out []Entry
	for i, b := range l.blocks() {
		switch b.Type {
		case "text":
			if t := strings.TrimSpace(b.Text); t != "" {
				e := l.base(i, RoleUser, KindMessage, true)
				e.Text, _ = truncateRunes(t, maxInlineTextRunes)
				out = append(out, e)
			}
		case "image":
			e := l.base(i, RoleUser, KindAttachment, true)
			e.Text = "[image]"
			out = append(out, e)
		default:
			out = append(out, l.base(i, RoleUser, KindMessage, false))
		}
	}
	return out
}

func (l piLine) assistantEntries() []Entry {
	blocks := l.blocks()
	if len(blocks) == 0 {
		// An assistant turn with no recorded content (e.g. an aborted or
		// failed generation) has nothing to show.
		return nil
	}
	var out []Entry
	for i, b := range blocks {
		switch b.Type {
		case "text":
			if t := strings.TrimSpace(b.Text); t != "" {
				e := l.base(i, RoleAssistant, KindMessage, true)
				e.Text, _ = truncateRunes(t, maxInlineTextRunes)
				out = append(out, e)
			}
		case "thinking":
			if t := strings.TrimSpace(b.Thinking); t != "" {
				e := l.base(i, RoleAssistant, KindThinking, true)
				e.Text, _ = truncateRunes(t, maxInlineTextRunes)
				out = append(out, e)
			}
		case "toolCall":
			e := l.base(i, RoleAssistant, KindToolCall, true)
			e.Tool = piTool(b)
			out = append(out, e)
		case "image":
			e := l.base(i, RoleAssistant, KindAttachment, true)
			e.Text = "[image]"
			out = append(out, e)
		default:
			out = append(out, l.base(i, RoleAssistant, KindMessage, false))
		}
	}
	return out
}

func (l piLine) toolResultEntries() []Entry {
	if l.Message == nil {
		return []Entry{l.base(0, RoleUser, KindToolResult, false)}
	}
	e := l.base(0, RoleUser, KindToolResult, true)
	r := &Result{ForID: l.Message.ToolCallID, OK: !l.Message.IsError}

	// edit/write carry the authoritative applied diff in details.diff.
	if det := l.appliedDiff(); det != "" {
		r.Diff, r.Truncated = capDiff(det)
	}

	if parts := l.textParts(); len(parts) > 0 {
		out := strings.Join(parts, "\n")
		capped, cut := truncateRunes(stripANSI(out), maxOutputRunes)
		r.OutputSummary = capped
		r.Truncated = r.Truncated || cut
	}
	e.Result = r
	return []Entry{e}
}

// ---- tool call / result projection ----

// piTool projects a toolCall block onto the render-friendly Tool shape.
func piTool(b piBlock) *Tool {
	t := &Tool{ID: b.ID, Name: b.Name, Title: b.Name}
	switch b.Name {
	case "bash":
		var in struct {
			Command string `json:"command"`
		}
		_ = json.Unmarshal(b.Arguments, &in)
		t.Command = in.Command
		t.InputSummary = oneLine(in.Command, 200)
	case "edit":
		var in struct {
			Path  string            `json:"path"`
			Edits []piEditReplacement `json:"edits"`
		}
		_ = json.Unmarshal(b.Arguments, &in)
		t.File = base(in.Path)
		t.InputSummary = in.Path
		// The applied diff rides on the paired tool_result's details.diff; the
		// first old/new pair here is only a best-effort preview, like Claude's.
		for _, e := range in.Edits {
			if e.OldText != "" || e.NewText != "" {
				t.Diff, t.DiffTruncated = diffFromEditInput(e.OldText, e.NewText)
				break
			}
		}
	case "write":
		var in struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		}
		_ = json.Unmarshal(b.Arguments, &in)
		t.File = base(in.Path)
		t.InputSummary = in.Path
		t.Diff, t.DiffTruncated = diffAllAdded(in.Content)
	case "read":
		var in struct {
			Path string `json:"path"`
		}
		_ = json.Unmarshal(b.Arguments, &in)
		t.File = base(in.Path)
		t.InputSummary = in.Path
	default:
		// Any other tool: a compact one-line summary of its input is always
		// renderable.
		t.InputSummary = oneLine(string(b.Arguments), 200)
	}
	return t
}

// piEditReplacement is one `edits[]` entry of the edit tool.
type piEditReplacement struct {
	OldText string `json:"oldText"`
	NewText string `json:"newText"`
}

// blocks decodes the message content as an array of blocks, tolerating a missing
// or non-array content (returns nil).
func (l piLine) blocks() []piBlock {
	if l.Message == nil {
		return nil
	}
	var bs []piBlock
	_ = json.Unmarshal(l.Message.Content, &bs)
	return bs
}

// appliedDiff extracts the authoritative unified diff from a tool result's
// details object (edit/write carry it there), or "" when absent.
func (l piLine) appliedDiff() string {
	if l.Message == nil {
		return ""
	}
	var det struct {
		Diff string `json:"diff"`
	}
	_ = json.Unmarshal(l.Message.Details, &det)
	return strings.TrimSpace(det.Diff)
}

// textParts gathers readable text (and image placeholders) from the content
// blocks, in order.
func (l piLine) textParts() []string {
	var parts []string
	for _, b := range l.blocks() {
		switch b.Type {
		case "text":
			if t := strings.TrimSpace(b.Text); t != "" {
				parts = append(parts, t)
			}
		case "image":
			parts = append(parts, "[image]")
		}
	}
	return parts
}

// capDiff truncates an already-rendered unified diff to the standard diff caps,
// reporting whether it was cut. Used for tool results that carry a diff string
// (pi's details.diff) rather than the structured hunks Claude produces.
func capDiff(s string) (string, bool) {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	truncated := len(lines) > maxDiffLines
	if truncated {
		lines = lines[:maxDiffLines]
	}
	out, cut := truncateRunes(strings.Join(lines, "\n"), maxDiffRunes)
	return out, truncated || cut
}

// piSessionsRoot returns ~/.pi/agent/sessions.
func piSessionsRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".pi", "agent", "sessions"), nil
}

// EncodePiSessionDir maps a project cwd to pi's session-directory name.
//
// pi stores each session as
//
//	~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<uuid>.jsonl
//
// where <encoded-cwd> is the absolute cwd with the leading separator stripped,
// every "/" (and "\" and ":" on Windows) replaced by "-", wrapped in "--" on
// both sides. Verified against pi's session-manager source (getDefaultSessionDirPath)
// and live directories:
//
//	/Users/alex/projects/gothalo  ->  --Users-alex-projects-gothalo--
//
// Note the difference from Claude Code's encoding (EncodeProjectDir): "." is NOT
// replaced, and the dir is wrapped rather than the path being mapped in place.
func EncodePiSessionDir(cwd string) string {
	s := cwd
	if strings.HasPrefix(s, "/") || strings.HasPrefix(s, "\\") {
		s = s[1:]
	}
	s = strings.NewReplacer("/", "-", "\\", "-", ":", "-").Replace(s)
	return "--" + s + "--"
}
