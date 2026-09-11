package transcript

import (
	"encoding/json"
	"strconv"
	"strings"
)

// opencodeSummaryRunes caps an opencode tool call's one-line input summary.
const opencodeSummaryRunes = 200

// opencodeReader normalizes one opencode `part` row onto the common Entry stream.
//
// opencode stores a conversation as `message` rows (metadata: role, timing) with
// child `part` rows carrying the actual blocks. opencodeSource joins the two and
// hands this reader a part plus its message, so Normalize keeps the same
// line-oriented shape as every other reader.
//
// Part types seen in a live store:
//
//	text        -> KindMessage
//	reasoning   -> KindThinking
//	tool        -> KindToolCall, plus KindToolResult once the call settles
//	step-start  \ turn plumbing, dropped
//	step-finish /
//	patch       -> dropped: it is a snapshot marker listing touched files, and the
//	               edit tool that made the change already carries the real diff
//
// The notable difference from Claude and Hermes: opencode keeps a call AND its
// result in ONE part, under `state` — `{status, input, output, metadata, title}`
// on success, `{status, input, error}` on failure. So a settled tool part expands
// into two entries, correlated by callID, which is what the app's tool ledger
// already pairs on.
type opencodeReader struct{}

func init() { Register(opencodeReader{}); RegisterOpener(opencodeOpener{}) }

func (opencodeReader) Kind() string { return "opencode" }

// opencodeRow is one joined part+message, as marshalled by opencodeSource.
type opencodeRow struct {
	ID      string          `json:"id"`
	Message string          `json:"message_id"`
	MsgData json.RawMessage `json:"message_data"`
	Part    json.RawMessage `json:"part_data"`
}

// opencodeMessage is the subset of a `message` row's JSON we need.
type opencodeMessage struct {
	Role string `json:"role"`
	Time struct {
		Created int64 `json:"created"`
	} `json:"time"`
}

// opencodePart is the subset of a `part` row's JSON we need. State is decoded
// lazily because its shape depends on status.
type opencodePart struct {
	Type   string          `json:"type"`
	Text   string          `json:"text"`
	Tool   string          `json:"tool"`
	CallID string          `json:"callID"`
	ID     string          `json:"id"`
	Name   string          `json:"name"`
	State  json.RawMessage `json:"state"`
}

// opencodeToolState is a tool part's `state`. Output/Metadata are only present
// once the call completes; Error only on failure.
type opencodeToolState struct {
	Status   string          `json:"status"`
	Title    string          `json:"title"`
	Input    json.RawMessage `json:"input"`
	Output   string          `json:"output"`
	Content  json.RawMessage `json:"content"`
	Error    json.RawMessage `json:"error"`
	Metadata struct {
		Diff string `json:"diff"`
	} `json:"metadata"`
}

type opencodeV2Message struct {
	ID   string `json:"id"`
	Type string `json:"type"`
	Time struct {
		Created   int64 `json:"created"`
		Completed int64 `json:"completed"`
	} `json:"time"`
	Text    string          `json:"text"`
	Content []opencodePart  `json:"content"`
	Error   json.RawMessage `json:"error"`
	// A "shell" message is a user-run `!command`, not a model turn: it carries the
	// command and its captured output directly rather than a content array.
	CallID  string `json:"callID"`
	Command string `json:"command"`
	Output  string `json:"output"`
}

// opencodeDropped are part types that are turn plumbing rather than conversation.
var opencodeDropped = map[string]bool{
	"step-start":  true,
	"step-finish": true,
	"patch":       true,
}

func (r opencodeReader) Normalize(line []byte) []Entry {
	var row opencodeRow
	if err := json.Unmarshal(line, &row); err != nil {
		return []Entry{{Kind: KindMessage, Role: "system", Text: string(line), Parsed: false}}
	}

	var part opencodePart
	if err := json.Unmarshal(row.Part, &part); err != nil {
		return []Entry{{ID: row.ID, Kind: KindMessage, Role: "system",
			Text: string(row.Part), Parsed: false}}
	}
	if opencodeDropped[part.Type] {
		return nil
	}

	var msg opencodeMessage
	_ = json.Unmarshal(row.MsgData, &msg) // best-effort; role may be empty
	role := msg.Role
	if role == "" {
		role = "assistant"
	}
	ts := unixMillisToRFC3339(msg.Time.Created)

	base := Entry{ID: row.ID, ParentID: row.Message, TS: ts, Role: role, Parsed: true}

	switch part.Type {
	case "text":
		if strings.TrimSpace(part.Text) == "" {
			return nil
		}
		e := base
		e.Kind = KindMessage
		e.Text = strings.TrimSpace(part.Text)
		return []Entry{e}

	case "reasoning":
		if strings.TrimSpace(part.Text) == "" {
			return nil
		}
		e := base
		e.Kind = KindThinking
		e.Text = strings.TrimSpace(part.Text)
		return []Entry{e}

	case "tool":
		return opencodeToolEntries(base, part)
	}

	// An unfamiliar part type still reaches the app, flagged.
	e := base
	e.Kind = KindMessage
	e.Text = part.Text
	e.Parsed = false
	return []Entry{e}
}

// opencodeToolEntries turns one tool part into its call entry and, when the call
// has settled, the matching result entry.
func opencodeToolEntries(base Entry, part opencodePart) []Entry {
	var st opencodeToolState
	if len(part.State) > 0 {
		_ = json.Unmarshal(part.State, &st)
	}

	name := part.Tool
	if name == "" {
		name = part.Name
	}
	if name == "" {
		name = "tool"
	}
	callID := part.CallID
	if callID == "" {
		// v2 puts the tool call id in `id`; legacy rows use `callID`.
		callID = part.ID
	}
	tool := &Tool{ID: callID, Name: name, Title: name}
	if st.Title != "" {
		tool.Subtitle = oneLine(st.Title, opencodeSummaryRunes)
	}
	applyOpencodeInput(tool, st.Input)

	call := base
	call.Kind = KindToolCall
	call.Tool = tool
	call.ID = base.ID + "#call"
	out := []Entry{call}

	// "running" (or an absent state) means the call is still in flight — emit the
	// invocation only; there is no outcome to report yet.
	switch st.Status {
	case "completed", "error":
	default:
		return out
	}

	res := &Result{ForID: callID, OK: st.Status == "completed"}
	if st.Metadata.Diff != "" {
		diff, truncated := truncateRunes(st.Metadata.Diff, maxDiffRunes)
		res.Diff = diff
		res.Truncated = truncated
	}
	text := st.Output
	if text == "" && len(st.Content) > 0 {
		var blocks []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if json.Unmarshal(st.Content, &blocks) == nil {
			var parts []string
			for _, block := range blocks {
				if block.Text != "" {
					parts = append(parts, block.Text)
				}
			}
			text = strings.Join(parts, "\n")
		}
	}
	if text == "" && len(st.Error) > 0 {
		text = opencodeErrorText(st.Error)
	}
	if text != "" {
		summary, truncated := truncateRunes(text, maxOutputRunes)
		res.OutputSummary = summary
		res.Truncated = res.Truncated || truncated
	}

	resEntry := base
	resEntry.Kind = KindToolResult
	resEntry.Role = "tool"
	resEntry.Result = res
	resEntry.ID = base.ID + "#result"
	return append(out, resEntry)
}

// normalizeOpencodeV2Message maps one OpenCode v2 *projected* message — the
// shape the service returns from `/api/session/{id}/message`, not a raw SQLite
// row — onto the common Entry stream.
//
// The projection is already a normalized timeline, so this is a shallower
// mapping than the legacy reader: `user`/`synthetic`/`system` carry their prose
// inline, `assistant` carries an ordered `content` array of text/reasoning/tool
// blocks, `compaction` carries a summary, and `shell` carries a user command.
// The tool blocks reuse opencodeToolEntries so a v2 tool call pairs and renders
// exactly like a legacy one.
func normalizeOpencodeV2Message(line []byte) []Entry {
	var msg opencodeV2Message
	if err := json.Unmarshal(line, &msg); err != nil {
		return []Entry{{Kind: KindMessage, Role: RoleSystem, Text: string(line), Parsed: false}}
	}
	role := RoleAssistant
	switch msg.Type {
	case "user":
		role = RoleUser
	case "synthetic", "system", "compaction":
		role = RoleSystem
	}
	ts := unixMillisToRFC3339(msg.Time.Created)

	switch msg.Type {
	case "user", "synthetic", "system":
		if strings.TrimSpace(msg.Text) == "" {
			return nil
		}
		return []Entry{{ID: msg.ID, TS: ts, Role: role, Kind: KindMessage,
			Text: strings.TrimSpace(msg.Text), Parsed: true}}
	case "compaction":
		var c struct {
			Summary string `json:"summary"`
		}
		_ = json.Unmarshal(line, &c)
		if strings.TrimSpace(c.Summary) == "" {
			return nil
		}
		text, _ := truncateRunes(strings.TrimSpace(c.Summary), maxInlineTextRunes)
		return []Entry{{ID: msg.ID, TS: ts, Role: RoleSystem, Kind: KindMessage, Text: text, Parsed: true}}
	case "shell":
		return opencodeShellEntries(msg, ts)
	case "assistant":
		// The model's own turn: its blocks are in Content, parsed below.
	default:
		// agent-switched / model-switched and any future plumbing carry no
		// conversation; dropping them keeps the chat clean.
		return nil
	}
	if len(msg.Content) == 0 {
		if len(msg.Error) == 0 {
			return nil
		}
		text := opencodeErrorText(msg.Error)
		if text == "" {
			return nil
		}
		return []Entry{{ID: msg.ID, TS: ts, Role: RoleAssistant, Kind: KindMessage, Text: text, Parsed: true}}
	}
	var out []Entry
	for i, part := range msg.Content {
		base := Entry{ID: msg.ID + "#" + strconv.Itoa(i), ParentID: msg.ID, TS: ts, Role: role, Parsed: true}
		if part.Type == "tool" {
			out = append(out, opencodeToolEntries(base, part)...)
			continue
		}
		if opencodeDropped[part.Type] {
			continue
		}
		if strings.TrimSpace(part.Text) == "" {
			continue
		}
		switch part.Type {
		case "reasoning":
			base.Kind, base.Text = KindThinking, strings.TrimSpace(part.Text)
		default:
			base.Kind, base.Text = KindMessage, strings.TrimSpace(part.Text)
		}
		out = append(out, base)
	}
	return out
}

// opencodeShellEntries renders a v2 "shell" message — a command the user ran
// directly (the `!cmd` composer escape) rather than a model turn — as the same
// tool_call/tool_result pair a model-issued shell tool produces, so the ledger
// renders both identically.
func opencodeShellEntries(msg opencodeV2Message, ts string) []Entry {
	command := strings.TrimSpace(msg.Command)
	if command == "" {
		return nil
	}
	id := msg.CallID
	if id == "" {
		id = msg.ID
	}
	call := Entry{ID: msg.ID + "#call", ParentID: msg.ID, TS: ts, Role: RoleAssistant,
		Kind: KindToolCall, Parsed: true,
		Tool: &Tool{ID: id, Name: "shell", Title: "shell",
			Command: command, InputSummary: oneLine(command, opencodeSummaryRunes)}}
	out := []Entry{call}

	if strings.TrimSpace(msg.Output) == "" {
		return out
	}
	summary, truncated := truncateRunes(stripANSI(msg.Output), maxOutputRunes)
	res := Entry{ID: msg.ID + "#result", ParentID: msg.ID, TS: ts, Role: "tool",
		Kind: KindToolResult, Parsed: true,
		Result: &Result{ForID: id, OK: true, OutputSummary: summary, Truncated: truncated}}
	return append(out, res)
}

// applyOpencodeInput projects a tool's input onto the rendering fields. opencode
// names them consistently across its built-ins (bash.command, read/edit.filePath),
// and anything unrecognised still gets a safe one-line summary.
func applyOpencodeInput(t *Tool, raw json.RawMessage) {
	if len(raw) == 0 {
		return
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.InputSummary = oneLine(string(raw), opencodeSummaryRunes)
		return
	}
	str := func(k string) string {
		if v, ok := m[k].(string); ok {
			return v
		}
		return ""
	}
	if cmd := str("command"); cmd != "" {
		t.Command = cmd
	}
	for _, k := range []string{"filePath", "file_path", "path", "pattern"} {
		if f := str(k); f != "" {
			t.File = f
			break
		}
	}
	t.InputSummary = oneLine(compactJSON(m), opencodeSummaryRunes)
}

// opencodeErrorText renders a failed call's error, which may be a bare string or
// an object, into something displayable.
func opencodeErrorText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil && s != "" {
		return s
	}
	var m map[string]any
	if json.Unmarshal(raw, &m) == nil {
		for _, k := range []string{"message", "error", "name"} {
			if v, ok := m[k].(string); ok && v != "" {
				return v
			}
		}
		return compactJSON(m)
	}
	return string(raw)
}

// opencodeOpener resolves an opencode pane to its session in the store.
type opencodeOpener struct{}

func (opencodeOpener) Kind() string { return "opencode" }

func (opencodeOpener) Open(cwd, sessionID string) (Source, error) {
	return openOpencodeSource(cwd, sessionID)
}
