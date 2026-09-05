package transcript

// Subagent discovery: the piece that keeps the phone from going dark exactly
// when an agent parallelizes.
//
// When Claude Code delegates with the Task tool, the child's conversation is NOT
// appended to the parent's transcript. It is written to a sibling directory
// named after the session:
//
//	~/.claude/projects/<encoded-cwd>/
//	    <session>.jsonl                    the parent transcript
//	    <session>/subagents/
//	        agent-<agentID>.jsonl          the child transcript, same line format
//	        agent-<agentID>.meta.json      {agentType, description, toolUseId, spawnDepth}
//
// Without this file the reader sees only a Task tool_call followed — minutes
// later — by its result, with nothing in between. That is the case a phone
// monitor most needs to show, and it was the one it could not.
//
// Two properties of the layout drive the design here, both verified against live
// files rather than assumed:
//
//  1. The directory is FLAT. A subagent that itself spawns a subagent does not
//     nest on disk; the grandchild lands in the same subagents/ dir carrying
//     SpawnDepth 2. So discovery returns one flat slice and the tree is rebuilt
//     by the consumer.
//
//  2. ToolUseID is the join key, and it points at a tool call in whichever
//     transcript spawned it — the parent session for a depth-1 child, a
//     sibling subagent's transcript for a depth-2 one. Matching ToolUseID
//     against the Tool.ID values of the transcript currently being rendered
//     therefore yields exactly that transcript's direct children, at any depth,
//     with no depth arithmetic.
//
// The child files are read on demand, never inlined: a single session dir in the
// wild held five subagents beside a 1.4 MB parent, and a phone should not pay for
// all of it to render one collapsed row.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// subagentMeta is the on-disk agent-<id>.meta.json shape. Unknown fields are
// ignored so a future Claude Code release adding keys does not break discovery.
type subagentMeta struct {
	AgentType   string `json:"agentType"`
	Description string `json:"description"`
	ToolUseID   string `json:"toolUseId"`
	SpawnDepth  int    `json:"spawnDepth"`
}

// Subagent is one delegated conversation, as advertised to the app.
//
// It is deliberately metadata-only: enough to render a collapsed row without
// opening the child transcript at all. Call OpenSubagent when the user expands
// the row.
type Subagent struct {
	// AgentID is the id embedded in the filenames (the "a31269…" of
	// agent-a31269….jsonl). It is the handle the client passes back to stream
	// this subagent, and is unique within a session.
	AgentID string `json:"agent_id"`
	// ToolUseID is the tool-use id of the Task call that spawned this subagent.
	// It equals the Tool.ID of that tool_call entry, which is how a client
	// attaches this subagent to the right row. The call lives in the parent
	// session's transcript for SpawnDepth 1, and in another subagent's
	// transcript for deeper ones.
	ToolUseID string `json:"tool_use_id"`
	// AgentType is the configured agent that ran (e.g. "general-purpose",
	// "Explore"). Suitable as the primary label.
	AgentType string `json:"agent_type"`
	// Description is the short task description given at spawn time — the
	// secondary label, e.g. "Build mobile Phase-3 control surface".
	Description string `json:"description"`
	// SpawnDepth is 1 for a child of the session itself, 2 for a child of a
	// subagent, and so on. Reported for display; it is not needed to rebuild the
	// tree (match on ToolUseID instead).
	SpawnDepth int `json:"spawn_depth"`

	// Done reports that the parent has been told this agent finished. False
	// means still working — NOT "unknown": the notification is exact, and the
	// spawning call's result is not (see subagent_status.go).
	Done bool `json:"done"`

	// LastActivity is when this conversation last wrote, taken from its newest
	// entry rather than the file's mtime (see [LastActivity]). Zero means
	// undatable, never "just now".
	LastActivity time.Time `json:"-"`

	// LastActivityTS is [LastActivity] on the wire, in unix milliseconds to
	// match `last_activity_ts` on agents. Omitted when undatable, so a client
	// renders nothing rather than 1970.
	LastActivityTS int64 `json:"last_activity_ts,omitempty"`

	// path is the resolved agent-<id>.jsonl. Unexported so a client can never
	// hand back a path: OpenSubagent re-discovers and matches on AgentID, which
	// makes traversal through this field impossible by construction.
	path string
}

// Subagents lists the subagents belonging to a pane's current session, or an
// empty slice when there are none.
//
// A session with no subagents is the overwhelmingly common case and is NOT an
// error: the directory simply does not exist. Only a kind with no transcript
// support, or an unresolvable session, returns an error — mirroring Locate, so
// the endpoint's existing 404 mapping keeps working unchanged.
//
// Ordering is by SpawnDepth then AgentID, purely so the output is deterministic
// for tests and diffs. It is NOT spawn order and must not be presented as a
// timeline: the authoritative order is the position of each matching Task call
// within the transcript being rendered.
func Subagents(kind, cwd, sessionID string) ([]Subagent, error) {
	parent, err := Locate(kind, cwd, sessionID)
	if err != nil {
		return nil, err
	}
	return subagentsBeside(parent), nil
}

// subagentsBeside enumerates the subagents dir that sits beside a parent
// transcript path. Split from Subagents so tests can point it at a fixture tree
// without needing a fake $HOME.
func subagentsBeside(parentPath string) []Subagent {
	out := listSubagentsBeside(parentPath)
	if len(out) == 0 {
		return out
	}
	// One scan of the parent serves every row; a per-row scan would re-read a
	// multi-megabyte file once per subagent.
	done := completedAgents(parentPath)
	for i := range out {
		out[i].Done = done[out[i].AgentID]
		if at, dated := lastEntryTime(out[i].path); dated {
			out[i].LastActivity = at
			out[i].LastActivityTS = at.UnixMilli()
		}
	}
	return out
}

// listSubagentsBeside is discovery WITHOUT liveness: ids, labels and paths.
//
// Split from the roster because [OpenSubagent] needs only a path, and the
// enrichment above is not free — it dates every child (63 of them beside one
// real session) and reads the whole parent. A stream of one child should not
// pay for a roster of all of them.
func listSubagentsBeside(parentPath string) []Subagent {
	dir := subagentDirFor(parentPath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		// Missing dir == no subagents. Any other read error is treated the same
		// way on purpose: a transcript that renders without its subagents is far
		// better than one that fails to render at all.
		return []Subagent{}
	}

	out := make([]Subagent, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		id, ok := agentIDFromMeta(e.Name())
		if !ok {
			continue
		}
		// Require the transcript itself, not just the metadata. A meta without
		// its .jsonl would advertise a row that cannot be opened.
		body := filepath.Join(dir, "agent-"+id+".jsonl")
		if !isFile(body) {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var m subagentMeta
		if err := json.Unmarshal(raw, &m); err != nil {
			// Unreadable metadata still leaves a streamable transcript, so keep
			// the row with the id as its only label rather than dropping it.
			m = subagentMeta{}
		}
		out = append(out, Subagent{
			AgentID:     id,
			ToolUseID:   m.ToolUseID,
			AgentType:   m.AgentType,
			Description: m.Description,
			SpawnDepth:  m.SpawnDepth,
			path:        body,
		})
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].SpawnDepth != out[j].SpawnDepth {
			return out[i].SpawnDepth < out[j].SpawnDepth
		}
		return out[i].AgentID < out[j].AgentID
	})
	return out
}

// subagentDirFor maps a parent transcript path to its subagents directory:
// <dir>/<session>.jsonl -> <dir>/<session>/subagents.
func subagentDirFor(parentPath string) string {
	return filepath.Join(strings.TrimSuffix(parentPath, ".jsonl"), "subagents")
}

// agentIDFromMeta extracts "a31269…" from "agent-a31269….meta.json", reporting
// false for any other filename. Requiring both affixes is what keeps a stray
// file in the directory from being taken for a subagent.
func agentIDFromMeta(name string) (string, bool) {
	if !strings.HasPrefix(name, "agent-") || !strings.HasSuffix(name, ".meta.json") {
		return "", false
	}
	id := strings.TrimSuffix(strings.TrimPrefix(name, "agent-"), ".meta.json")
	if id == "" {
		return "", false
	}
	return id, true
}

// OpenSubagent opens one subagent's transcript as a Source, ready to stream
// through exactly the same framing as a top-level transcript.
//
// agentID comes from the client, so it is never used to build a path. Discovery
// runs first and the id is matched against what was found; an id that is not in
// the list returns ErrNoTranscript. Path traversal is therefore not merely
// filtered, it is unrepresentable.
//
// The child file is the same JSONL dialect as the parent, so it reuses the
// parent kind's Reader — no second format to maintain.
func OpenSubagent(kind, cwd, sessionID, agentID string) (Source, error) {
	parent, err := Locate(kind, cwd, sessionID)
	if err != nil {
		return nil, err
	}
	return openSubagentBeside(parent, kind, agentID)
}

// openSubagentBeside resolves an id against a parent's subagents dir. Uses the
// cheap listing: matching an id needs no liveness.
func openSubagentBeside(parentPath, kind, agentID string) (Source, error) {
	for _, s := range listSubagentsBeside(parentPath) {
		if s.AgentID == agentID {
			return newFileSource(s.path, ReaderFor(kind)), nil
		}
	}
	return nil, ErrNoTranscript
}
