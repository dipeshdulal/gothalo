package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/charmbracelet/log"
	"github.com/coder/websocket"

	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/transcript"
)

// transcriptPollInterval is how often the tail re-reads the transcript file for
// newly-appended lines. Claude Code writes a line per streamed block, so a short
// poll keeps the chat feeling live without an fsnotify dependency.
const transcriptPollInterval = 250 * time.Millisecond

// transcriptProtocol is the wire-protocol version echoed in the hello frame, so a
// client can detect an incompatible framing without guessing. Bumped to 2 when
// the backlog became paginated (newest page + load_older) and inbound control
// frames stopped being end-of-stream.
const transcriptProtocol = 2

// transcriptNewestPage is how many newest normalized entries the backlog sends on
// connect. Small enough for a cheap mobile connect; older history is fetched on
// demand via load_older. Tune here.
const transcriptNewestPage = 150

// transcriptDefaultOlderLimit is the page size used for a load_older frame that
// omits (or zeroes) its limit.
const transcriptDefaultOlderLimit = 150

// transcriptMaxOlderLimit caps a client-requested load_older limit so one page
// can't ask for an unbounded slice.
const transcriptMaxOlderLimit = 500

// helloFrame is the first frame sent on connect: identity + backlog stats, before
// any entry frames.
type helloFrame struct {
	Type         string `json:"type"` // "hello"
	Protocol     int    `json:"protocol"`
	Pane         string `json:"pane"`
	AgentKind    string `json:"agent_kind"`
	SessionID    string `json:"session_id"`
	BacklogCount int    `json:"backlog_count"` // entries about to be sent as backlog
	Total        int    `json:"total"`         // total normalized entries in the file
	HasMore      bool   `json:"has_more"`      // older entries elided by the backlog cap
	// OldestLoadedSeq is the absolute seq of the oldest entry in this first page
	// (0 when empty). A client pages older by sending it back as before_seq.
	OldestLoadedSeq int `json:"oldest_loaded_seq"`
	// HasOlder is true when entries with seq < OldestLoadedSeq exist (== HasMore;
	// named for the load_older cursor semantics).
	HasOlder bool `json:"has_older"`
}

// loadOlderFrame is the one client→server control frame: fetch the page of history
// immediately older than BeforeSeq (up to Limit entries).
type loadOlderFrame struct {
	Type      string `json:"type"` // "load_older"
	BeforeSeq int    `json:"before_seq"`
	Limit     int    `json:"limit"`
}

// pageCompleteFrame closes a load_older response: it follows the older entry
// frames and tells the client how far back it now has and whether to keep paging.
type pageCompleteFrame struct {
	Type               string `json:"type"` // "page_complete"
	RequestedBeforeSeq int    `json:"requested_before_seq"`
	OldestLoadedSeq    int    `json:"oldest_loaded_seq"`
	HasOlder           bool   `json:"has_older"`
}

// entryFrame carries one normalized entry. Live is false for backlog entries and
// true for entries appended after connect (the live tail).
type entryFrame struct {
	Type  string            `json:"type"` // "entry"
	Live  bool              `json:"live"`
	Entry *transcript.Entry `json:"entry"`
}

// backlogCompleteFrame marks the boundary between the replayed backlog and the
// live tail, so the app can, e.g., stop showing a spinner and jump to the bottom.
type backlogCompleteFrame struct {
	Type    string `json:"type"` // "backlog_complete"
	Count   int    `json:"count"`
	HasMore bool   `json:"has_more"`
}

// GET /agent-transcript?pane=<pane_id>&token=<...> — upgraded to a WebSocket that
// streams an agent's own structured transcript as a chat feed. Unlike /attach
// (binary raw PTY bytes), every frame here is TEXT JSON, one normalized entry per
// frame:
//
//	hello                 — identity + pagination stats (oldest_loaded_seq/has_older)
//	entry (live:false) ×N — the newest page, oldest→newest (~transcriptNewestPage)
//	backlog_complete      — boundary marker
//	entry (live:true)  …  — new entries as the agent appends them, forever
//
// Backlog is PAGINATED: only the newest transcriptNewestPage entries are sent on
// connect. To read older history the client sends a control frame over the same
// socket:
//
//	{"type":"load_older","before_seq":<int>,"limit":<int>}
//
// and the server replies with that page — entry frames (live:false, oldest→newest)
// for entries with seq < before_seq, up to limit — then a page_complete frame with
// the new oldest_loaded_seq + has_older. The live tail keeps running independently
// while a page loads. Any other/garbage inbound frame closes the socket cleanly.
// seq is the absolute 1-based position of an entry in the whole file, so it is a
// stable cursor across pages.
//
// The bridge resolves the pane's transcript file (transcript.Locate: session id,
// then newest-matching fallback), reads each page with a bounded ring buffer (the
// whole file is never held), then tails the file by short poll. It is READ-ONLY:
// it never writes to the pane (prompts/approvals stay on POST /send and POST
// /approve). Per-connection state is only the tailer's byte offset + the seq
// counter; the socket closing stops the poll.
//
// Auth mirrors /attach: ?token=<bearer> (per-device or admin), because WS clients
// can't set an Authorization header. Errors are surfaced as clean HTTP statuses
// BEFORE the upgrade (400 missing pane, 401 unauthorized, 404 no agent/transcript,
// 502 herdr, 500 read), so the client sees a real status rather than a torn socket.
func (s *Server) handleAgentTranscript(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorize(r); !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	pane := r.URL.Query().Get("pane")
	if pane == "" {
		http.Error(w, "want ?pane=<pane_id>", http.StatusBadRequest)
		return
	}

	// Resolve the agent (for kind/cwd/session) before upgrading, so a missing agent
	// or transcript is a clean HTTP status, not a dropped socket.
	c, _, bare, err := s.target(pane)
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}
	agent, err := c.Get(bare)
	if err != nil {
		if errors.Is(err, herdr.ErrAgentNotFound) {
			http.Error(w, "no such agent", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}

	path, err := transcript.Locate(agent.Kind, agent.Cwd, agent.SessionID())
	if err != nil {
		log.Warn("agent-transcript: locate failed", "pane", pane, "kind", agent.Kind, "err", err)
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	reader := transcript.ReaderFor(agent.Kind)

	// Read the newest page before the upgrade so a read failure is a clean 500 and
	// we know the resume offset for the tail. Entries come back with their absolute
	// seq stamped, so the page's oldest seq is a real cursor into the file.
	backlog, offset, err := transcript.ReadBacklog(path, reader, transcriptNewestPage)
	if err != nil {
		log.Error("agent-transcript: backlog read failed", "pane", pane, "path", path, "err", err)
		http.Error(w, "read transcript failed", http.StatusInternalServerError)
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		log.Error("agent-transcript: ws accept failed", "pane", pane, "err", err)
		return
	}
	defer conn.CloseNow()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// The live tail (this goroutine) and load_older replies (the read goroutine)
	// both write to the socket; coder/websocket forbids concurrent writes, so all
	// sends go through this mutex.
	var writeMu sync.Mutex
	send := func(v any) error {
		b, err := json.Marshal(v)
		if err != nil {
			return err
		}
		writeMu.Lock()
		defer writeMu.Unlock()
		return conn.Write(ctx, websocket.MessageText, b)
	}

	// Read loop: inbound frames are control messages now, not end-of-stream. A
	// well-formed load_older is serviced; ping/close are handled by the library;
	// anything else (garbage, unknown type, non-text) closes the socket cleanly.
	// It runs independently of the live tail below.
	go func() {
		for {
			typ, data, err := conn.Read(ctx)
			if err != nil {
				cancel()
				return
			}
			if typ != websocket.MessageText {
				closeClean(conn, "expected text control frame")
				cancel()
				return
			}
			var ctrl loadOlderFrame
			if err := json.Unmarshal(data, &ctrl); err != nil || ctrl.Type != "load_older" {
				closeClean(conn, "unrecognized control frame")
				cancel()
				return
			}
			if err := serveOlder(ctx, reader, path, pane, ctrl, send); err != nil {
				cancel()
				return
			}
		}
	}()

	log.Info("agent-transcript: streaming", "pane", pane, "kind", agent.Kind,
		"page", len(backlog.Entries), "total", backlog.Total, "has_older", backlog.HasMore)

	if err := send(helloFrame{
		Type:            "hello",
		Protocol:        transcriptProtocol,
		Pane:            pane,
		AgentKind:       agent.Kind,
		SessionID:       agent.SessionID(),
		BacklogCount:    len(backlog.Entries),
		Total:           backlog.Total,
		HasMore:         backlog.HasMore,
		OldestLoadedSeq: backlog.OldestSeq,
		HasOlder:        backlog.HasMore,
	}); err != nil {
		return
	}

	for i := range backlog.Entries {
		if err := send(entryFrame{Type: "entry", Live: false, Entry: &backlog.Entries[i]}); err != nil {
			return
		}
	}
	if err := send(backlogCompleteFrame{Type: "backlog_complete", Count: len(backlog.Entries), HasMore: backlog.HasMore}); err != nil {
		return
	}

	// Live tail: poll for appended lines, stream each new normalized entry. seq
	// continues from Total (the newest file entry's absolute seq), so appended
	// entries keep the same absolute cursor as the backlog page.
	seq := backlog.Total
	tailer := transcript.NewTailer(path, reader, offset)
	ticker := time.NewTicker(transcriptPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Info("agent-transcript: closed", "pane", pane)
			conn.Close(websocket.StatusNormalClosure, "")
			return
		case <-ticker.C:
			ents, err := tailer.Poll()
			if err != nil {
				// Transient (file briefly unavailable during a rotation); keep polling.
				log.Warn("agent-transcript: poll failed", "pane", pane, "err", err)
				continue
			}
			for i := range ents {
				seq++
				ents[i].Seq = seq
				if err := send(entryFrame{Type: "entry", Live: true, Entry: &ents[i]}); err != nil {
					return
				}
			}
		}
	}
}

// serveOlder handles one load_older control frame: it reads the page of entries
// immediately older than before_seq (bounded, streaming) and writes them as
// live:false entry frames oldest→newest, then a page_complete frame carrying the
// new oldest_loaded_seq + has_older. A read failure is non-fatal to the socket —
// it is logged and reported as an empty page — so a bad cursor never tears down
// the live tail. It returns a non-nil error only when a socket write fails.
func serveOlder(ctx context.Context, reader transcript.Reader, path, pane string, req loadOlderFrame, send func(any) error) error {
	limit := req.Limit
	if limit <= 0 {
		limit = transcriptDefaultOlderLimit
	}
	if limit > transcriptMaxOlderLimit {
		limit = transcriptMaxOlderLimit
	}

	page, err := transcript.ReadOlder(path, reader, req.BeforeSeq, limit)
	if err != nil {
		log.Warn("agent-transcript: load_older read failed", "pane", pane, "before_seq", req.BeforeSeq, "err", err)
		page = transcript.OlderPage{} // empty page; keep the socket alive
	}

	for i := range page.Entries {
		if err := send(entryFrame{Type: "entry", Live: false, Entry: &page.Entries[i]}); err != nil {
			return err
		}
	}
	return send(pageCompleteFrame{
		Type:               "page_complete",
		RequestedBeforeSeq: req.BeforeSeq,
		OldestLoadedSeq:    page.OldestSeq,
		HasOlder:           page.HasOlder,
	})
}

// closeClean sends a normal (1000) WebSocket close with a reason. Used when an
// inbound frame is unrecognized: the framing changed so garbage is a client bug,
// but we still tear down gracefully rather than crash.
func closeClean(conn *websocket.Conn, reason string) {
	conn.Close(websocket.StatusNormalClosure, reason)
}
