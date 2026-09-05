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
// recency threshold guesses at it. Bash tasks report through the same channel
// with their own ids, so matching is restricted to ids the roster knows.

import (
	"regexp"
)

// notificationRe matches one task-notification's id and status. Tolerant of
// whatever sits between them (the block carries several other tags) and of the
// JSON escaping the line has been through by the time it is on disk.
var notificationRe = regexp.MustCompile(
	`<task-id>([^<\\]+)</task-id>.*?<status>([^<\\]+)</status>`,
)

// runningStatus is the one status that does NOT end an agent. Anything else a
// notification reports — completed, failed, cancelled — has stopped it, and
// treating an unknown status as still-running would leave a row claiming to
// work forever.
const runningStatus = "running"
