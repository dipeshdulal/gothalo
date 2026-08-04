package transcript

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	_ "modernc.org/sqlite" // pure-Go driver; no cgo, so the build stays portable
)

// hermesSummaryRunes caps a Hermes tool call's one-line input summary.
const hermesSummaryRunes = 200

// hermesSource streams a Hermes session out of ~/.hermes/state.db.
//
// Hermes is the first non-file backend, and it is why Source exists: there is no
// path to tail and no byte offset to resume from. The cursor is instead the
// `messages.id` autoincrement, which is strictly monotonic per session — a
// better cursor than a byte offset, since it cannot be invalidated by a rewrite.
//
// Seq (the client's paging cursor) is NOT the row id. One row expands into
// several entries — an assistant turn carries reasoning, prose, and N tool calls
// — so seq counts *entries*, exactly as it does for a JSONL file where one line
// can expand the same way. That means Backlog and Older normalize the session's
// rows to count entries, mirroring ReadBacklog/ReadOlder. Sessions are bounded
// (hundreds to low thousands of rows) and the read is indexed by
// idx_messages_session, so this stays cheap; memory is bounded by the same ring
// buffer the file path uses.
type hermesSource struct {
	db        *sql.DB
	sessionID string

	// mu guards cursor: Poll runs on the connection goroutine while Older runs on
	// the socket's read goroutine. database/sql is itself concurrency-safe.
	mu     sync.Mutex
	cursor int64 // highest messages.id already emitted
}

// hermesDBPath returns the Hermes state database, honouring $HERMES_DIR for
// non-default installs.
func hermesDBPath() string {
	dir := os.Getenv("HERMES_DIR")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		dir = filepath.Join(home, ".hermes")
	}
	return filepath.Join(dir, "state.db")
}

// openHermesSource opens the state database read-only and verifies the session
// exists, so a stale session id 404s at connect rather than streaming empty.
//
// The connection is read-only and opened with immutable=false: Hermes writes to
// this database continuously in WAL mode, and a reader must see those commits.
func openHermesSource(sessionID string) (Source, error) {
	if sessionID == "" {
		// Without agent_session.value there is nothing to look up — Hermes sessions
		// are keyed by id, not by cwd, so there is no fallback to guess with. This is
		// the "install the herdr integration" case; see the README.
		return nil, ErrNoTranscript
	}
	path := hermesDBPath()
	if path == "" {
		return nil, ErrNoTranscript
	}
	if _, err := os.Stat(path); err != nil {
		return nil, ErrNoTranscript
	}

	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro")
	if err != nil {
		return nil, errUnexpected("hermes", err)
	}
	// One connection is plenty for a read-only poller and keeps WAL handling simple.
	db.SetMaxOpenConns(1)

	var n int
	if err := db.QueryRow(`SELECT count(*) FROM sessions WHERE id = ?`, sessionID).Scan(&n); err != nil {
		db.Close()
		return nil, errUnexpected("hermes", err)
	}
	if n == 0 {
		db.Close()
		return nil, ErrNoTranscript
	}
	return &hermesSource{db: db, sessionID: sessionID}, nil
}

// hermesSelect is the column list shared by every read. `active = 1` drops rows
// Hermes has retired via compaction, which are summarized elsewhere and would
// otherwise appear twice in the conversation.
const hermesSelect = `
	SELECT id, role,
	       COALESCE(content, ''), COALESCE(tool_call_id, ''),
	       COALESCE(tool_calls, ''), COALESCE(tool_name, ''),
	       COALESCE(reasoning, ''), COALESCE(timestamp, 0)
	  FROM messages
	 WHERE session_id = ? AND active = 1`

// scanRows turns a result set into normalized entries, in row order, calling fn
// for each entry. fn returning false stops the scan early (used by Older to stop
// at the cursor).
func (s *hermesSource) scanRows(rows *sql.Rows, fn func(Entry) bool) error {
	defer rows.Close()
	for rows.Next() {
		var r hermesRow
		if err := rows.Scan(&r.ID, &r.Role, &r.Content, &r.ToolCallID,
			&r.ToolCalls, &r.ToolName, &r.Reasoning, &r.Timestamp); err != nil {
			return err
		}
		line, err := json.Marshal(r)
		if err != nil {
			continue // a row we cannot even marshal is skipped, not fatal
		}
		for _, e := range (hermesReader{}).Normalize(line) {
			if !fn(e) {
				return nil
			}
		}
	}
	return rows.Err()
}

// Backlog normalizes the whole session to count entries, keeps the newest cap in
// a ring buffer, and arms the cursor at the highest row id seen.
func (s *hermesSource) Backlog(cap int) (Backlog, error) {
	rows, err := s.db.Query(hermesSelect+` ORDER BY id`, s.sessionID)
	if err != nil {
		return Backlog{}, errUnexpected("hermes", err)
	}

	rb := newRing(cap)
	total, dropped := 0, false
	if err := s.scanRows(rows, func(e Entry) bool {
		total++
		if rb.push(e) {
			dropped = true
		}
		return true
	}); err != nil {
		return Backlog{}, errUnexpected("hermes", err)
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

	// Arm the tail at the session's current max row id, so Poll returns only what
	// arrives after this page. Done as its own query rather than tracked during the
	// scan, so a session whose every row normalized to zero entries still advances.
	var maxID sql.NullInt64
	if err := s.db.QueryRow(
		`SELECT max(id) FROM messages WHERE session_id = ? AND active = 1`,
		s.sessionID).Scan(&maxID); err != nil {
		return Backlog{}, errUnexpected("hermes", err)
	}
	s.mu.Lock()
	s.cursor = maxID.Int64
	s.mu.Unlock()

	return Backlog{Entries: entries, HasMore: dropped, Total: total, OldestSeq: oldest}, nil
}

// Older returns up to limit entries with seq < beforeSeq, oldest first. Like the
// file backend it rescans from the start and stops at the cursor: seq is a
// position in the normalized entry stream, so there is no row to seek directly to.
func (s *hermesSource) Older(beforeSeq, limit int) (OlderPage, error) {
	if limit < 1 {
		limit = 1
	}
	if beforeSeq <= 1 {
		return OlderPage{}, nil
	}

	rows, err := s.db.Query(hermesSelect+` ORDER BY id`, s.sessionID)
	if err != nil {
		return OlderPage{}, errUnexpected("hermes", err)
	}

	rb := newRing(limit)
	seq := 0
	if err := s.scanRows(rows, func(e Entry) bool {
		seq++
		if seq >= beforeSeq {
			return false // reached the cursor; nothing from here is older
		}
		e.Seq = seq
		rb.push(e)
		return true
	}); err != nil {
		return OlderPage{}, errUnexpected("hermes", err)
	}

	entries := rb.slice()
	page := OlderPage{Entries: entries}
	if len(entries) > 0 {
		page.OldestSeq = entries[0].Seq
		page.HasOlder = entries[0].Seq > 1
	}
	return page, nil
}

// Poll returns entries from rows committed since the last call. Because the
// cursor is a row id rather than a byte offset, a rewritten or vacuumed database
// cannot replay history — ids only move forward.
func (s *hermesSource) Poll() ([]Entry, error) {
	s.mu.Lock()
	cursor := s.cursor
	s.mu.Unlock()

	rows, err := s.db.Query(hermesSelect+` AND id > ? ORDER BY id`, s.sessionID, cursor)
	if err != nil {
		return nil, errUnexpected("hermes", err)
	}

	var out []Entry
	var maxID int64 = cursor
	// Track the row id alongside the entries so the cursor advances even when a row
	// normalizes to nothing (a session_meta row, say).
	if err := func() error {
		defer rows.Close()
		for rows.Next() {
			var r hermesRow
			if err := rows.Scan(&r.ID, &r.Role, &r.Content, &r.ToolCallID,
				&r.ToolCalls, &r.ToolName, &r.Reasoning, &r.Timestamp); err != nil {
				return err
			}
			if r.ID > maxID {
				maxID = r.ID
			}
			line, err := json.Marshal(r)
			if err != nil {
				continue
			}
			out = append(out, (hermesReader{}).Normalize(line)...)
		}
		return rows.Err()
	}(); err != nil {
		return nil, errUnexpected("hermes", err)
	}

	s.mu.Lock()
	if maxID > s.cursor {
		s.cursor = maxID
	}
	s.mu.Unlock()
	return out, nil
}

func (s *hermesSource) Close() error {
	if s.db == nil {
		return nil
	}
	if err := s.db.Close(); err != nil {
		return fmt.Errorf("transcript/hermes: close: %w", err)
	}
	return nil
}
