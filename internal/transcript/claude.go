package transcript

import (
	"encoding/json"
	"fmt"
	"strings"
)

// claudeReader normalizes a Claude Code JSONL transcript. Claude writes one JSON
// object per line; the relevant ones carry uuid/parentUuid/timestamp and a
// `message` {role, content}. Assistant content is an array of typed blocks (text,
// thinking, tool_use); user content is a string or an array (text, tool_result,
// image). Tool results also appear as a richer top-level `toolUseResult` on the
// following user line — we prefer it for diffs (Edit/Write carry a structuredPatch)
// and structured stdout/stderr. Metadata-only lines (ai-title, mode, …) are
// dropped; anything we can't place becomes a Parsed=false passthrough so the tail
// never breaks. See CONTRACT.md for the wire shape and captured examples.
type claudeReader struct{}

func init() { Register(claudeReader{}); RegisterOpener(claudeOpener{}) }

func (claudeReader) Kind() string { return "claude" }

// claudeOpener resolves a Claude pane to its JSONL file (see Locate) and serves
// it as a fileSource. The path math lives in resolve.go; this is only the
// registry wiring.
type claudeOpener struct{}

func (claudeOpener) Kind() string { return "claude" }

func (claudeOpener) Open(cwd, sessionID string) (Source, error) {
	path, err := Locate("claude", cwd, sessionID)
	if err != nil {
		return nil, err
	}
	return newFileSource(path, claudeReader{}), nil
}

// claudeIgnored are entry types that are pure session metadata / plumbing — not
// part of the conversation. They are dropped (Normalize returns no entries).
//
// "attachment" is dropped here too: verified against live transcripts, top-level
// attachment lines are Claude Code IDE/runtime deltas (task_reminder,
// queued_command, agent_listing_delta, skill_listing, plan_mode, …), never
// conversation content. Genuine user attachments (pasted images) arrive instead as
// `image` content blocks inside a user message and DO surface (KindAttachment).
var claudeIgnored = map[string]bool{
	"ai-title":              true,
	"agent-name":            true,
	"mode":                  true,
	"permission-mode":       true,
	"file-history-snapshot": true,
	"file-history-delta":    true,
	"last-prompt":           true,
	"queue-operation":       true,
	"pr-link":               true,
	"attachment":            true,
}

// claudeLine is the subset of a transcript line the reader reads. Fields that vary
// in shape (message content, tool result, system content, attachment) stay as
// RawMessage and are decoded per type.
type claudeLine struct {
	Type          string          `json:"type"`
	UUID          string          `json:"uuid"`
	ParentUUID    string          `json:"parentUuid"`
	Timestamp     string          `json:"timestamp"`
	Message       *claudeMessage  `json:"message"`
	ToolUseResult json.RawMessage `json:"toolUseResult"`
	Subtype       string          `json:"subtype"` // system
	Content       json.RawMessage `json:"content"` // system content (a string)
}

type claudeMessage struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"` // string OR []claudeBlock
}

// claudeBlock is one content block (assistant or user). Only the fields relevant
// to a given block Type are populated.
type claudeBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`        // text
	Thinking  string          `json:"thinking"`    // thinking
	ID        string          `json:"id"`          // tool_use
	Name      string          `json:"name"`        // tool_use
	Input     json.RawMessage `json:"input"`       // tool_use
	ToolUseID string          `json:"tool_use_id"` // tool_result
	Content   json.RawMessage `json:"content"`     // tool_result (string OR array)
	IsError   bool            `json:"is_error"`    // tool_result
}

func (claudeReader) Normalize(line []byte) []Entry {
	var l claudeLine
	if err := json.Unmarshal(line, &l); err != nil {
		// Not JSON we understand — never drop the stream, pass through minimally.
		return []Entry{{ID: "", Role: RoleSystem, Kind: KindMessage, Parsed: false}}
	}
	if claudeIgnored[l.Type] {
		return nil
	}

	switch l.Type {
	case "assistant":
		return l.assistantEntries()
	case "user":
		return l.userEntries()
	case "system":
		return l.systemEntries()
	default:
		// A known-shaped but unhandled type: emit a minimal passthrough so the app
		// learns something arrived, without guessing its meaning.
		return []Entry{l.base(0, roleOf(l), KindMessage, false)}
	}
}

// base builds an Entry pre-filled with the shared identity/threading fields. idx
// is the block index within the line (for a unique id when a line expands into
// several entries).
func (l claudeLine) base(idx int, role, kind string, parsed bool) Entry {
	id := l.UUID
	if id != "" {
		id = fmt.Sprintf("%s#%d", l.UUID, idx)
	}
	return Entry{
		ID:       id,
		ParentID: l.ParentUUID,
		TS:       l.Timestamp,
		Role:     role,
		Kind:     kind,
		Parsed:   parsed,
	}
}

// roleOf maps a line's message role onto the contract's role enum, defaulting to
// system for roleless lines.
func roleOf(l claudeLine) string {
	if l.Message != nil {
		switch l.Message.Role {
		case "user":
			return RoleUser
		case "assistant":
			return RoleAssistant
		}
	}
	return RoleSystem
}

func (l claudeLine) assistantEntries() []Entry {
	blocks := l.blocks()
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
		case "tool_use":
			e := l.base(i, RoleAssistant, KindToolCall, true)
			e.Tool = claudeTool(b)
			out = append(out, e)
		default:
			out = append(out, l.base(i, RoleAssistant, KindMessage, false))
		}
	}
	return out
}

func (l claudeLine) userEntries() []Entry {
	if l.Message == nil {
		return []Entry{l.base(0, RoleUser, KindMessage, false)}
	}
	// content may be a bare string (a plain user prompt) …
	var s string
	if json.Unmarshal(l.Message.Content, &s) == nil {
		t := strings.TrimSpace(s)
		if t == "" {
			return nil
		}
		e := l.base(0, RoleUser, KindMessage, true)
		e.Text, _ = truncateRunes(t, maxInlineTextRunes)
		return []Entry{e}
	}
	// … or an array of blocks.
	var out []Entry
	for i, b := range l.blocks() {
		switch b.Type {
		case "text":
			if t := strings.TrimSpace(b.Text); t != "" {
				e := l.base(i, RoleUser, KindMessage, true)
				e.Text, _ = truncateRunes(t, maxInlineTextRunes)
				out = append(out, e)
			}
		case "tool_result":
			e := l.base(i, RoleUser, KindToolResult, true)
			e.Result = claudeResult(b, l.ToolUseResult)
			out = append(out, e)
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

func (l claudeLine) systemEntries() []Entry {
	var s string
	_ = json.Unmarshal(l.Content, &s)
	t := stripXMLTags(s)
	if t == "" {
		return nil // wrapper-only system line (e.g. empty local-command output)
	}
	e := l.base(0, RoleSystem, KindMessage, true)
	e.Text, _ = truncateRunes(t, maxInlineTextRunes)
	return []Entry{e}
}

// blocks decodes the message content as an array of blocks, tolerating a missing
// or non-array content (returns nil).
func (l claudeLine) blocks() []claudeBlock {
	if l.Message == nil {
		return nil
	}
	var bs []claudeBlock
	_ = json.Unmarshal(l.Message.Content, &bs)
	return bs
}

// ---- tool call / result projection ----

func claudeTool(b claudeBlock) *Tool {
	t := &Tool{ID: b.ID, Name: b.Name, Title: b.Name}
	switch b.Name {
	case "Bash":
		var in struct {
			Command     string `json:"command"`
			Description string `json:"description"`
		}
		_ = json.Unmarshal(b.Input, &in)
		t.Command = in.Command
		t.Subtitle = oneLine(in.Description, 120)
		t.InputSummary = oneLine(in.Command, 200)
	case "Edit":
		var in struct {
			FilePath  string `json:"file_path"`
			OldString string `json:"old_string"`
			NewString string `json:"new_string"`
		}
		_ = json.Unmarshal(b.Input, &in)
		t.File = base(in.FilePath)
		t.InputSummary = in.FilePath
		t.Diff, t.DiffTruncated = diffFromEditInput(in.OldString, in.NewString)
	case "Write":
		var in struct {
			FilePath string `json:"file_path"`
			Content  string `json:"content"`
		}
		_ = json.Unmarshal(b.Input, &in)
		t.File = base(in.FilePath)
		t.InputSummary = in.FilePath
		t.Diff, t.DiffTruncated = diffAllAdded(in.Content)
	case "Read":
		var in struct {
			FilePath string `json:"file_path"`
		}
		_ = json.Unmarshal(b.Input, &in)
		t.File = base(in.FilePath)
		t.InputSummary = in.FilePath
	default:
		// Any other tool: a compact JSON of its input is always renderable.
		t.InputSummary = oneLine(string(b.Input), 200)
	}
	return t
}

// claudeToolResult is the recognised shape of the richer top-level toolUseResult.
// Different tools fill different subsets; absent fields stay zero.
type claudeToolResult struct {
	Stdout          string                `json:"stdout"`
	Stderr          string                `json:"stderr"`
	Interrupted     bool                  `json:"interrupted"`
	FilePath        string                `json:"filePath"`
	StructuredPatch []structuredPatchHunk `json:"structuredPatch"`
}

// claudeResult builds a Result from the inline tool_result block plus the richer
// top-level toolUseResult (preferred for diffs/structured output).
func claudeResult(b claudeBlock, tur json.RawMessage) *Result {
	r := &Result{ForID: b.ToolUseID, OK: !b.IsError}

	if len(tur) > 0 {
		var obj claudeToolResult
		if json.Unmarshal(tur, &obj) == nil {
			if obj.Interrupted {
				r.OK = false
			}
			if len(obj.StructuredPatch) > 0 {
				r.Diff, r.Truncated = diffFromStructuredPatch(obj.StructuredPatch)
			}
			out := obj.Stdout
			if s := strings.TrimSpace(obj.Stderr); s != "" {
				if out != "" {
					out += "\n"
				}
				out += "[stderr] " + obj.Stderr
			}
			if out != "" {
				capped, cut := truncateRunes(stripANSI(out), maxOutputRunes)
				r.OutputSummary = capped
				r.Truncated = r.Truncated || cut
			}
		} else {
			// toolUseResult was a bare string.
			var s string
			if json.Unmarshal(tur, &s) == nil && s != "" {
				capped, cut := truncateRunes(stripANSI(s), maxOutputRunes)
				r.OutputSummary = capped
				r.Truncated = cut
			}
		}
	}

	// Fall back to the inline tool_result content when the richer object gave us
	// nothing textual (e.g. Read results, error messages).
	if r.OutputSummary == "" && r.Diff == "" {
		if txt := claudeText(b.Content); txt != "" {
			capped, cut := truncateRunes(stripANSI(txt), maxOutputRunes)
			r.OutputSummary = capped
			r.Truncated = cut
		}
	}
	return r
}

// claudeText extracts readable text from a tool_result content field, which is
// either a JSON string or an array of {type:"text", text:…} / image blocks.
func claudeText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return strings.TrimSpace(s)
	}
	var blocks []claudeBlock
	if json.Unmarshal(raw, &blocks) == nil {
		var parts []string
		for _, b := range blocks {
			switch b.Type {
			case "text":
				if t := strings.TrimSpace(b.Text); t != "" {
					parts = append(parts, t)
				}
			case "image":
				parts = append(parts, "[image]")
			}
		}
		return strings.TrimSpace(strings.Join(parts, "\n"))
	}
	return ""
}

// stripXMLTags removes simple <tag> / </tag> wrappers Claude uses around system
// content (e.g. <local-command-stdout>…</local-command-stdout>) and trims, so a
// wrapper with no inner text collapses to "".
func stripXMLTags(s string) string {
	var b strings.Builder
	depth := 0
	for _, r := range s {
		switch r {
		case '<':
			depth++
		case '>':
			if depth > 0 {
				depth--
			}
		default:
			if depth == 0 {
				b.WriteRune(r)
			}
		}
	}
	return strings.TrimSpace(b.String())
}
