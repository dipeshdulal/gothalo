package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
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
// frames stopped being end-of-stream; to 3 when hello gained the session's
// subagent roster and ?subagent= let a client stream a delegated conversation;
// to 4 when hello stopped being once-per-socket (a session rotation re-sends
// session_changed + hello + backlog); to 5 when the subagent roster stopped
// being connect-time-only and gained its own `subagents` frame.
const transcriptProtocol = 5

// transcriptRosterInterval is how often the stream re-reads the subagent roster.
//
// The roster used to ride only in hello, which is sent on connect and on
// rotation — so a chat left open while four agents finished went on saying they
// were running, with their ages climbing. Slower than the tail poll because it
// lists a directory and scans the parent, and an agent finishing is a
// human-scale event; fast enough that the answer is never visibly stale.
const transcriptRosterInterval = 3 * time.Second

// transcriptSessionPollInterval is how often the stream re-reads the pane's agent
// session id to notice a rotation. Slower than the tail poll because it is a
// round-trip to the Herdr socket, and starting a new session is a human-scale
// event — a second or two of the old transcript is not worth a chattier poll.
const transcriptSessionPollInterval = 2 * time.Second

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
	// Subagent echoes the ?subagent= that is being streamed, or "" for the
	// session's own transcript. A client that reconnects can tell from hello
	// alone which conversation it landed in.
	Subagent string `json:"subagent,omitempty"`
	// Subagents is the session's complete, FLAT subagent roster — every depth,
	// not just children of the conversation being streamed. That is deliberate:
	// a subagent's own children are found by matching their ToolUseID against
	// the Tool.ID of the Task calls in whichever transcript is on screen, so one
	// roster serves every level and drilling down needs no extra round trip.
	// Omitted entirely when the session delegated nothing, which is the norm.
	Subagents []transcript.Subagent `json:"subagents,omitempty"`
}

// subagentsFrame re-sends the whole roster when it has changed — an agent
// spawned, or one the parent has now been told finished. Whole rather than a
// delta because it is small and a client that misses one delta would be wrong
// until the next rotation.
type subagentsFrame struct {
	Type      string                `json:"type"` // "subagents"
	Pane      string                `json:"pane"`
	Subagents []transcript.Subagent `json:"subagents"`
}

// rosterSignature collapses a roster to the part a client can see change:
// which agents exist and whether each has finished.
//
// Age is deliberately excluded. A working agent's last_activity_ts advances
// every few seconds, and resending the roster for that alone would be a frame
// every tick to say nothing the client cannot already compute.
func rosterSignature(subs []transcript.Subagent) string {
	var b strings.Builder
	for _, s := range subs {
		b.WriteString(s.AgentID)
		if s.Done {
			b.WriteByte('+')
		}
		b.WriteByte(';')
	}
	return b.String()
}

// sessionChangedFrame announces that the pane's agent started a NEW session and
// this socket has re-pointed at it. It is followed by a fresh hello, the new
// session's backlog and a backlog_complete — byte for byte what a client gets on
// connect — so the whole rotation is handled without a reconnect.
//
// A client MUST discard everything it has buffered when it sees this: seq is
// absolute WITHIN a session, so the new session restarts at 1 and its entries
// would otherwise collide with (and be de-duped against) the old ones.
type sessionChangedFrame struct {
	Type string `json:"type"` // "session_changed"
	Pane string `json:"pane"`
	From string `json:"from"` // the session id this socket was following
	To   string `json:"to"`   // the session id it now follows
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
// The socket also FOLLOWS THE PANE ACROSS SESSIONS. An agent's session id is not
// fixed for the life of a pane: /clear, /new, /resume or a restarted agent all
// rotate it, and the old transcript file then stops growing — a socket pinned to
// the file it resolved at connect just goes silent, which reads as a hung app.
// So the stream re-reads the pane's session id every transcriptSessionPollInterval
// and, when it changes, reopens on the new session and replays the opening
// sequence in place:
//
//	session_changed  — {from, to}: discard everything buffered
//	hello            — now carrying the NEW session_id
//	entry (live:false) ×N + backlog_complete — the new session's newest page
//
// after which the live tail resumes against the new session. Detection is on the
// session ID, not on watching for a "/new" being typed, so it fires however the
// session was started — from the app, from the keyboard at the machine, or by the
// agent itself. A ?subagent= stream is exempt: it is one delegated conversation
// belonging to the session that spawned it, and following a rotation would swap
// the user onto a different conversation than the one they opened.
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

	if other, ambiguous := siblingSharesCwd(c, bare, agent); ambiguous {
		// Resolution would fall back to matching on working directory, and a
		// sibling agent in the same directory makes that a coin flip. Answer
		// "not yet" rather than serve the sibling's conversation — see
		// siblingSharesCwd.
		log.Warn("agent-transcript: unresolvable, session id unknown and a sibling shares the cwd",
			"pane", pane, "sibling", other, "cwd", agent.Cwd)
		http.Error(w, "transcript not available yet — this agent has not reported its session id", http.StatusNotFound)
		return
	}

	// Open the pane's transcript through the per-kind Source registry. What backs
	// it — a JSONL file for Claude, a SQLite database for Hermes — is the source's
	// business; everything below here is storage-agnostic.
	//
	// ?subagent=<agent_id> streams a delegated conversation instead of the
	// session's own. It is the same JSONL dialect behind the same Source
	// interface, so nothing downstream — paging, tailing, framing — changes.
	// The id is matched against discovery rather than pasted into a path, so a
	// hostile value resolves to nothing rather than escaping the session dir.
	var src transcript.Source
	sub := r.URL.Query().Get("subagent")
	if sub != "" {
		src, err = transcript.OpenSubagent(agent.Kind, agent.Cwd, agent.SessionID(), sub)
	} else {
		src, err = transcript.Open(agent.Kind, agent.Cwd, agent.SessionID())
	}
	if err != nil {
		log.Warn("agent-transcript: open failed", "pane", pane, "kind", agent.Kind,
			"subagent", sub, "err", err)
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	stream := &transcriptStream{src: src, sessionID: agent.SessionID()}
	defer stream.Close()

	// The roster is advisory: a session that delegated nothing, or a kind with no
	// subagent concept, yields an empty list. A failure here must not cost the
	// user their transcript, so it is logged and the stream continues without it.
	subagents, err := transcript.Subagents(agent.Kind, agent.Cwd, agent.SessionID())
	if err != nil {
		log.Warn("agent-transcript: subagent discovery failed", "pane", pane,
			"kind", agent.Kind, "err", err)
		subagents = nil
	}

	// Read the newest page before the upgrade so a read failure is a clean 500.
	// This also arms the source's read cursor, so the live tail below resumes
	// exactly where this page ended. Entries carry their absolute seq, so the
	// page's oldest seq is a real cursor into the session.
	backlog, err := stream.Backlog(transcriptNewestPage)
	if err != nil {
		log.Error("agent-transcript: backlog read failed", "pane", pane, "kind", agent.Kind, "err", err)
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
			if err := serveOlder(ctx, stream, pane, ctrl, send); err != nil {
				cancel()
				return
			}
		}
	}()

	log.Info("agent-transcript: streaming", "pane", pane, "kind", agent.Kind,
		"page", len(backlog.Entries), "total", backlog.Total, "has_older", backlog.HasMore)

	opening := transcriptOpening{
		pane:      pane,
		kind:      agent.Kind,
		sessionID: stream.SessionID(),
		subagent:  sub,
		subagents: subagents,
	}
	if err := sendOpening(send, opening, backlog); err != nil {
		return
	}

	// Live tail: poll the source, stream each new normalized entry. seq continues
	// from Total (the newest entry's absolute seq), so new entries keep the same
	// absolute cursor as the backlog page.
	//
	// The second ticker watches for the pane's agent starting a NEW session and
	// re-points this socket at it (see the header comment). seq restarts with it,
	// because it is absolute within a session.
	//
	// A ?subagent= stream does NOT follow rotations: it is one delegated
	// conversation belonging to the session that spawned it, and that transcript
	// is complete in itself. Re-pointing it at the new session's root transcript
	// would silently swap the user onto a different conversation than the one
	// they drilled into. A nil channel here simply never fires.
	seq := backlog.Total
	ticker := time.NewTicker(transcriptPollInterval)
	defer ticker.Stop()
	var sessionTick <-chan time.Time
	if sub == "" {
		sessionTicker := time.NewTicker(transcriptSessionPollInterval)
		defer sessionTicker.Stop()
		sessionTick = sessionTicker.C
	}
	// The roster changes without the transcript changing — an agent the parent
	// was told about finished — so it needs its own beat rather than riding on
	// the tail.
	rosterTicker := time.NewTicker(transcriptRosterInterval)
	defer rosterTicker.Stop()
	rosterSig := rosterSignature(subagents)
	for {
		select {
		case <-ctx.Done():
			log.Info("agent-transcript: closed", "pane", pane)
			conn.Close(websocket.StatusNormalClosure, "")
			return
		case <-sessionTick:
			next, ok := s.rotatedSession(c, bare, pane, stream.SessionID())
			if !ok {
				continue
			}
			// Read the new session's opening page BEFORE swapping: a failure here
			// leaves the socket on the old session (still live, still tailing)
			// rather than on a half-open new one, and the next tick retries.
			nextBacklog, err := next.src.Backlog(transcriptNewestPage)
			if err != nil {
				log.Warn("agent-transcript: new-session backlog failed", "pane", pane,
					"session", next.sessionID, "err", err)
				_ = next.src.Close()
				continue
			}
			from := stream.Swap(next.src, next.sessionID)
			log.Info("agent-transcript: session rotated", "pane", pane, "from", from,
				"to", next.sessionID, "page", len(nextBacklog.Entries), "total", nextBacklog.Total)
			if err := send(sessionChangedFrame{Type: "session_changed", Pane: pane, From: from, To: next.sessionID}); err != nil {
				return
			}
			if err := sendOpening(send, next.opening(pane), nextBacklog); err != nil {
				return
			}
			seq = nextBacklog.Total
			rosterSig = rosterSignature(next.subagents)
		case <-rosterTicker.C:
			next, err := transcript.Subagents(agent.Kind, agent.Cwd, stream.SessionID())
			if err != nil {
				// A roster that cannot be read must never cost the conversation;
				// keep the one the client already has.
				continue
			}
			if sig := rosterSignature(next); sig != rosterSig {
				rosterSig = sig
				if err := send(subagentsFrame{Type: "subagents", Pane: pane, Subagents: next}); err != nil {
					return
				}
			}
		case <-ticker.C:
			ents, err := stream.Poll()
			if err != nil {
				// Transient (store briefly unavailable, e.g. a file rotation or a
				// locked database); keep polling.
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

// transcriptOpening is the identity half of a hello — everything the frame says
// about the conversation, as opposed to the backlog page it introduces. It is a
// struct because a rotation has to reproduce all of it for the new session, and
// a five-string parameter list is where "kind" and "sessionID" get swapped.
type transcriptOpening struct {
	pane      string
	kind      string
	sessionID string
	subagent  string
	subagents []transcript.Subagent
}

// sendOpening writes the three frames that open a session on this socket: hello,
// the backlog page oldest→newest, then backlog_complete. It runs both on connect
// and after a session rotation — the client's handling of a new session is
// therefore identical to its handling of a fresh connect, which is the point.
func sendOpening(send func(any) error, op transcriptOpening, backlog transcript.Backlog) error {
	if err := send(helloFrame{
		Type:            "hello",
		Protocol:        transcriptProtocol,
		Pane:            op.pane,
		AgentKind:       op.kind,
		SessionID:       op.sessionID,
		BacklogCount:    len(backlog.Entries),
		Total:           backlog.Total,
		HasMore:         backlog.HasMore,
		OldestLoadedSeq: backlog.OldestSeq,
		HasOlder:        backlog.HasMore,
		Subagent:        op.subagent,
		Subagents:       op.subagents,
	}); err != nil {
		return err
	}
	for i := range backlog.Entries {
		if err := send(entryFrame{Type: "entry", Live: false, Entry: &backlog.Entries[i]}); err != nil {
			return err
		}
	}
	return send(backlogCompleteFrame{Type: "backlog_complete", Count: len(backlog.Entries), HasMore: backlog.HasMore})
}

// openedSession is a transcript opened on a session the socket has not adopted
// yet — returned by rotatedSession so the caller can read its first page before
// committing to it.
type openedSession struct {
	src       transcript.Source
	sessionID string
	kind      string
	subagents []transcript.Subagent
}

// opening is the hello identity for this session. The subagent field is always
// empty: a ?subagent= stream never rotates (see the live tail), so a rotation is
// by construction a root transcript.
func (o openedSession) opening(pane string) transcriptOpening {
	return transcriptOpening{
		pane:      pane,
		kind:      o.kind,
		sessionID: o.sessionID,
		subagents: o.subagents,
	}
}

// rotatedSession reports whether the pane's agent is now on a session other than
// current and, if so, returns that session opened and ready to read.
//
// Everything here is deliberately quiet: this runs on a timer against a live
// socket, so an agent that has momentarily vanished, a Herdr blip, or a session
// whose transcript is not resolvable yet must leave the existing stream alone and
// let the next tick try again. Only a genuine, openable rotation returns ok.
func (s *Server) rotatedSession(c *herdr.Client, bare, pane, current string) (openedSession, bool) {
	agent, err := c.Get(bare)
	if err != nil {
		// The agent may be gone for good (the pane closed), but tearing the socket
		// down here is not this function's job: the client's own reconnect path
		// already checks whether the pane still exists.
		log.Debug("agent-transcript: session check failed", "pane", pane, "err", err)
		return openedSession{}, false
	}
	next := agent.SessionID()
	// An empty id is "Herdr does not know yet", not "the session ended" — holding
	// the current stream is strictly better than dropping to the newest-file
	// fallback, which can resolve to another pane's conversation.
	if next == "" || next == current {
		return openedSession{}, false
	}
	src, err := transcript.Open(agent.Kind, agent.Cwd, next)
	if err != nil {
		// Not yet resolvable (or the new kind has no transcript support). Stay put;
		// the next tick retries. Claude's opener already handles the common case —
		// a named session whose file has not been written yet — by pointing at
		// where the file will be, so this is genuinely the unusual path.
		log.Debug("agent-transcript: new session not openable yet", "pane", pane,
			"session", next, "kind", agent.Kind, "err", err)
		return openedSession{}, false
	}
	// The roster belongs to the session, so a rotation invalidates the one hello
	// already sent. A fresh session has usually delegated nothing yet, which is
	// exactly why it must be re-read rather than carried over. Advisory as on
	// connect: a discovery failure costs the roster, not the transcript.
	subagents, err := transcript.Subagents(agent.Kind, agent.Cwd, next)
	if err != nil {
		log.Warn("agent-transcript: subagent discovery failed for new session", "pane", pane,
			"session", next, "kind", agent.Kind, "err", err)
		subagents = nil
	}
	return openedSession{src: src, sessionID: next, kind: agent.Kind, subagents: subagents}, true
}

// transcriptStream is the session a socket is currently following: its open
// Source plus that session's id. It exists because the session can rotate under a
// live socket, so "the source" is no longer a value the handler can close over —
// the live tail (connection goroutine) and load_older (read goroutine) both reach
// for it while the tail may be swapping it out.
//
// The mutex is held across the underlying call rather than just around the field
// read, so a swap can never close a Source that another goroutine is mid-read on.
// Older is the slow one, and it briefly delays a tail poll; that is the right
// trade for not handing back entries from a closed source.
type transcriptStream struct {
	mu        sync.Mutex
	src       transcript.Source
	sessionID string
}

// SessionID returns the id of the session currently being followed.
func (t *transcriptStream) SessionID() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.sessionID
}

// Swap adopts src as the followed session, closing the one it replaces, and
// returns the id of that previous session.
func (t *transcriptStream) Swap(src transcript.Source, sessionID string) (previous string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	old := t.src
	previous, t.src, t.sessionID = t.sessionID, src, sessionID
	if old != nil {
		_ = old.Close()
	}
	return previous
}

func (t *transcriptStream) Backlog(cap int) (transcript.Backlog, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.src.Backlog(cap)
}

func (t *transcriptStream) Older(beforeSeq, limit int) (transcript.OlderPage, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.src.Older(beforeSeq, limit)
}

func (t *transcriptStream) Poll() ([]transcript.Entry, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.src.Poll()
}

func (t *transcriptStream) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.src.Close()
}

// serveOlder handles one load_older control frame: it reads the page of entries
// immediately older than before_seq (bounded, streaming) and writes them as
// live:false entry frames oldest→newest, then a page_complete frame carrying the
// new oldest_loaded_seq + has_older. A read failure is non-fatal to the socket —
// it is logged and reported as an empty page — so a bad cursor never tears down
// the live tail. It returns a non-nil error only when a socket write fails.
func serveOlder(ctx context.Context, stream *transcriptStream, pane string, req loadOlderFrame, send func(any) error) error {
	limit := req.Limit
	if limit <= 0 {
		limit = transcriptDefaultOlderLimit
	}
	if limit > transcriptMaxOlderLimit {
		limit = transcriptMaxOlderLimit
	}

	page, err := stream.Older(req.BeforeSeq, limit)
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

// siblingSharesCwd reports whether this pane's transcript is unresolvable
// because another live agent OF THE SAME KIND occupies the same working
// directory, naming that sibling for the log.
//
// It only ever fires when the agent has NO session id. With one, resolution is
// exact and a sibling is irrelevant. Without one, resolution falls back to
// "newest transcript for this directory" — and if a same-kind sibling shares
// that directory, the fallback cannot tell the two apart. It does not fail; it
// confidently returns the wrong conversation. A sibling of a DIFFERENT kind is
// harmless: each kind resolves in its own namespace (Claude's project dir, pi's
// session dir, OpenCode's service), so it can never be the transcript this pane
// would land on.
//
// That is not hypothetical. Starting an agent in a directory Claude has not
// trusted parks it on a permission prompt, so it has no session id until the
// operator answers — and a phone that navigates there meanwhile was served an
// unrelated agent's 259-message history, three times running. The first agent in
// a new directory is exactly when that prompt appears, which makes this the
// common path rather than a corner.
//
// [transcript.Locate] already refuses to guess when a KNOWN session id has no
// file yet ("not written yet must read as absent, not as license to guess").
// This extends the same rule to the case where the session id is not known at
// all — which the resolver cannot detect on its own, because only the bridge
// knows what other agents are live.
func siblingSharesCwd(c *herdr.Client, bare string, agent herdr.Agent) (sibling string, ambiguous bool) {
	if agent.SessionID() != "" || agent.Cwd == "" {
		return "", false
	}
	agents, err := c.Agents()
	if err != nil {
		// Can't tell, so don't block a read on a failed side lookup.
		return "", false
	}
	return siblingInSameCwd(agents, bare, agent)
}

// siblingInSameCwd is the decision [siblingSharesCwd] makes once it has the
// agent list, split out so it is testable without a Herdr socket.
func siblingInSameCwd(agents []herdr.Agent, bare string, agent herdr.Agent) (sibling string, ambiguous bool) {
	if agent.SessionID() != "" || agent.Cwd == "" {
		return "", false
	}
	for _, other := range agents {
		if other.PaneID == bare || other.Cwd != agent.Cwd || other.Kind != agent.Kind {
			continue
		}
		return other.PaneID, true
	}
	return "", false
}
