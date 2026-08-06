package transcript

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"
)

// hermesReader normalizes one Hermes message row onto the common Entry stream.
//
// Hermes does not write transcript files — every session lives in the `messages`
// table of ~/.hermes/state.db (see hermessource.go). hermesSource serializes each
// row to a JSON object and hands it here, so this reader has the same
// Normalize(line []byte) shape as the file-backed ones and slots into the same
// registry. The row shape is:
//
//	{id, session_id, role, content, tool_call_id, tool_calls, tool_name,
//	 reasoning, timestamp}
//
// Roles observed in a live database: user, assistant, tool, session_meta.
// An assistant row can carry reasoning, prose, and tool calls at once, so it
// expands into several entries — reasoning first, then prose, then one entry per
// tool call, which is the order they happened in.
type hermesReader struct{}

func init() { Register(hermesReader{}); RegisterOpener(hermesOpener{}) }

func (hermesReader) Kind() string { return "hermes" }

// hermesRow is one `messages` row as marshalled by hermesSource.
type hermesRow struct {
	ID         int64   `json:"id"`
	Role       string  `json:"role"`
	Content    string  `json:"content"`
	ToolCallID string  `json:"tool_call_id"`
	ToolCalls  string  `json:"tool_calls"` // a JSON array, stored as TEXT
	ToolName   string  `json:"tool_name"`
	Reasoning  string  `json:"reasoning"`
	Timestamp  float64 `json:"timestamp"` // unix epoch seconds, fractional
}

// hermesToolCall is one element of the `tool_calls` JSON array. Hermes uses the
// OpenAI function-calling shape.
type hermesToolCall struct {
	ID       string `json:"id"`
	CallID   string `json:"call_id"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"` // a JSON object, stored as a string
	} `json:"function"`
}

// hermesIgnoredRoles are bookkeeping rows that are not part of the conversation.
var hermesIgnoredRoles = map[string]bool{
	"session_meta": true,
}

func (r hermesReader) Normalize(line []byte) []Entry {
	var row hermesRow
	if err := json.Unmarshal(line, &row); err != nil {
		return []Entry{{Kind: KindMessage, Role: "system", Text: string(line), Parsed: false}}
	}
	if hermesIgnoredRoles[row.Role] {
		return nil
	}

	ts := ""
	if row.Timestamp > 0 {
		sec, frac := int64(row.Timestamp), row.Timestamp-float64(int64(row.Timestamp))
		ts = time.Unix(sec, int64(frac*1e9)).UTC().Format(time.RFC3339)
	}
	id := strconv.FormatInt(row.ID, 10)
	base := Entry{ID: id, TS: ts, Role: row.Role, Parsed: true}
	n := 0
	// emit stamps a per-block suffix so every entry from one row has a unique ID,
	// matching how the claude reader indexes blocks within a line.
	emit := func(e Entry) Entry {
		e.ID = id + "#" + strconv.Itoa(n)
		n++
		return e
	}

	var out []Entry

	switch row.Role {
	case "tool":
		// A tool result. Hermes has no structured ok/error flag — a failed call comes
		// back as prose beginning "Error executing tool:", which is what its own UI
		// keys on, so we do the same rather than inventing a signal.
		content, truncated := truncateRunes(row.Content, maxOutputRunes)
		out = append(out, emit(Entry{
			ID: id, TS: ts, Role: "tool", Kind: KindToolResult, Parsed: true,
			Result: &Result{
				ForID:         row.ToolCallID,
				OK:            !strings.HasPrefix(strings.TrimSpace(row.Content), "Error executing tool"),
				OutputSummary: content,
				Truncated:     truncated,
			},
		}))
		return out

	case "user", "assistant":
		if s := strings.TrimSpace(row.Reasoning); s != "" {
			e := base
			e.Kind = KindThinking
			e.Text = s
			out = append(out, emit(e))
		}
		if s := strings.TrimSpace(row.Content); s != "" {
			e := base
			e.Kind = KindMessage
			e.Text = s
			out = append(out, emit(e))
		}
		for _, tc := range parseHermesToolCalls(row.ToolCalls) {
			e := base
			e.Kind = KindToolCall
			e.Tool = tc
			out = append(out, emit(e))
		}
		// A row that carried nothing renderable (e.g. an empty assistant turn that
		// only held tool calls we failed to parse) is dropped rather than emitted as
		// a blank bubble.
		return out
	}

	// An unrecognised role still reaches the app, flagged, so the tail never breaks.
	return []Entry{{
		ID: id, TS: ts, Role: row.Role, Kind: KindMessage,
		Text: row.Content, Parsed: false,
	}}
}

// parseHermesToolCalls decodes the `tool_calls` TEXT column into Tools. A column
// that is empty or unparseable yields none — a malformed row degrades to its
// prose rather than breaking the stream.
func parseHermesToolCalls(raw string) []*Tool {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	var calls []hermesToolCall
	if err := json.Unmarshal([]byte(raw), &calls); err != nil {
		return nil
	}
	out := make([]*Tool, 0, len(calls))
	for _, c := range calls {
		id := c.CallID
		if id == "" {
			id = c.ID
		}
		name := c.Function.Name
		if name == "" {
			continue
		}
		t := &Tool{ID: id, Name: name, Title: name}
		applyHermesArgs(t, c.Function.Arguments)
		out = append(out, t)
	}
	return out
}

// applyHermesArgs projects a tool call's JSON arguments onto the rendering fields
// the app understands. Hermes tool schemas vary, so this reads the few keys that
// carry obvious meaning and always leaves a safe one-line InputSummary behind.
func applyHermesArgs(t *Tool, args string) {
	if strings.TrimSpace(args) == "" {
		return
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(args), &m); err != nil {
		t.InputSummary = oneLine(args, hermesSummaryRunes)
		return
	}
	str := func(k string) string {
		if v, ok := m[k].(string); ok {
			return v
		}
		return ""
	}
	// `terminal` is Hermes's shell tool; treat its command like Bash's so the app
	// renders it in the command component rather than as opaque arguments.
	if cmd := str("command"); cmd != "" {
		t.Command = cmd
	}
	for _, k := range []string{"path", "file", "file_path", "filename"} {
		if f := str(k); f != "" {
			t.File = f
			break
		}
	}
	t.InputSummary = oneLine(compactJSON(m), hermesSummaryRunes)
}

// hermesOpener resolves a Hermes pane to its session in the state database.
type hermesOpener struct{}

func (hermesOpener) Kind() string { return "hermes" }

func (hermesOpener) Open(cwd, sessionID string) (Source, error) {
	return openHermesSource(sessionID)
}
