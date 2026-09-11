package transcript

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// opencodeSettle is how long a part must go untouched before the tail treats it
// as final and streams it.
//
// opencode does not append immutable records the way Claude's JSONL does: it
// INSERTs a part and then UPDATEs it in place as content streams in (measured on
// a live store: 20 of 24 text parts and every reasoning and tool part carried
// time_updated > time_created). A cursor that only ever moves forward past new
// ids therefore sees each part exactly once, at creation, when it is still empty
// — and an empty part normalizes to nothing, so messages never appeared at all.
//
// Waiting for a quiet period is what makes the content complete when we read it.
// The alternative — re-emitting a part as it grows — is not expressible today:
// the client de-dupes on seq and DISCARDS a repeat, so a re-emit is either
// dropped (same seq) or renders the message twice (new seq). Streaming text live
// needs a protocol that can say "replace", which this is not.
const opencodeSettle = 1200 * time.Millisecond

// opencodeSource streams an opencode session out of its SQLite store.
//
// opencode's model is a level deeper than Hermes's: a `message` row is metadata
// (who spoke, when) and the content lives in child `part` rows, one per block —
// text, reasoning, a tool call, a step marker. So the query joins the two and the
// reader receives a part already carrying its message's role.
//
// Backlog and Older read in part-id order, which is chronological (verified on a
// live store: ordering by id and by time_created give the same sequence). The
// live tail cannot use that ordering — see opencodeSettle.
//
// Child sessions (subagents, `session.parent_id` set) are naturally excluded:
// they carry their own session_id, and we only ever query the one herdr reports.
type opencodeSource struct {
	db        *sql.DB
	sessionID string

	mu sync.Mutex
	// watermark is the highest time_updated already considered for streaming.
	watermark int64
	// emitted guards against a part that changes again after it looked settled;
	// without it that part would stream twice under two different seqs.
	emitted map[string]bool
}

// opencodeDBPath returns opencode's SQLite store, honouring $OPENCODE_DATA_DIR
// and XDG_DATA_HOME for non-default installs.
func opencodeDBPath() string {
	if dir := os.Getenv("OPENCODE_DATA_DIR"); dir != "" {
		return filepath.Join(dir, "opencode.db")
	}
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(base, "opencode", "opencode.db")
}

// openOpencodeSource resolves an opencode pane to a streamable transcript.
//
// OpenCode v2 exposes a supported HTTP API, so it is tried first. Its managed
// service resolves the session by id, or by cwd when herdr has not reported one
// (the opencode TUI integration does not always set agent_session, and without a
// cwd fallback every opencode pane would 404). The legacy database is the
// fallback for a stopped service or an older install.
func openOpencodeSource(cwd, sessionID string) (Source, error) {
	if src, err := openOpencodeV2Source(cwd, sessionID); err == nil {
		return src, nil
	}

	if sessionID == "" {
		// The legacy store is keyed by id, not cwd — without agent_session.value
		// there is nothing to look up. See the README on the herdr integration.
		return nil, ErrNoTranscript
	}
	path := opencodeDBPath()
	if path == "" {
		return nil, ErrNoTranscript
	}
	if _, err := os.Stat(path); err != nil {
		return nil, ErrNoTranscript
	}

	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		return nil, errUnexpected("opencode", err)
	}
	db.SetMaxOpenConns(1)

	var n int
	if err := db.QueryRow(`SELECT count(*) FROM session WHERE id = ?`, sessionID).Scan(&n); err != nil {
		db.Close()
		return nil, errUnexpected("opencode", err)
	}
	if n == 0 {
		db.Close()
		return nil, ErrNoTranscript
	}
	return &opencodeSource{db: db, sessionID: sessionID, emitted: map[string]bool{}}, nil
}

// opencodeSelect joins each part to its message so the reader gets the role
// without a second lookup. Ordered by part id, which is chronological.
const opencodeSelect = `
	SELECT p.id, p.message_id, p.time_updated, m.data, p.data
	  FROM part p
	  JOIN message m ON m.id = p.message_id
	 WHERE p.session_id = ?`

// scanParts normalizes a result set, calling fn per entry. fn returning false
// stops the scan. It records every part id it read in `seen` (when non-nil) and
// returns the highest time_updated observed, so the caller can advance its
// watermark even across rows that yielded no entries.
func (s *opencodeSource) scanParts(rows *sql.Rows, seen map[string]bool, fn func(Entry) bool) (maxUpdated int64, err error) {
	defer rows.Close()
	for rows.Next() {
		var partID, messageID, messageData, partData string
		var updated int64
		if err := rows.Scan(&partID, &messageID, &updated, &messageData, &partData); err != nil {
			return maxUpdated, err
		}
		if updated > maxUpdated {
			maxUpdated = updated
		}
		if seen != nil {
			seen[partID] = true
		}
		line, err := json.Marshal(opencodeRow{
			ID:      partID,
			Message: messageID,
			MsgData: json.RawMessage(messageData),
			Part:    json.RawMessage(partData),
		})
		if err != nil {
			continue
		}
		for _, e := range (opencodeReader{}).Normalize(line) {
			if !fn(e) {
				return maxUpdated, nil
			}
		}
	}
	return maxUpdated, rows.Err()
}

// nowMillis is the clock the settle window is measured against (a seam for tests).
var nowMillis = func() int64 { return time.Now().UnixMilli() }

func (s *opencodeSource) Backlog(cap int) (Backlog, error) {
	rows, err := s.db.Query(opencodeSelect+` ORDER BY p.id`, s.sessionID)
	if err != nil {
		return Backlog{}, errUnexpected("opencode", err)
	}

	rb := newRing(cap)
	total, dropped := 0, false
	seen := map[string]bool{}
	maxUpdated, err := s.scanParts(rows, seen, func(e Entry) bool {
		total++
		if rb.push(e) {
			dropped = true
		}
		return true
	})
	if err != nil {
		return Backlog{}, errUnexpected("opencode", err)
	}

	entries := rb.slice()
	base := total - len(entries)
	for i := range entries {
		entries[i].Seq = base + i + 1
	}
	oldest := 0
	if len(entries) > 0 {
		oldest = base + 1
	}

	// Everything on screen at connect counts as delivered, whether or not it had
	// settled: a part still streaming when you connect shows its partial text and
	// is completed on the next connect, rather than arriving twice.
	s.mu.Lock()
	s.emitted = seen
	if maxUpdated > s.watermark {
		s.watermark = maxUpdated
	}
	s.mu.Unlock()

	return Backlog{Entries: entries, HasMore: dropped, Total: total, OldestSeq: oldest}, nil
}

func (s *opencodeSource) Older(beforeSeq, limit int) (OlderPage, error) {
	if limit < 1 {
		limit = 1
	}
	if beforeSeq <= 1 {
		return OlderPage{}, nil
	}

	rows, err := s.db.Query(opencodeSelect+` ORDER BY p.id`, s.sessionID)
	if err != nil {
		return OlderPage{}, errUnexpected("opencode", err)
	}

	rb := newRing(limit)
	seq := 0
	if _, err := s.scanParts(rows, nil, func(e Entry) bool {
		seq++
		if seq >= beforeSeq {
			return false
		}
		e.Seq = seq
		rb.push(e)
		return true
	}); err != nil {
		return OlderPage{}, errUnexpected("opencode", err)
	}

	entries := rb.slice()
	page := OlderPage{Entries: entries}
	if len(entries) > 0 {
		page.OldestSeq = entries[0].Seq
		page.HasOlder = entries[0].Seq > 1
	}
	return page, nil
}

// Poll returns entries for parts that have settled since the last call — those
// whose time_updated has advanced past the watermark and then gone quiet for
// opencodeSettle. See that constant for why the wait is necessary: opencode
// mutates a part as content streams into it, so reading one the instant it
// appears yields an empty row.
//
// The cost is latency, not correctness: a message shows up roughly a settle
// window after the agent finishes writing it, rather than growing token by
// token. Live-growing text would need the wire protocol to express "replace an
// entry", which it cannot — the client de-dupes on seq and drops repeats.
func (s *opencodeSource) Poll() ([]Entry, error) {
	s.mu.Lock()
	watermark := s.watermark
	s.mu.Unlock()

	settledBefore := nowMillis() - opencodeSettle.Milliseconds()
	rows, err := s.db.Query(
		opencodeSelect+` AND p.time_updated > ? AND p.time_updated <= ? ORDER BY p.time_updated, p.id`,
		s.sessionID, watermark, settledBefore)
	if err != nil {
		return nil, errUnexpected("opencode", err)
	}

	seen := map[string]bool{}
	var out []Entry
	maxUpdated, err := s.scanParts(rows, seen, func(e Entry) bool {
		out = append(out, e)
		return true
	})
	if err != nil {
		return nil, errUnexpected("opencode", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	// Drop anything already delivered: a part that settled, streamed, and was then
	// touched again would otherwise arrive a second time under a fresh seq.
	kept := out[:0]
	for i, e := range out {
		id := partIDOf(e)
		if s.emitted[id] {
			continue
		}
		kept = append(kept, out[i])
	}
	for id := range seen {
		s.emitted[id] = true
	}
	if maxUpdated > s.watermark {
		s.watermark = maxUpdated
	}
	return kept, nil
}

// partIDOf recovers the source part id from an entry id. A tool part expands
// into "<part>#call" and "<part>#result", so the suffix is trimmed.
func partIDOf(e Entry) string {
	if i := strings.IndexByte(e.ID, '#'); i >= 0 {
		return e.ID[:i]
	}
	return e.ID
}

func (s *opencodeSource) Close() error {
	if s.db == nil {
		return nil
	}
	return s.db.Close()
}
