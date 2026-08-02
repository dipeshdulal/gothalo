package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
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
// client can detect an incompatible framing without guessing.
const transcriptProtocol = 1

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
//	hello                 — identity + backlog stats
//	entry (live:false) ×N — the backlog, oldest→newest (capped, see has_more)
//	backlog_complete      — boundary marker
//	entry (live:true)  …  — new entries as the agent appends them, forever
//
// The bridge resolves the pane's transcript file (transcript.Locate: session id,
// then newest-matching fallback), reads the backlog with a bounded ring buffer,
// then tails the file by short poll. It is READ-ONLY: it never writes to the pane
// (prompts/approvals stay on POST /send and POST /approve). Per-connection state
// is only the tailer's byte offset; the socket closing stops the poll.
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
	agent, err := s.herdr.Get(pane)
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

	// Read the backlog before the upgrade so a read failure is a clean 500 and we
	// know the resume offset for the tail.
	backlog, offset, err := transcript.ReadBacklog(path, reader, transcript.DefaultBacklogCap)
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

	// A read loop is required so the library processes client control frames (ping/
	// close); it also gives us prompt teardown when the client goes away. The client
	// isn't expected to send data — anything it sends is ignored.
	go func() {
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				cancel()
				return
			}
		}
	}()

	seq := 0
	send := func(v any) error {
		b, err := json.Marshal(v)
		if err != nil {
			return err
		}
		return conn.Write(ctx, websocket.MessageText, b)
	}

	log.Info("agent-transcript: streaming", "pane", pane, "kind", agent.Kind,
		"backlog", len(backlog.Entries), "total", backlog.Total, "has_more", backlog.HasMore)

	if err := send(helloFrame{
		Type:         "hello",
		Protocol:     transcriptProtocol,
		Pane:         pane,
		AgentKind:    agent.Kind,
		SessionID:    agent.SessionID(),
		BacklogCount: len(backlog.Entries),
		Total:        backlog.Total,
		HasMore:      backlog.HasMore,
	}); err != nil {
		return
	}

	for i := range backlog.Entries {
		seq++
		backlog.Entries[i].Seq = seq
		if err := send(entryFrame{Type: "entry", Live: false, Entry: &backlog.Entries[i]}); err != nil {
			return
		}
	}
	if err := send(backlogCompleteFrame{Type: "backlog_complete", Count: len(backlog.Entries), HasMore: backlog.HasMore}); err != nil {
		return
	}

	// Live tail: poll for appended lines, stream each new normalized entry.
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
