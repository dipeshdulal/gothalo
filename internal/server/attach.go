package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
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

// kindDebounce lets a burst of lifecycle signals settle before re-resolving the
// pane. Starting an agent emits pane.updated, pane.agent_detected and
// pane.agent_status_changed inside the same second, and each one would
// otherwise cost a `pane get`.
const kindDebounce = 150 * time.Millisecond

// inboundBuffer holds client frames while a backend swap is in flight. Frames
// are dropped when it fills rather than blocking the socket reader; the only
// window in which nothing is consuming is the swap itself.
const inboundBuffer = 256

// A hand-typed `claude` gets none of the readiness handshake `herdr agent
// start` performs, so `agent attach` can refuse for a moment after the agent is
// first detected — the process exits immediately instead of streaming. An
// attach that dies inside agentAttachGrace is treated as that race and retried
// up to agentAttachRetries times before falling back to the plain backend.
const (
	agentAttachRetries = 3
	agentAttachGrace   = 1 * time.Second
	agentAttachBackoff = 250 * time.Millisecond
)

// clientFrame is one inbound WebSocket message, routed to whichever backend is
// currently running.
type clientFrame struct {
	typ  websocket.MessageType
	data []byte
}

// socketWriter serializes writes to the WebSocket. Backends hand off to it
// instead of holding the connection, and coder/websocket allows only one
// concurrent writer.
type socketWriter struct {
	mu   sync.Mutex
	ctx  context.Context
	conn *websocket.Conn
}

func (w *socketWriter) write(typ websocket.MessageType, data []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.conn.Write(w.ctx, typ, data)
}

func (w *socketWriter) binary(data []byte) error {
	return w.write(websocket.MessageBinary, data)
}

// mode announces which backend is now streaming, so the client can reset its
// emulator before the new byte stream starts. Without the reset, an alt-screen
// TUI's leftovers corrupt the plain-shell frames that follow it (and vice
// versa).
func (w *socketWriter) mode(agent bool) error {
	msg, err := json.Marshal(map[string]any{"type": "mode", "agent": agent})
	if err != nil {
		return err
	}
	return w.write(websocket.MessageText, msg)
}

// socketIO is the socket-facing half a backend sees. A backend must NEVER read
// or write the WebSocket itself: cancelling the context of an in-flight
// coder/websocket read closes the connection outright (its setupReadTimeout
// registers a context.AfterFunc that calls Conn.close), so a backend owning the
// socket would tear it down on every swap. The supervisor owns the connection
// and hands each backend a channel and a writer instead.
type socketIO struct {
	in <-chan clientFrame
	w  *socketWriter
}

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
// The pane's kind is not fixed for the life of the socket: type `claude` into a
// plain shell and Herdr hosts an agent in it; exit the agent and it is a plain
// shell again. [superviseAttach] follows those transitions, swapping the backend
// underneath the same WebSocket rather than making the client reconnect.
//
// Frame types: **binary** frames are raw terminal bytes (the accessory key row
// writes control bytes straight into this stream, D6). **text** frames are
// out-of-band control messages. Client to bridge:
// `{"type":"resize","cols":C,"rows":R}`, which sizes the PTY so the client's
// line-editing (autocomplete, wrapping) stays aligned with its viewport. Bridge
// to client: `{"type":"mode","agent":bool}`, sent on every backend swap so the
// client can reset its emulator before the new stream arrives. The backend
// process/poller is stopped when the WS closes.
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

	superviseAttach(conn, c, bare, info.IsAgent())
}

// superviseAttach owns the WebSocket and runs whichever backend matches the
// pane's current kind, swapping between them as agents come and go.
//
// Herdr's lifecycle signals are not directional — pane.agent_detected fires on
// BOTH an agent appearing and one exiting, and the pane.updated that trails an
// exit still carries the departed agent — so nothing here trusts an event's
// payload. Every signal means "re-resolve", and `pane get` decides.
//
// The watcher is the ONLY thing that reports an agent leaving. `herdr agent
// attach` does not exit when its agent does — it stays attached and happily
// streams the shell that is left behind (measured), so waiting for the backend
// to end would wait forever. A backend ending by itself means something else
// entirely: the client went away, or the pane closed. Re-resolving tells those
// apart from a kind change.
func superviseAttach(conn *websocket.Conn, c *herdr.Client, pane string, agent bool) {
	// Bounds the socket's lifetime independent of the (hijacked) request
	// context. It outlives every backend: cancelling it closes the connection.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	w := &socketWriter{ctx: ctx, conn: conn}

	// One reader for the whole socket, feeding whichever backend is running.
	in := make(chan clientFrame, inboundBuffer)
	go func() {
		defer cancel() // the client is gone; unblock the supervisor and backend
		for {
			typ, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			select {
			case in <- clientFrame{typ: typ, data: data}:
			case <-ctx.Done():
				return
			default:
				// Buffer full: no backend is consuming, which happens only
				// during a swap. Losing a keystroke there beats stalling the
				// reader (and with it the close handshake).
			}
		}
	}()

	sio := socketIO{in: in, w: w}
	changed := watchPaneKind(ctx, c, pane)

	for {
		bctx, bcancel := context.WithCancel(ctx)
		done := make(chan struct{})
		go func(agent bool) {
			defer close(done)
			if agent {
				runAgentPTY(bctx, sio, c, pane)
			} else {
				runPaneStream(bctx, sio, c, pane)
			}
		}(agent)

		next := agent
	wait:
		for {
			select {
			case <-done:
				bcancel()
				if ctx.Err() != nil {
					conn.Close(websocket.StatusNormalClosure, "")
					return
				}
				info, err := c.GetPane(pane)
				if err != nil || info.IsAgent() == agent {
					// The pane is gone, or it is unchanged and the backend
					// stopped for its own reasons. Either way this attach ends.
					conn.Close(websocket.StatusNormalClosure, "")
					return
				}
				next = info.IsAgent()
				break wait
			case n, ok := <-changed:
				if !ok {
					// The watcher's Herdr socket died. Keep streaming what we
					// have; a nil channel blocks forever in this select.
					changed = nil
					continue
				}
				if n == agent {
					continue // a signal that resolved to no change
				}
				next = n
				bcancel()
				<-done
				break wait
			}
		}
		bcancel()

		if ctx.Err() != nil {
			return
		}
		agent = next
		log.Info("attach: kind changed, swapping backend", "pane", pane, "agent", agent)
		if err := w.mode(agent); err != nil {
			return
		}
	}
}

// watchPaneKind reports the pane's kind each time a Herdr lifecycle signal
// settles. It emits the freshly resolved value rather than a transition, so a
// signal that turns out to mean nothing is the caller's to ignore — which keeps
// this free of any state that could drift from the supervisor's.
//
// pane.agent_detected is global (it is how a client learns about an agent that
// appeared after connecting); pane.agent_status_changed is per-pane and is what
// actually reports the agent leaving, as `agent:""` with status `unknown`.
func watchPaneKind(ctx context.Context, c *herdr.Client, pane string) <-chan bool {
	out := make(chan bool)
	go func() {
		defer close(out)
		path, err := c.ServerSocketPath()
		if err != nil {
			return
		}
		sub, err := herdr.DialSocket(path)
		if err != nil {
			log.Error("attach: kind subscribe dial failed", "pane", pane, "err", err)
			return
		}
		defer sub.Close()
		go func() { <-ctx.Done(); sub.Close() }()
		if err := sub.Subscribe([]herdr.Subscription{
			{Type: "pane.agent_detected"},
			{Type: "pane.agent_status_changed", PaneID: pane},
		}); err != nil {
			log.Error("attach: kind subscribe failed", "pane", pane, "err", err)
			return
		}

		// resolved is the last kind this watcher established. It is a cache for
		// skipping work, never an authority: every value sent downstream comes
		// from a fresh `pane get`.
		var resolved atomic.Bool
		if info, err := c.GetPane(pane); err == nil {
			resolved.Store(info.IsAgent())
		}

		poke := make(chan struct{}, 1)
		go func() {
			for {
				msg, err := sub.ReadMessage()
				if err != nil {
					close(poke)
					return
				}
				if msg.Event == "" || !mentionsPane(msg.Data, pane) {
					continue
				}
				// pane.agent_status_changed fires on every idle→working→blocked
				// transition, which for an attached agent is constant churn —
				// and each re-resolve is a `pane get` subprocess. A payload
				// naming a non-empty agent is proof an agent is present (herdr
				// does not invent a name), so when that agrees with what we
				// already resolved there is nothing to check. Every other
				// shape, including the empty-agent departure signal, falls
				// through to a real re-resolve.
				if resolved.Load() && namesAgent(msg.Data) {
					continue
				}
				select {
				case poke <- struct{}{}:
				default: // one pending re-resolve already covers this burst
				}
			}
		}()

		for {
			select {
			case <-ctx.Done():
				return
			case _, ok := <-poke:
				if !ok {
					return
				}
			}
			// Let the rest of the burst land before asking Herdr.
			select {
			case <-ctx.Done():
				return
			case <-time.After(kindDebounce):
			}
			info, err := c.GetPane(pane)
			if err != nil {
				continue // a transient lookup failure is not a kind change
			}
			resolved.Store(info.IsAgent())
			select {
			case out <- info.IsAgent():
			case <-ctx.Done():
				return
			}
		}
	}()
	return out
}

// mentionsPane reports whether a Herdr event payload concerns this pane. The
// pane id sits at the top level on the agent events and under "pane" on the
// structural ones.
func mentionsPane(data json.RawMessage, pane string) bool {
	var d struct {
		PaneID string `json:"pane_id"`
		Pane   struct {
			PaneID string `json:"pane_id"`
		} `json:"pane"`
	}
	if json.Unmarshal(data, &d) != nil {
		return false
	}
	return d.PaneID == pane || d.Pane.PaneID == pane
}

// namesAgent reports whether a Herdr event payload names a hosted agent. A
// non-empty name is positive proof one is present; an empty or absent one
// proves nothing either way (pane.updated keeps reporting a departed agent, and
// the departure signal carries `agent:""`), so only the positive case is
// actionable — see its use in [watchPaneKind].
func namesAgent(data json.RawMessage) bool {
	var d struct {
		Agent string `json:"agent"`
		Pane  struct {
			Agent string `json:"agent"`
		} `json:"pane"`
	}
	if json.Unmarshal(data, &d) != nil {
		return false
	}
	return d.Agent != "" || d.Pane.Agent != ""
}

// runAgentPTY streams an agent pane via `herdr agent attach` under a PTY,
// retrying briefly when the attach dies on arrival — see [agentAttachGrace].
// Returning hands control back to the supervisor, which decides whether the
// socket ends or swaps to the plain backend.
func runAgentPTY(ctx context.Context, sio socketIO, c *herdr.Client, pane string) {
	for attempt := 0; ; attempt++ {
		start := time.Now()
		agentPTYOnce(ctx, sio, c, pane)
		if ctx.Err() != nil || attempt >= agentAttachRetries-1 {
			return
		}
		if time.Since(start) >= agentAttachGrace {
			return // it streamed for a while, so this is a real exit
		}
		info, err := c.GetPane(pane)
		if err != nil || !info.IsAgent() {
			return // the agent really is gone; let the supervisor re-resolve
		}
		log.Info("attach: agent attach died on arrival, retrying", "pane", pane, "attempt", attempt+1)
		select {
		case <-ctx.Done():
			return
		case <-time.After(agentAttachBackoff):
		}
	}
}

// agentPTYOnce runs one `herdr agent attach` to completion, bridging raw bytes
// both ways. Binary frames from the client are stdin; text frames are control
// messages (resize), applied with pty.Setsize.
func agentPTYOnce(ctx context.Context, sio socketIO, c *herdr.Client, pane string) {
	cmd := c.AttachCommand(pane)
	// A sane default geometry; the client sends its real size on connect (and on
	// every later resize) as a text control frame, which we apply below.
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 24, Cols: 80})
	if err != nil {
		log.Error("attach: pty start failed", "pane", pane, "err", err)
		return
	}
	defer func() {
		_ = ptmx.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	// Bounded by the backend's context: the supervisor cancels it to swap
	// backends, and it is cancelled with the socket when the client goes away.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		<-ctx.Done()
		// Kill BEFORE closing: on darwin, closing a PTY master does not
		// interrupt a goroutine already blocked reading it, so a swap would
		// hang forever waiting for that read to return (measured — the reader
		// sat in IO wait while the supervisor waited on it). Killing the attach
		// process ends the read with EIO, which is what actually unblocks it.
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = ptmx.Close()
	}()

	log.Info("attach: streaming agent", "pane", pane)

	// Bridge both directions. Whichever side ends first (client disconnects, the
	// attach process exits, or the supervisor swaps us out) unblocks the other
	// via the deferred teardown. wg is what makes the swap safe: this function
	// must not return while a goroutine of its own could still write to the
	// shared socket, or a stale frame would land in the next backend's stream.
	var wg sync.WaitGroup
	wg.Add(2)
	done := make(chan struct{}, 2)
	// pty -> WS: raw terminal bytes as binary frames.
	go func() {
		defer wg.Done()
		defer func() { done <- struct{}{} }()
		buf := make([]byte, 32*1024)
		for {
			n, rerr := ptmx.Read(buf)
			if n > 0 {
				if werr := sio.w.binary(buf[:n]); werr != nil {
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
		defer wg.Done()
		defer func() { done <- struct{}{} }()
		for {
			var f clientFrame
			select {
			case <-ctx.Done():
				return
			case f = <-sio.in:
			}
			if f.typ == websocket.MessageText {
				applyResize(ptmx, f.data, pane)
				continue
			}
			if _, werr := ptmx.Write(f.data); werr != nil {
				return
			}
		}
	}()
	select {
	case <-done:
	case <-ctx.Done():
	}
	cancel()
	wg.Wait()

	log.Info("attach: agent stream ended", "pane", pane)
}

// attachPaneStream bridges a non-agent pane. Herdr exposes no live stream for a
// plain pane, so we mirror it: forward inbound binary frames to the pane via
// send-text, and repaint the visible frame to the client. Rather than poll on a
// fixed tick, we subscribe to Herdr's pane.updated event for THIS pane and
// repaint on change (coalesced), with a slow fallback read as a safety net — so
// interactive redraws (autocomplete, history recall) track near-live instead of
// being sampled a few times a second. Text frames (resize) are swallowed —
// Herdr owns a plain pane's geometry.
func runPaneStream(ctx context.Context, sio socketIO, c *herdr.Client, pane string) {
	ctx, cancel := context.WithCancel(ctx)

	log.Info("attach: streaming pane", "pane", pane)

	// wg is what makes the swap safe: this function must not return while a
	// goroutine of its own could still write to the shared socket, or a stale
	// repaint would land in the next backend's stream. The defers run
	// bottom-up, so cancel() lands before Wait() and nothing deadlocks — and
	// the early return on a failed seed write is covered too.
	var wg sync.WaitGroup
	defer wg.Wait()
	defer cancel()
	wg.Add(3)
	done := make(chan struct{}, 3)

	// WS -> pane: binary frames are raw keystrokes; text frames are control
	// messages we ignore for a plain pane (so the JSON never reaches the shell).
	go func() {
		defer wg.Done()
		defer func() { done <- struct{}{} }()
		for {
			var f clientFrame
			select {
			case <-ctx.Done():
				return
			case f = <-sio.in:
			}
			if f.typ == websocket.MessageText {
				continue
			}
			// send-text types text and drops control sequences, so keys are
			// split out and pressed via send-keys — see splitPaneInput.
			for _, chunk := range splitPaneInput(string(f.data)) {
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
		defer wg.Done()
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
		if e := sio.w.binary(crlf(hist)); e != nil {
			return
		}
		log.Info("attach: seeded scrollback", "pane", pane, "bytes", len(hist))
	}

	// Repaint loop: read + repaint on a change (or the fallback tick), then hold
	// off briefly so a burst of events collapses into a bounded repaint rate.
	go func() {
		defer wg.Done()
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
				if e := sio.w.binary(repaint(frame)); e != nil {
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

	select {
	case <-done:
	case <-ctx.Done():
	}
	log.Info("attach: pane stream ended", "pane", pane)
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
