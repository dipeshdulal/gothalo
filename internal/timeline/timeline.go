// Package timeline records the recent PAST of every agent the bridge can see.
//
// Every other read surface answers "what is true now": /snapshot, /agent-state,
// the inbox, Priority. None of them can answer the question you actually have
// when you pick your phone up after an hour — has this agent been blocked for
// fifty minutes, or did it block ten seconds ago? The status is identical in
// both cases; only the elapsed time distinguishes "it is waiting on me" from
// "it is stuck and my afternoon is gone".
//
// So this package keeps one entry per agent status transition, each carrying the
// duration spent in the PREVIOUS status. That duration is the whole point: it is
// the one fact the snapshot genuinely cannot reconstruct, because Herdr's
// state_change_seq is a counter, not a clock, and nothing else remembers when a
// span began.
//
// It is deliberately NOT a mirror of live state (the mistake the deleted
// AgentEvents drift table made — see docs/RESEARCH-feature-ideas.md #8). It
// stores only the transitions themselves, and the app still reads current status
// from the snapshot.
//
// The ring is bounded twice over ([MaxEntries] and [Retention]) and persisted to
// a JSON file, because a bridge restart is precisely when the recent past is
// most valuable and an in-memory ring is emptiest.
package timeline

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/charmbracelet/log"
)

// MaxEntries caps the ring. Sized for "the last day or two of a busy fleet, in a
// file small enough to rewrite on a timer": ~200 bytes an entry puts a full ring
// around 300KB. Oldest entries are evicted first.
const MaxEntries = 1500

// Retention drops entries older than this, whatever the count. A timeline is a
// glanceable "what happened while I was away", not an audit log — a transition
// from four days ago answers no question the user is asking, and keeping it only
// pushes out something that does.
const Retention = 72 * time.Hour

// MaxLimit is the largest page GET /timeline will return, so one request can
// never be asked to marshal the entire ring.
const MaxLimit = 500

// DefaultLimit is the page size when the caller does not ask for one — deep
// enough to fill a phone screen several scrolls over.
const DefaultLimit = 100

// StatusGone is the synthetic "to" status recorded when a pane closes or its
// process exits. Herdr has no agent status for "the pane is gone", but for a
// timeline it is the most informative transition there is: it closes the span
// and tells you the agent stopped rather than went quiet.
const StatusGone = "gone"

// Entry is one recorded agent status transition.
//
// Field names are the wire contract (docs/CONTRACT-timeline.md); keep them and
// the doc in step.
type Entry struct {
	// TS is when the transition was observed, in unix milliseconds.
	TS int64 `json:"ts"`
	// Pane is the session-qualified pane id ("acme/w1:p2"), the same id every
	// other endpoint takes.
	Pane string `json:"pane"`
	// Agent is the agent kind ("claude", "codex", …), carried so a row can name
	// the agent without a second lookup — including for a pane that has since
	// closed and is no longer in any snapshot.
	Agent string `json:"agent,omitempty"`
	// Session is the Herdr session label ("default"), matching the bus payloads.
	Session string `json:"session,omitempty"`
	// Workspace is the session-qualified workspace id. It comes free on the bus
	// payload; the tab id does not, and resolving one would cost a Herdr read per
	// transition, so it is deliberately absent.
	Workspace string `json:"workspace,omitempty"`
	// From is the status being left. Empty means this is the first time the
	// bridge saw this pane at all (a newly detected agent), not a transition out
	// of an unnamed state.
	From string `json:"from,omitempty"`
	// To is the status entered — a Herdr agent status, or [StatusGone].
	To string `json:"to"`
	// PrevMS is how long the pane spent in From, in milliseconds. It is ABSENT,
	// not zero, when the span's start is not known — the first transition after
	// a gap in observation the bridge could not close (see
	// [Recorder.reconcile]). Zero is a real value (an instantaneous flip), so
	// the two must not be conflated.
	PrevMS *int64 `json:"prev_ms,omitempty"`
}

// Log is the bounded, persistent ring. All methods are safe for concurrent use:
// the recorder appends from the bus goroutine while HTTP handlers read.
type Log struct {
	path string
	now  func() time.Time

	mu sync.Mutex
	// entries is oldest-first, which is the order eviction wants. Readers get
	// newest-first — see [Log.Entries].
	entries []Entry
	// dirty means entries have changed since the last successful save. The ring
	// is flushed on a timer rather than on every append: transitions arrive in
	// bursts (an agent flipping working -> blocked -> working), and rewriting the
	// whole file per transition would turn a diagnostic nicety into steady disk
	// churn. See [Log.Flush].
	dirty bool
}

// Open loads the ring from path, dropping anything already past [Retention].
//
// It never fails. A missing file is the normal first-run case, and a corrupt or
// unreadable one degrades to an empty ring with a warning: the timeline is a
// convenience, and refusing to start the bridge — losing pairing, approvals and
// push with it — because a history file went bad would be wildly the wrong
// trade. The bad file is left in place for inspection and overwritten on the
// next flush.
func Open(path string) *Log {
	l := &Log{path: path, now: time.Now}
	b, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Warn("timeline: could not read history, starting empty", "path", path, "err", err)
		}
		return l
	}
	var entries []Entry
	if err := json.Unmarshal(b, &entries); err != nil {
		log.Warn("timeline: history file is unreadable, starting empty", "path", path, "err", err)
		return l
	}
	l.entries = entries
	l.sortLocked()
	l.evictLocked()
	log.Info("timeline: loaded history", "entries", len(l.entries))
	return l
}

// Append records one transition, evicting whatever the bounds require.
func (l *Log) Append(e Entry) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.entries = append(l.entries, e)
	// An entry can arrive out of order only if the clock moved backwards; sorting
	// on append keeps "oldest first" an invariant the readers can rely on rather
	// than a hope.
	if len(l.entries) > 1 && e.TS < l.entries[len(l.entries)-2].TS {
		l.sortLocked()
	}
	l.evictLocked()
	l.dirty = true
}

// Entries returns up to limit entries NEWEST FIRST, optionally restricted to one
// session-qualified pane. limit <= 0 means [DefaultLimit]; anything above
// [MaxLimit] is clamped to it.
//
// It always returns a non-nil slice, so the JSON body carries `[]` and never
// `null` — a client should not have to special-case "no history yet".
func (l *Log) Entries(limit int, pane string) []Entry {
	switch {
	case limit <= 0:
		limit = DefaultLimit
	case limit > MaxLimit:
		limit = MaxLimit
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]Entry, 0, min(limit, len(l.entries)))
	for i := len(l.entries) - 1; i >= 0 && len(out) < limit; i-- {
		if pane != "" && l.entries[i].Pane != pane {
			continue
		}
		out = append(out, l.entries[i])
	}
	return out
}

// Latest returns the newest recorded entry for a pane.
//
// This is what makes a restart cheap to recover from: the newest entry says
// which status a pane entered and exactly when, so a span that is still running
// can be resumed with its real start time instead of being restarted at boot.
// See [Recorder.reconcile].
func (l *Log) Latest(pane string) (Entry, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for i := len(l.entries) - 1; i >= 0; i-- {
		if l.entries[i].Pane == pane {
			return l.entries[i], true
		}
	}
	return Entry{}, false
}

// Len reports how many entries the ring currently holds.
func (l *Log) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.entries)
}

// Flush writes the ring to disk if anything changed since the last write. It is
// a no-op when clean, so it is safe to call on a tight timer.
//
// The write is atomic (temp file + rename) for the same reason the device
// registry's is: a half-written history that then fails to parse would take the
// whole recent past with it.
func (l *Log) Flush() error {
	l.mu.Lock()
	// Re-apply the bounds against the current clock BEFORE the dirty check, not
	// after. Retention is a promise about what the ring contains, and eviction is
	// driven by the clock, not by appends — so a quiet bridge (no transitions for
	// a day, which is exactly the state a retention window is for) would go on
	// serving and storing entries long past the window simply because nothing
	// arrived to trigger a trim. Evicting here makes the flush timer the thing
	// that enforces it; evicting also re-dirties the ring, so what lands on disk
	// is already trimmed.
	l.evictLocked()
	if !l.dirty {
		l.mu.Unlock()
		return nil
	}
	b, err := json.Marshal(l.entries)
	if err != nil {
		l.mu.Unlock()
		return err
	}
	l.dirty = false
	path := l.path
	l.mu.Unlock()

	if path == "" {
		return nil // memory-only (tests): nothing to persist to
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		l.markDirty()
		return fmt.Errorf("write timeline: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		l.markDirty()
		return fmt.Errorf("replace timeline: %w", err)
	}
	return nil
}

// markDirty re-arms the flush after a failed write, so a transient disk error
// costs a retry rather than the entries that were in flight when it happened.
func (l *Log) markDirty() {
	l.mu.Lock()
	l.dirty = true
	l.mu.Unlock()
}

// evictLocked applies both bounds: the retention window first (it is the one
// that can free a lot at once), then the hard count cap. Callers must hold l.mu.
func (l *Log) evictLocked() {
	cutoff := l.now().Add(-Retention).UnixMilli()
	keep := 0
	for keep < len(l.entries) && l.entries[keep].TS < cutoff {
		keep++
	}
	if keep > 0 {
		l.entries = append(l.entries[:0], l.entries[keep:]...)
		l.dirty = true
	}
	if over := len(l.entries) - MaxEntries; over > 0 {
		l.entries = append(l.entries[:0], l.entries[over:]...)
		l.dirty = true
	}
}

// sortLocked restores the oldest-first invariant. Callers must hold l.mu.
func (l *Log) sortLocked() {
	sort.SliceStable(l.entries, func(i, j int) bool { return l.entries[i].TS < l.entries[j].TS })
}
