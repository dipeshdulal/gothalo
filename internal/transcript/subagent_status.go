package transcript

// Subagent liveness: which delegated conversations are still working.
//
// The obvious signal — "the spawning Task call has no tool_result yet" — is
// wrong for the case that matters. An ASYNC agent's call returns within seconds
// ("launched successfully") and the child then runs for minutes, so every row
// would read as finished while four agents were demonstrably alive. Verified
// against a live session: 15 Task calls, all with results, 6 children still
// appending.
//
// Completion is reported to the parent later, as a task-notification carrying
// the AGENT id and a status. That is the join key, and it is exact — no
// recency threshold guesses at it. Bash and monitor tasks report through the
// same channel with their own ids, so matching is restricted to ids the roster
// knows.
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
