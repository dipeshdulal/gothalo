package transcript

import (
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"sync"

	"github.com/dipeshdulal/gothalo/internal/opencode"
)

// opencodeV2PollPage and opencodeV2PollMax bound how far a single Poll walks
// back. A poll normally sees one or two new messages; the caps only matter after
// the bridge was paused long enough for a burst to land.
const (
	opencodeV2PollPage = 200
	opencodeV2PollMax  = 2000
)

// opencodeV2Source streams a session through OpenCode v2's managed service HTTP
// API instead of the legacy SQLite store.
//
// Why an API source rather than another file reader: v2 exposes a *projected*
// timeline (/api/session/{id}/message) already shaped like this package's Entry
// stream — user/system/synthetic prose, assistant text/reasoning/tool blocks,
// compaction summaries, and user-run shell commands. Normalizing that is much
// less code than reverse-engineering the store, and it is the interface v2
// treats as stable. The legacy database remains the fallback for a stopped
// service or an older install (see openOpencodeSource).
//
// Backlog loads the whole session once and keeps it in memory; Older is then a
// slice of that cache. The session is a chat — bounded in practice — so holding
// its normalized entries costs far less than re-deriving the absolute seq of
// every page, and it keeps seq stable across polls without a second server call.
// Poll is incremental: it walks back from the newest message until it meets the
// watermark, normalizes only what is new, and de-dupes on entry id so a message
// that grows between polls streams just its newly-appeared blocks.
type opencodeV2Source struct {
	svc       opencode.Service
	sessionID string
	cwd       string

	mu sync.Mutex
	// entries is every normalized entry loaded so far, ascending. Backlog seeds
	// it with the whole session; Poll appends.
	entries []Entry
	// seen holds entry ids already emitted, so a message that grows between polls
	// only streams its newly-appeared blocks (a text block that changes in place
	// keeps its id and is not re-sent).
	seen map[string]bool
	// watermark is the newest message already considered. Poll fetches messages
	// strictly newer than it and advances it only past messages that cannot grow
	// further (everything but a still-running final assistant turn).
	watermarkTime int64
	watermarkID   string
}

type opencodeV2MessagesResponse struct {
	Data   []json.RawMessage `json:"data"`
	Cursor struct {
		Next *string `json:"next"`
	} `json:"cursor"`
}

// request reads a service path, mapping the service's 404 to this package's
// "no transcript here" so callers keep their existing branching.
func (s *opencodeV2Source) request(path string) ([]byte, error) {
	b, err := s.svc.Get(path)
	if errors.Is(err, opencode.ErrNotFound) {
		return nil, ErrNoTranscript
	}
	return b, err
}

// loadAll fetches the whole session in ascending order, following the cursor
// until the server stops handing one back. The page size is left at the server
// default (OpenCode caps an explicit limit); the cursor makes that irrelevant.
//
// It returns the newest message and the one before it. Backlog needs both: the
// newest may be an assistant turn the model is still writing, and the watermark
// must stop at the previous message so the running turn is re-read (and its new
// blocks streamed) once it finishes.
func (s *opencodeV2Source) loadAll() ([]Entry, opencodeV2Message, opencodeV2Message, error) {
	base := "/api/session/" + url.PathEscape(s.sessionID) + "/message"
	path := base + "?order=asc"

	var all []Entry
	var newest, prev opencodeV2Message
	for path != "" {
		b, err := s.request(path)
		if err != nil {
			return nil, newest, prev, err
		}
		var page opencodeV2MessagesResponse
		if err := json.Unmarshal(b, &page); err != nil {
			return nil, newest, prev, err
		}
		for _, raw := range page.Data {
			all = append(all, normalizeOpencodeV2Message(raw)...)
			var m opencodeV2Message
			if json.Unmarshal(raw, &m) != nil {
				continue
			}
			if newerThan(m, newest.Time.Created, newest.ID) {
				prev = newest
				newest = m
			} else if newerThan(m, prev.Time.Created, prev.ID) {
				prev = m
			}
		}
		path = ""
		if page.Cursor.Next != nil {
			path = base + "?cursor=" + url.QueryEscape(*page.Cursor.Next)
		}
	}
	return all, newest, prev, nil
}

// newerThan reports whether m is strictly after the (time, id) watermark. Ids are
// time-ordered, so the id is a stable tiebreak for messages sharing a millisecond.
func newerThan(m opencodeV2Message, wTime int64, wID string) bool {
	if m.Time.Created != wTime {
		return m.Time.Created > wTime
	}
	return m.ID > wID
}

func (s *opencodeV2Source) Backlog(cap int) (Backlog, error) {
	entries, newest, prev, err := s.loadAll()
	if err != nil {
		return Backlog{}, errUnexpected("opencode", err)
	}

	// Arm the watermark at the newest SETTLED message. If the model is mid-turn,
	// the final assistant message is still growing: stop at the message before it
	// so Poll re-reads (and completes) it, while everything at or before it is
	// already delivered and stays quiet.
	watermark := newest
	if newest.Type == "assistant" && newest.Time.Completed == 0 {
		watermark = prev
	}

	s.mu.Lock()
	s.entries = entries
	s.seen = make(map[string]bool, len(entries))
	for _, e := range entries {
		s.seen[e.ID] = true
	}
	s.watermarkTime = watermark.Time.Created
	s.watermarkID = watermark.ID
	s.mu.Unlock()

	if cap < 0 {
		cap = 0
	}
	start := len(entries) - cap
	if start < 0 {
		start = 0
	}
	page := append([]Entry(nil), entries[start:]...)
	for i := range page {
		page[i].Seq = start + i + 1
	}
	oldest := 0
	if len(page) > 0 {
		oldest = start + 1
	}
	return Backlog{Entries: page, HasMore: start > 0, Total: len(entries), OldestSeq: oldest}, nil
}

func (s *opencodeV2Source) Older(beforeSeq, limit int) (OlderPage, error) {
	if limit < 1 {
		limit = 1
	}
	if beforeSeq <= 1 {
		return OlderPage{}, nil
	}
	s.mu.Lock()
	entries := append([]Entry(nil), s.entries...)
	s.mu.Unlock()

	end := beforeSeq - 1
	if end > len(entries) {
		end = len(entries)
	}
	start := end - limit
	if start < 0 {
		start = 0
	}
	page := append([]Entry(nil), entries[start:end]...)
	for i := range page {
		page[i].Seq = start + i + 1
	}
	oldest := 0
	if len(page) > 0 {
		oldest = start + 1
	}
	return OlderPage{Entries: page, OldestSeq: oldest, HasOlder: start > 0}, nil
}

// Poll returns entries that appeared since the last call. It walks back from the
// newest message, stopping at the watermark, then normalizes and emits only the
// entry ids it has not sent before. A message the model is still writing is
// re-read each poll: its existing blocks keep their ids and stay quiet, while a
// block that appears later streams once.
func (s *opencodeV2Source) Poll() ([]Entry, error) {
	s.mu.Lock()
	wTime, wID := s.watermarkTime, s.watermarkID
	s.mu.Unlock()

	var raws []json.RawMessage
	var metas []opencodeV2Message
	cursor := ""
	for {
		base := "/api/session/" + url.PathEscape(s.sessionID) + "/message"
		path := base + "?order=desc&limit=" + strconv.Itoa(opencodeV2PollPage)
		if cursor != "" {
			path = base + "?cursor=" + url.QueryEscape(cursor)
		}
		b, err := s.request(path)
		if err != nil {
			return nil, errUnexpected("opencode", err)
		}
		var page opencodeV2MessagesResponse
		if err := json.Unmarshal(b, &page); err != nil {
			return nil, errUnexpected("opencode", err)
		}
		reachedKnown := false
		for _, raw := range page.Data {
			var m opencodeV2Message
			if json.Unmarshal(raw, &m) != nil {
				continue
			}
			if !newerThan(m, wTime, wID) {
				reachedKnown = true
				break
			}
			raws = append(raws, raw)
			metas = append(metas, m)
		}
		if reachedKnown || len(page.Data) == 0 || page.Cursor.Next == nil || len(raws) >= opencodeV2PollMax {
			break
		}
		cursor = *page.Cursor.Next
	}

	// Descending pages arrive newest-first; the transcript stream is oldest-first.
	for i, j := 0, len(raws)-1; i < j; i, j = i+1, j-1 {
		raws[i], raws[j] = raws[j], raws[i]
		metas[i], metas[j] = metas[j], metas[i]
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.seen == nil {
		s.seen = map[string]bool{}
	}
	var out []Entry
	for i, raw := range raws {
		m := metas[i]
		for _, e := range normalizeOpencodeV2Message(raw) {
			if s.seen[e.ID] {
				continue
			}
			s.seen[e.ID] = true
			s.entries = append(s.entries, e)
			out = append(out, e)
		}
		// Advance only past a message that cannot grow: a non-assistant turn, a
		// completed assistant turn, or an assistant turn with younger messages
		// already present. The final still-running assistant stays past the
		// watermark and is re-read next poll.
		settled := m.Type != "assistant" || m.Time.Completed > 0 || i != len(raws)-1
		if settled {
			s.watermarkTime, s.watermarkID = m.Time.Created, m.ID
		}
	}
	return out, nil
}

func (s *opencodeV2Source) Close() error { return nil }

// openOpencodeV2Source resolves the managed service for this session and returns
// a source ready to stream. An empty session id is not fatal: the service can
// resolve one from the pane's cwd. Any failure to reach or verify the service is
// reported so the caller can fall back.
func openOpencodeV2Source(cwd, sessionID string) (Source, error) {
	svc, err := opencode.Discover()
	if err != nil {
		return nil, err
	}
	if sessionID == "" {
		sessionID, err = svc.SessionForCwd(cwd)
	} else {
		err = svc.Verify(sessionID, cwd)
	}
	if err != nil {
		if errors.Is(err, opencode.ErrNotFound) {
			return nil, ErrNoTranscript
		}
		return nil, err
	}
	return &opencodeV2Source{svc: svc, sessionID: sessionID, cwd: cwd, seen: map[string]bool{}}, nil
}
