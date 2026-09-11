// Package transcript turns a coding agent's structured session transcript into a
// kind-agnostic, streamable chat schema. It is the "chat view" data source that
// sits one layer above agentstate: instead of a parsed current-state card scraped
// from the terminal, it reads the agent's structured transcript store (Claude Code
// writes JSONL; OpenCode v2 exposes a local service API) and normalizes every entry
// into the same shape — messages, thinking, tool calls (with command/diff), and
// tool results — so the app renders one chat UI regardless of which agent produced
// it.
//
// The design mirrors internal/agentstate: a per-kind Reader maps each agent's
// transcript format onto the common Entry. Unknown kinds fall back to a generic
// reader that emits a minimal Parsed=false entry rather than failing. Adding an
// agent is one new file that implements Reader and calls Register in its init —
// the endpoint, the JSON contract, and existing readers stay untouched.
//
// Readers are pure and panic-free: Normalize maps one raw transcript line to zero
// or more Entry values and NEVER drops the stream because a line didn't match — an
// unrecognised line becomes a single Parsed=false entry, and pure-metadata lines
// are skipped. This keeps a live tail resilient to schema drift.
package transcript

import (
	"encoding/json"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Role is the speaker of an entry, clamped to a small agent-agnostic set.
const (
	RoleUser      = "user"
	RoleAssistant = "assistant"
	RoleSystem    = "system"
)

// Kind is the entry's structural type — what UI component the app renders.
const (
	KindMessage    = "message"     // prose (markdown) from user/assistant/system
	KindThinking   = "thinking"    // assistant reasoning block
	KindToolCall   = "tool_call"   // the agent invoking a tool (command/diff/file)
	KindToolResult = "tool_result" // the tool's output (ok/diff/summary)
	KindAttachment = "attachment"  // image / pasted file / other non-text payload
)

// Entry is the normalized, kind-agnostic transcript row streamed to the app. The
// same shape is produced for every agent kind so the client renders one UI. Empty
// optional fields are omitted from the JSON to keep frames small.
type Entry struct {
	// ID identifies this entry. One transcript line can expand into several
	// entries (an assistant turn = text + thinking + N tool calls), so ID is the
	// source line's uuid suffixed with the block index (e.g. "…a1b2#2") and is
	// unique per emitted entry.
	ID string `json:"id"`
	// ParentID is the source line's parentUuid (conversation threading), or empty.
	ParentID string `json:"parent_id,omitempty"`
	// Seq is a monotonically increasing 1-based counter stamped by the emitter in
	// stream order. Backlog and live entries share one sequence, so the app can
	// order and de-dupe purely on Seq without parsing timestamps.
	Seq int `json:"seq"`
	// TS is the source line's ISO-8601 timestamp, or empty when absent.
	TS string `json:"ts,omitempty"`
	// Role is user | assistant | system.
	Role string `json:"role"`
	// Kind is message | thinking | tool_call | tool_result | attachment.
	Kind string `json:"kind"`
	// Text is the markdown body for message/thinking (and a short placeholder for
	// attachments). Empty for tool_call/tool_result.
	Text string `json:"text,omitempty"`
	// Tool is present only for tool_call: what the agent invoked.
	Tool *Tool `json:"tool,omitempty"`
	// Result is present only for tool_result: how the tool call ended.
	Result *Result `json:"result,omitempty"`
	// Parsed is false when the reader could not recognise the line and passed it
	// through minimally. The app can still render Role/Kind/Text.
	Parsed bool `json:"parsed"`
}

// Tool is the invocation details of a tool_call. Name is the raw tool name; the
// other fields are a rendering-friendly projection so the app never needs to know
// a tool's specific input schema. Correlate a Tool with its Result via Tool.ID ==
// Result.ForID.
type Tool struct {
	// ID is the agent's own tool-use id (e.g. "toolu_01…"); the matching
	// tool_result carries it as ForID. This is the reliable call<->result key.
	ID string `json:"id,omitempty"`
	// Name is the raw tool name (Bash, Edit, Read, Write, WebFetch, …).
	Name string `json:"name"`
	// Title is a short human label for the tool (usually == Name).
	Title string `json:"title,omitempty"`
	// Subtitle is an optional secondary label (e.g. a Bash command's description).
	Subtitle string `json:"subtitle,omitempty"`
	// Command is the shell command for command-running tools (Bash), else empty.
	Command string `json:"command,omitempty"`
	// File is the primary file path a file tool acts on (Edit/Read/Write), else "".
	File string `json:"file,omitempty"`
	// Diff is a unified diff of the proposed change for Edit/Write, built from the
	// tool input (old/new). It may be truncated (see DiffTruncated). The applied
	// diff also appears on the paired tool_result and is authoritative.
	Diff string `json:"diff,omitempty"`
	// DiffTruncated is true when Diff was capped.
	DiffTruncated bool `json:"diff_truncated,omitempty"`
	// InputSummary is a compact one-line summary of the tool input, always safe to
	// render even for tools the reader doesn't specifically understand.
	InputSummary string `json:"input_summary,omitempty"`
}

// Result is the outcome of a tool call. Correlate with its Tool via ForID.
type Result struct {
	// ForID is the tool-use id this result answers (== the Tool.ID of the call).
	ForID string `json:"for_id,omitempty"`
	// OK is false when the tool reported an error or was interrupted.
	OK bool `json:"ok"`
	// OutputSummary is the tool's textual output (stdout/stderr/content), capped.
	OutputSummary string `json:"output_summary,omitempty"`
	// Diff is the applied unified diff for Edit/Write, built from the richer
	// toolUseResult (structuredPatch). Authoritative over the tool_call's Diff.
	Diff string `json:"diff,omitempty"`
	// Truncated is true when OutputSummary or Diff was capped.
	Truncated bool `json:"truncated,omitempty"`
}

// Reader maps one agent kind's transcript format onto the common Entry stream.
//
// Implementations MUST be pure, panic-free, and degrade gracefully. Normalize
// takes one raw transcript line (a JSONL object for Claude) and returns the
// entries it expands into — zero (a pure-metadata line to drop), one, or many
// (an assistant turn with several content blocks). A line the reader can parse as
// JSON but does not recognise should yield a single Parsed=false entry; a line it
// cannot parse at all should also yield one Parsed=false entry rather than being
// silently dropped. The caller stamps Seq in stream order, so readers leave it 0.
type Reader interface {
	// Kind is the herdr agent kind this reader handles ("claude", "codex", …).
	Kind() string
	// Normalize converts one raw transcript line into its normalized entries.
	Normalize(line []byte) []Entry
}

// registry maps agent kind -> reader. Populated by each reader's init via
// Register. Written only at startup (inits are single-threaded); read-only after.
var registry = map[string]Reader{}

// Register adds a reader to the registry, keyed by r.Kind(). Call it from a
// reader file's init(). A later Register for the same kind wins (last loaded).
func Register(r Reader) { registry[r.Kind()] = r }

// ReaderFor returns the reader for a kind, or the generic fallback for an
// unregistered/unknown kind (which reports Parsed=false).
func ReaderFor(kind string) Reader {
	if r, ok := registry[strings.ToLower(strings.TrimSpace(kind))]; ok {
		return r
	}
	return genericReader{}
}

// ---- shared helpers used by readers ----

// Output/diff caps. The transcript can be huge; a single Bash result or a
// whole-file Write diff is capped so one entry can't blow up a frame. The caller
// documents these in CONTRACT.md.
const (
	// maxOutputRunes caps a tool result's output summary.
	maxOutputRunes = 4000
	// maxDiffLines caps how many lines of a diff are emitted.
	maxDiffLines = 400
	// maxDiffRunes caps a diff's total size regardless of line count.
	maxDiffRunes = 12000
	// maxInlineTextRunes caps a passed-through message/thinking body.
	maxInlineTextRunes = 20000
)

// Terminal escape / control matchers. Coding-agent stdout is frequently colorized,
// so a captured tool output can carry ANSI SGR runs (\x1b[2m … \x1b[0m), cursor
// moves, OSC title/hyperlink sequences, and stray C0 control bytes. Rendered raw on
// the phone these show up as literal "ESC[2m" gibberish, so stripANSI removes them
// before the output is capped and streamed.
var (
	// ansiCSI matches a CSI sequence: ESC '[' , parameter bytes (0x30–0x3f),
	// intermediate bytes (0x20–0x2f), then a final byte (0x40–0x7e). Covers SGR
	// color/style, cursor movement, erase, etc.
	ansiCSI = regexp.MustCompile("\x1b\\[[0-?]*[ -/]*[@-~]")
	// ansiOSC matches an OSC sequence: ESC ']' , a payload, terminated by BEL
	// (0x07) or ST (ESC '\\'). Covers window-title and hyperlink escapes.
	ansiOSC = regexp.MustCompile("\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)")
	// c0Control matches stray C0 control bytes and DEL, preserving only newline
	// (\n) and tab (\t) as legitimate whitespace. This also sweeps up any lone ESC
	// left behind by a partial/other escape sequence.
	c0Control = regexp.MustCompile("[\x00-\x08\x0b-\x1f\x7f]")
)

// stripANSI removes ANSI CSI/OSC escape sequences and stray C0 control bytes from
// s, keeping newlines and tabs. It is applied to raw tool output before capping so
// the transcript ledger renders clean plain text (and the cap counts visible runes,
// not escape-sequence noise).
func stripANSI(s string) string {
	s = ansiOSC.ReplaceAllString(s, "")
	s = ansiCSI.ReplaceAllString(s, "")
	s = c0Control.ReplaceAllString(s, "")
	return s
}

// truncateRunes caps s to n runes, returning the capped string and whether it was
// cut. Cheaper than importing agentstate; kept local so the packages stay decoupled.
func truncateRunes(s string, n int) (string, bool) {
	r := []rune(s)
	if len(r) <= n {
		return s, false
	}
	return string(r[:n]), true
}

// firstNonEmptyLine returns the first non-blank line of s, trimmed — used to derive
// a subtitle/summary from a multi-line body.
func firstNonEmptyLine(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(l); t != "" {
			return t
		}
	}
	return ""
}

// oneLine collapses whitespace runs to single spaces and trims, so a summary sits
// on one line. It caps at n runes with an ellipsis.
func oneLine(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > n {
		return strings.TrimRight(string(r[:n-1]), " ") + "…"
	}
	return s
}

// base returns the final path element (file basename) or the input unchanged when
// it isn't a path.
func base(p string) string {
	if p == "" {
		return ""
	}
	return filepath.Base(p)
}

// unixMillisToRFC3339 formats a millisecond epoch as the Entry.TS wire format,
// returning "" for a zero/absent timestamp so the field is simply omitted.
// Database-backed agents store epochs rather than the ISO strings Claude writes.
func unixMillisToRFC3339(ms int64) string {
	if ms <= 0 {
		return ""
	}
	return time.UnixMilli(ms).UTC().Format(time.RFC3339)
}

// compactJSON marshals v to a compact one-line string for an input summary,
// returning "" on failure (a summary is best-effort, never fatal).
func compactJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(b)
}
