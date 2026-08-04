package transcript

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	_ "modernc.org/sqlite"
)

// opencodeSource streams an opencode session out of its SQLite store.
//
// opencode's model is a level deeper than Hermes's: a `message` row is metadata
// (who spoke, when) and the content lives in child `part` rows, one per block —
// text, reasoning, a tool call, a step marker. So the query joins the two and the
// reader receives a part already carrying its message's role.
//
// The cursor is the part id. opencode's ids are time-sortable (verified against a
// live store: ordering by id and by time_created produce the same sequence), so
// `id > cursor` is both monotonic and index-friendly, exactly like Hermes's
// autoincrement.
//
// Child sessions (subagents, `session.parent_id` set) are naturally excluded:
// they carry their own session_id, and we only ever query the one herdr reports.
type opencodeSource struct {
	db        *sql.DB
	sessionID string

	mu     sync.Mutex
	cursor string // highest part id already emitted
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

// openOpencodeSource opens the store read-only and verifies the session exists,
// so a stale id 404s at connect rather than streaming nothing.
func openOpencodeSource(sessionID string) (Source, error) {
	if sessionID == "" {
		// opencode sessions are keyed by id, not cwd — without agent_session.value
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
	return &opencodeSource{db: db, sessionID: sessionID}, nil
}

// opencodeSelect joins each part to its message so the reader gets the role
// without a second lookup. Ordered by part id, which is chronological.
const opencodeSelect = `
	SELECT p.id, p.message_id, m.data, p.data
	  FROM part p
	  JOIN message m ON m.id = p.message_id
	 WHERE p.session_id = ?`

// scanParts normalizes a result set, calling fn per entry. fn returning false
// stops the scan. The highest part id seen is returned so the caller can advance
// its cursor even across rows that yielded no entries.
func (s *opencodeSource) scanParts(rows *sql.Rows, fn func(Entry) bool) (maxID string, err error) {
	defer rows.Close()
	for rows.Next() {
		var partID, messageID, messageData, partData string
		if err := rows.Scan(&partID, &messageID, &messageData, &partData); err != nil {
			return maxID, err
		}
		if partID > maxID {
			maxID = partID
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
				return maxID, nil
			}
		}
	}
	return maxID, rows.Err()
}

func (s *opencodeSource) Backlog(cap int) (Backlog, error) {
	rows, err := s.db.Query(opencodeSelect+` ORDER BY p.id`, s.sessionID)
	if err != nil {
		return Backlog{}, errUnexpected("opencode", err)
	}

	rb := newRing(cap)
	total, dropped := 0, false
	maxID, err := s.scanParts(rows, func(e Entry) bool {
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

	s.mu.Lock()
	if maxID > s.cursor {
		s.cursor = maxID
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
	if _, err := s.scanParts(rows, func(e Entry) bool {
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

// Poll returns entries from parts written since the last call.
//
// One caveat specific to opencode: a `tool` part is UPDATED in place as the call
// progresses (status running -> completed), rather than a new row being written.
// An id-only cursor therefore never re-emits it, so a tool call streams as its
// running form and its completion is picked up on the next connect. That is the
// honest trade for a monotonic cursor; re-reading updated rows would mean
// tracking time_updated and de-duplicating downstream, which the entry stream
// has no way to express today.
func (s *opencodeSource) Poll() ([]Entry, error) {
	s.mu.Lock()
	cursor := s.cursor
	s.mu.Unlock()

	rows, err := s.db.Query(opencodeSelect+` AND p.id > ? ORDER BY p.id`, s.sessionID, cursor)
	if err != nil {
		return nil, errUnexpected("opencode", err)
	}

	var out []Entry
	maxID, err := s.scanParts(rows, func(e Entry) bool {
		out = append(out, e)
		return true
	})
	if err != nil {
		return nil, errUnexpected("opencode", err)
	}

	s.mu.Lock()
	if maxID > s.cursor {
		s.cursor = maxID
	}
	s.mu.Unlock()
	return out, nil
}

func (s *opencodeSource) Close() error {
	if s.db == nil {
		return nil
	}
	return s.db.Close()
}
