package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"time"

	"github.com/charmbracelet/log"
	"github.com/coder/websocket"
	"github.com/creack/pty"

	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// paneFallbackInterval is a slow safety-net read for a plain pane, in case a
// pane.updated event is ever missed; the live path is the subscription below.
const paneFallbackInterval = 1 * time.Second

// paneCoalesce bounds the repaint rate: a burst of pane.updated events (a single
// keystroke can emit ~20) collapses into repaints at most this often.
const paneCoalesce = 40 * time.Millisecond

// GET /attach?pane=<pane_id>&token=<...> — upgraded to a WebSocket that streams
// a live terminal for ANY pane (agent, shell, dev-server, logs…). It bridges:
//
//	terminal bytes ──▶ WS  (binary frames the client renders)
//	WS             ──▶ terminal stdin  (keystrokes/control bytes the client sends)
//
// Two backends, chosen by pane kind, behind one WS contract:
//
//   - Agent panes keep the high-fidelity path: `herdr agent attach <pane>` under
//     a PTY, bridging raw bytes both ways.
//   - Plain panes have no agent to attach, so the bridge polls
//     `herdr pane read` and repaints the socket, and forwards inbound bytes as
//     a mix of `pane send-text` (literal text) and `pane send-keys` (Enter,
//     arrows, Ctrl-C — see splitPaneInput, since send-text drops those).
//
// Frame types: **binary** frames are raw terminal bytes (the accessory key row
// writes control bytes straight into this stream, D6). **text** frames are
// out-of-band control messages; today the only one is
// `{"type":"resize","cols":C,"rows":R}`, which sizes the PTY so the client's
// line-editing (autocomplete, wrapping) stays aligned with its viewport. The
// backend process/poller is stopped when the WS closes.
//
// Auth uses the same authorize() path as every other endpoint, and accepts
// ?token= because WS clients can't always set an Authorization header.
func (s *Server) handleAttach(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorize(r); !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	pane := r.URL.Query().Get("pane")
	if pane == "" {
		http.Error(w, "want ?pane=<pane_id>", http.StatusBadRequest)
		return
	}
	c, _, bare, err := s.target(pane)
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}

	// Resolve the pane before upgrading so a missing pane is a clean HTTP 404
	// (not a torn-down socket), and so we can pick the right backend.
	info, err := c.GetPane(bare)
	if err != nil {
		log.Error("attach: pane lookup failed", "pane", pane, "err", err)
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}

	// Auth is by bearer/token, not Origin, so origin verification is disabled;
	// a phone connects cross-origin and can't forge a valid token.
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		log.Error("attach: ws accept failed", "pane", pane, "err", err)
		return
	}
	defer conn.CloseNow()
	// Match the old NetConn behaviour: don't cap a single inbound message (a
	// large paste arrives as one binary frame). Control frames are tiny anyway.
	conn.SetReadLimit(-1)

	if info.IsAgent() {
		attachAgentPTY(conn, c, bare)
		return
	}
	attachPaneStream(conn, c, bare)
}

// attachAgentPTY streams an agent pane via `herdr agent attach` under a PTY,
// bridging raw bytes both ways. Binary frames from the client are stdin; text
// frames are control messages (resize), applied with pty.Setsize.
func attachAgentPTY(conn *websocket.Conn, c *herdr.Client, pane string) {
	cmd := c.AttachCommand(pane)
	// A sane default geometry; the client sends its real size on connect (and on
	// every later resize) as a text control frame, which we apply below.
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 24, Cols: 80})
	if err != nil {
		log.Error("attach: pty start failed", "pane", pane, "err", err)
		conn.Close(websocket.StatusInternalError, "attach failed")
		return
	}
	defer func() {
		_ = ptmx.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	// A background-derived context bounds the socket's lifetime independent of
	// the (hijacked) request context; cancelling it unblocks both loops.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	log.Info("attach: streaming agent", "pane", pane)

	// Bridge both directions. Whichever side ends first (client disconnects, or
	// the attach process exits) unblocks the other via the deferred teardown.
	// coder/websocket allows one concurrent reader + one concurrent writer.
	done := make(chan struct{}, 2)
	// pty -> WS: raw terminal bytes as binary frames.
	go func() {
		defer func() { done <- struct{}{} }()
		buf := make([]byte, 32*1024)
		for {
			n, rerr := ptmx.Read(buf)
			if n > 0 {
				if werr := conn.Write(ctx, websocket.MessageBinary, buf[:n]); werr != nil {
					return
				}
			}
			if rerr != nil {
				return
			}
		}
	}()
	// WS -> pty: binary frames are stdin; text frames are control (resize).
	go func() {
		defer func() { done <- struct{}{} }()
		for {
			typ, data, rerr := conn.Read(ctx)
			if rerr != nil {
				return
			}
			if typ == websocket.MessageText {
				applyResize(ptmx, data, pane)
				continue
			}
			if _, werr := ptmx.Write(data); werr != nil {
				return
			}
		}
	}()
	<-done

	log.Info("attach: closed", "pane", pane)
	conn.Close(websocket.StatusNormalClosure, "")
}

// attachPaneStream bridges a non-agent pane. Herdr exposes no live stream for a
// plain pane, so we mirror it: forward inbound binary frames to the pane via
// send-text, and repaint the visible frame to the client. Rather than poll on a
// fixed tick, we subscribe to Herdr's pane.updated event for THIS pane and
// repaint on change (coalesced), with a slow fallback read as a safety net — so
// interactive redraws (autocomplete, history recall) track near-live instead of
// being sampled a few times a second. Text frames (resize) are swallowed —
// Herdr owns a plain pane's geometry.
func attachPaneStream(conn *websocket.Conn, c *herdr.Client, pane string) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	log.Info("attach: streaming pane", "pane", pane)

	done := make(chan struct{}, 3)

	// WS -> pane: binary frames are raw keystrokes; text frames are control
	// messages we ignore for a plain pane (so the JSON never reaches the shell).
	go func() {
		defer func() { done <- struct{}{} }()
		for {
			typ, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			if typ == websocket.MessageText {
				continue
			}
			// send-text types text and drops control sequences, so keys are
			// split out and pressed via send-keys — see splitPaneInput.
			for _, chunk := range splitPaneInput(string(data)) {
				var e error
				if chunk.key != "" {
					e = c.SendKeys(pane, chunk.key)
				} else {
					e = c.Send(pane, chunk.text)
				}
				if e != nil {
					log.Error("attach: pane input failed", "pane", pane, "chunk", chunk, "err", e)
				}
			}
		}
	}()

	// dirty carries a coalesced "this pane changed" signal from the subscription
	// (and the fallback ticker) to the repaint loop.
	dirty := make(chan struct{}, 1)
	poke := func() {
		select {
		case dirty <- struct{}{}:
		default: // a signal is already pending; one repaint takes the latest frame
		}
	}

	// Subscribe to pane.updated for this pane on its own Herdr connection and
	// poke the repaint loop on each event. Torn down with the attach.
	go func() {
		defer func() { done <- struct{}{} }()
		path, err := c.ServerSocketPath()
		if err != nil {
			return
		}
		sub, err := herdr.DialSocket(path)
		if err != nil {
			log.Error("attach: subscribe dial failed", "pane", pane, "err", err)
			return
		}
		defer sub.Close()
		go func() { <-ctx.Done(); sub.Close() }()
		if err := sub.Subscribe([]herdr.Subscription{{Type: "pane.updated", PaneID: pane}}); err != nil {
			log.Error("attach: subscribe failed", "pane", pane, "err", err)
			return
		}
		for {
			msg, err := sub.ReadMessage()
			if err != nil {
				return
			}
			if msg.Event != "" {
				poke()
			}
		}
	}()

	// Seed the client's scrollback, once, before the first repaint. A plain pane
	// has no live byte stream to replay: the client only ever receives whole
	// frames prefixed with a clear-screen, so its buffer holds nothing to scroll
	// back through. Herdr does hold the history — a `docker compose logs -f`
	// pane had 10,467 rows of it — and hands over the last [herdr.PaneHistoryRows]
	// on request, which is the whole reachable window (no offset method exists).
	//
	// This goes out WITHOUT repaint's clear-screen prefix, so it scrolls into the
	// client's scrollback; the first repaint then erases only the viewport (ED 2
	// leaves scrollback intact) and paints the live frame over it.
	//
	// The seed ends with the current frame, so a few of its last lines can show
	// up both in scrollback and on screen. That overlap is deliberate: trimming
	// by the pane's row count would risk cutting past it and leaving a silent gap
	// in the history, and a repeated line is easier to live with than a lost one.
	if hist, err := c.ReadPaneHistory(pane); err != nil {
		// History is a nicety; a live pane still streams without it.
		log.Error("attach: history read failed", "pane", pane, "err", err)
	} else if len(bytes.TrimSpace(hist)) > 0 {
		if e := conn.Write(ctx, websocket.MessageBinary, crlf(hist)); e != nil {
			return
		}
		log.Info("attach: seeded scrollback", "pane", pane, "bytes", len(hist))
	}

	// Repaint loop: read + repaint on a change (or the fallback tick), then hold
	// off briefly so a burst of events collapses into a bounded repaint rate.
	go func() {
		defer func() { done <- struct{}{} }()
		var last []byte
		fallback := time.NewTicker(paneFallbackInterval)
		defer fallback.Stop()
		poke() // initial paint
		for {
			select {
			case <-ctx.Done():
				return
			case <-dirty:
			case <-fallback.C:
			}
			frame, err := c.ReadPane(pane)
			if err != nil {
				return // pane closed / herdr gone
			}
			if !bytes.Equal(frame, last) {
				last = append(last[:0], frame...)
				if e := conn.Write(ctx, websocket.MessageBinary, repaint(frame)); e != nil {
					return
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(paneCoalesce):
			}
		}
	}()

	<-done
	cancel()
	log.Info("attach: closed", "pane", pane)
	conn.Close(websocket.StatusNormalClosure, "")
}

// applyResize parses a {"type":"resize","cols":C,"rows":R} control frame and
// resizes the PTY so the agent's TUI redraws for the client's real viewport.
// Malformed or out-of-range frames are ignored rather than fatal.
func applyResize(ptmx *os.File, data []byte, pane string) {
	var msg struct {
		Type string `json:"type"`
		Cols int    `json:"cols"`
		Rows int    `json:"rows"`
	}
	if err := json.Unmarshal(data, &msg); err != nil || msg.Type != "resize" {
		return
	}
	if msg.Cols <= 0 || msg.Rows <= 0 || msg.Cols > 1000 || msg.Rows > 1000 {
		return
	}
	if err := pty.Setsize(ptmx, &pty.Winsize{Rows: uint16(msg.Rows), Cols: uint16(msg.Cols)}); err != nil {
		log.Error("attach: resize failed", "pane", pane, "err", err)
	}
}

// repaint frames a full-screen redraw for the terminal emulator: cursor home +
// erase display, then the pane's rows with CRLF line endings so each row lands
// at column 0 regardless of the emulator's newline mode.
func repaint(frame []byte) []byte {
	frame = crlf(frame)
	out := make([]byte, 0, len(frame)+8)
	out = append(out, "\x1b[H\x1b[2J"...) // cursor home, erase entire display
	return append(out, frame...)
}

// crlf gives every row a CRLF ending so it lands at column 0 regardless of the
// emulator's newline mode. Idempotent: an already-CRLF stream is unchanged.
func crlf(frame []byte) []byte {
	frame = bytes.ReplaceAll(frame, []byte("\r\n"), []byte("\n"))
	return bytes.ReplaceAll(frame, []byte("\n"), []byte("\r\n"))
}
