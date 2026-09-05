package transcript

// Subagent liveness: which delegated conversations are still working.
//
// There are two ways an agent's end is recorded, and reading only one of them
// is wrong in opposite directions.
//
// An ASYNC agent's spawning call returns within seconds ("launched
// successfully") while the child runs on for minutes, so "the call has a
// result" would report every one of them finished. Verified against a live
// session: 15 calls, all with results, 6 children still appending. Their end
// arrives later as a task-notification carrying the AGENT id and a status.
// That is the join key, and it is exact — no recency threshold guesses at it.
// Bash and monitor tasks report through the same channel with their own ids,
// so matching is restricted to ids the roster knows.
//
// A SYNCHRONOUS agent never sends one. It reports by returning — its result is
// the completion — so reading notifications alone leaves it running forever.
// Measured on a plain parallel fan-out: 4 children, 4 results, the parent idle,
// zero task-notifications in the whole transcript. That is the common shape of
// delegation, so the row said "4 running" on a session that had finished, with
// the ages climbing — the exact stuck-agent signal the age exists to give.
//
// Which rule applies is not inferred from timing: the spawning call states it,
// as `run_in_background`. Absent means unknown and is treated as async (notify
// only), because guessing "synchronous" on an async call reinstates the first
// bug, while guessing "async" on a synchronous one merely leaves today's.
//
// Parsing is block-at-a-time, never one sweep for an id followed by a status.
// Two shapes on disk make the sweep wrong:
//
//  1. A block can name SEVERAL agents under a single status — the "no
//     completion record was found for 3 background agents" notice. A sweep
//     matches the first id and resumes past the status, so the rest are never
//     seen. They are the worst rows to lose: that block exists precisely
//     because those agents will never report for themselves, so a miss leaves
//     them running forever.
//
//  2. A block need not carry a status at all (monitor events use the same
//     envelope), and agent prose quotes these tags verbatim. A sweep pairs an
//     id in one block with a status from the next, or from a report that
//     merely talks about notifications.

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strings"
)

// notificationBlockRe isolates one whole task-notification. Everything else is
// matched only WITHIN a block, so no pairing can cross the boundary. Ungreedy,
// so adjacent blocks on one line stay separate.
var notificationBlockRe = regexp.MustCompile(
	`(?s)<task-notification>.*?</task-notification>`,
)

// taskIDRe matches every agent a block names. The class stops at a backslash so
// an escaped newline in the JSON-encoded line ends the capture rather than
// running on into the next field.
var taskIDRe = regexp.MustCompile(`<task-id>([^<\\]+)</task-id>`)

// statusRe matches a block's status. A block may legitimately carry none.
var statusRe = regexp.MustCompile(`<status>([^<\\]+)</status>`)

// runningStatus is the one status that does not end an agent. It also un-ends
// one: an agent can be resumed after a terminal status and report again (a real
// id went stopped → killed → failed → completed), so the last word wins rather
// than the first latching forever.
const runningStatus = "running"

// applyNotifications folds every notification in a chunk into done, in file
// order, last writer winning per id.
//
// The residual, which last_activity_ts is there to expose: a resumed agent is
// silent until it next reports, so between the resume and that report it still
// reads as finished while its age keeps advancing.
func applyNotifications(chunk []byte, done map[string]bool) {
	for _, block := range notificationBlockRe.FindAll(chunk, -1) {
		status := statusRe.FindSubmatch(block)
		if status == nil {
			continue
		}
		finished := !strings.EqualFold(
			strings.TrimSpace(string(status[1])), runningStatus)
		for _, id := range taskIDRe.FindAllSubmatch(block, -1) {
			done[string(id[1])] = finished
		}
	}
}

// spawnTools are the tool names that delegate a conversation. Two spellings
// because the tool was renamed; the join is on the tool-use id either way, so a
// third name costs only this line.
var spawnTools = map[string]bool{"Task": true, "Agent": true}

// scanBlock is one content block, cut down to the fields liveness needs.
type scanBlock struct {
	Type      string `json:"type"`
	Name      string `json:"name"`
	ID        string `json:"id"`
	ToolUseID string `json:"tool_use_id"`
	Input     struct {
		// Pointer so "absent" stays distinguishable from "false". Absent is
		// not synchronous: see the package comment.
		RunInBackground *bool `json:"run_in_background"`
	} `json:"input"`
}

// scanLine is one transcript line. Content sits under message for Claude and
// at the top level elsewhere; whichever is present is the one read.
type scanLine struct {
	Message struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
	Content json.RawMessage `json:"content"`
}

// applyToolCalls folds a chunk's spawning calls and their results into sync and
// results, both keyed by tool-use id.
//
// Parsed as JSON rather than swept for with a regex, for the same reason
// notifications are parsed a block at a time: a spawn's `prompt` is arbitrary
// text that routinely quotes field names, so pairing an id with a
// `run_in_background` found somewhere after it pairs across whatever the prompt
// happens to contain. JSON gives the boundary exactly.
func applyToolCalls(chunk []byte, sync, results map[string]bool) {
	for _, line := range bytes.Split(chunk, []byte{'\n'}) {
		// Most lines are prose. Decoding those costs more than the whole scan
		// saves, and neither field can be present without its name appearing.
		if !bytes.Contains(line, []byte("tool_use")) &&
			!bytes.Contains(line, []byte("tool_result")) {
			continue
		}
		var l scanLine
		if json.Unmarshal(line, &l) != nil {
			continue
		}
		raw := l.Message.Content
		if len(raw) == 0 {
			raw = l.Content
		}
		var blocks []scanBlock
		// Content is a bare string on plain messages; those carry no tool call.
		if len(raw) == 0 || json.Unmarshal(raw, &blocks) != nil {
			continue
		}
		for _, b := range blocks {
			switch {
			case b.Type == "tool_use" && spawnTools[b.Name] && b.ID != "":
				if b.Input.RunInBackground != nil && !*b.Input.RunInBackground {
					sync[b.ID] = true
				}
			case b.Type == "tool_result" && b.ToolUseID != "":
				results[b.ToolUseID] = true
			}
		}
	}
}
