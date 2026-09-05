package transcript

// Subagent counts for the snapshot: "4 running" on an agent row, without
// opening its chat.
//
// This runs on the snapshot path, which is polled constantly, against parents
// that reach 1.4 MB — so the completion scan behind it is incremental. A
// transcript is append-only, so after the first pass each poll reads only the
// bytes added since, and the whole file is re-read only when it shrinks
// (a rewrite, a rotation).
//
// Counting does NOT read the children: [subagentsBeside] tails every child to
// date it, which is right for a roster of rows and wasteful for a number. A
// directory listing gives the total, and the cached completion set gives the
// rest.

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Counts is how many subagents a session has, and how many are still working.
type Counts struct {
	Total   int `json:"total"`
	Running int `json:"running"`
}

// scanState is how far a parent has been scanned and what it yielded.
//
// offset is the end of the last COMPLETE line. A transcript caught mid-append
// leaves a partial line at the tail; resuming after it would split a
// notification across two scans so neither ever matches.
type scanState struct {
	offset int64
	read   int64 // bytes ever read for this path; test-only accounting
	used   time.Time
	done   map[string]bool
}

// scanCacheMax bounds the cache. Every session rotation is a new parent path
// and the bridge runs for weeks, so without a cap this grows for the life of
// the process. Far above the number of panes any host actually runs, so the
// eviction below is a backstop rather than something that fires in normal use.
const scanCacheMax = 256

var (
	scanMu    sync.Mutex
	scanCache = map[string]*scanState{}
)

// completedAgents reports the agent ids this parent has been told are
// finished, reading only what it has not read before.
func completedAgents(parentPath string) map[string]bool {
	scanMu.Lock()
	defer scanMu.Unlock()

	st := scanCache[parentPath]
	if st == nil {
		evictScanCache()
		st = &scanState{done: map[string]bool{}}
		scanCache[parentPath] = st
	}
	st.used = time.Now()

	info, err := os.Stat(parentPath)
	if err != nil {
		return copyDone(st.done)
	}
	// Shrunk means rewritten, not appended: everything learned is suspect.
	if info.Size() < st.offset {
		st.offset = 0
		st.done = map[string]bool{}
	}
	if info.Size() == st.offset {
		return copyDone(st.done)
	}

	f, err := os.Open(parentPath)
	if err != nil {
		return copyDone(st.done)
	}
	defer f.Close()

	buf := make([]byte, info.Size()-st.offset)
	n, err := f.ReadAt(buf, st.offset)
	if n == 0 && err != nil {
		return copyDone(st.done)
	}
	buf = buf[:n]
	st.read += int64(n)

	// Stop at the last newline; the remainder is a line still being written.
	complete := strings.LastIndexByte(string(buf), '\n')
	if complete < 0 {
		return copyDone(st.done)
	}
	chunk := buf[:complete+1]
	st.offset += int64(len(chunk))

	for _, m := range notificationRe.FindAllSubmatch(chunk, -1) {
		status := strings.ToLower(strings.TrimSpace(string(m[2])))
		if status == runningStatus {
			continue
		}
		st.done[string(m[1])] = true
	}
	return copyDone(st.done)
}

// evictScanCache drops the least recently used half once the cache is full.
// Half rather than one, so eviction runs rarely instead of on every insert
// past the cap. Callers hold scanMu.
func evictScanCache() {
	if len(scanCache) < scanCacheMax {
		return
	}
	paths := make([]string, 0, len(scanCache))
	for p := range scanCache {
		paths = append(paths, p)
	}
	sort.Slice(paths, func(i, j int) bool {
		return scanCache[paths[i]].used.Before(scanCache[paths[j]].used)
	})
	for _, p := range paths[:len(paths)/2] {
		delete(scanCache, p)
	}
}

// resetScanCache empties the cache. Tests only.
func resetScanCache() {
	scanMu.Lock()
	defer scanMu.Unlock()
	scanCache = map[string]*scanState{}
}

func copyDone(in map[string]bool) map[string]bool {
	out := make(map[string]bool, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

// scanStats reports the bytes ever read for a parent. Test accounting for the
// incremental guarantee; nothing in the bridge reads it.
func scanStats(parentPath string) int64 {
	scanMu.Lock()
	defer scanMu.Unlock()
	if st := scanCache[parentPath]; st != nil {
		return st.read
	}
	return 0
}

// SubagentCounts reports a pane's session's subagent totals, and whether they
// could be determined at all. Zero total is a normal answer, not a failure:
// most sessions delegate nothing.
func SubagentCounts(kind, cwd, sessionID string) (Counts, bool) {
	parent, err := Locate(kind, cwd, sessionID)
	if err != nil {
		return Counts{}, false
	}
	return countsBeside(parent), true
}

// countsBeside counts the subagents dir beside a parent transcript.
func countsBeside(parentPath string) Counts {
	entries, err := os.ReadDir(subagentDirFor(parentPath))
	if err != nil {
		return Counts{}
	}
	done := completedAgents(parentPath)

	var c Counts
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		id, ok := agentIDFromMeta(e.Name())
		if !ok {
			continue
		}
		// Same rule as discovery: a meta without its transcript is not a row.
		if !isFile(filepath.Join(subagentDirFor(parentPath), "agent-"+id+".jsonl")) {
			continue
		}
		c.Total++
		if !done[id] {
			c.Running++
		}
	}
	return c
}
