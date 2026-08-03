package server

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"time"

	"github.com/charmbracelet/log"
	"github.com/coder/websocket"
	"github.com/creack/pty"

	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// paneReadInterval is how often a non-agent pane is re-read and repainted.
const paneReadInterval = 200 * time.Millisecond

// GET /attach?pane=<pane_id>&token=<...> — upgraded to a WebSocket that streams
// a live terminal for ANY pane (agent, shell, dev-server, logs…). It bridges:
//
//	terminal bytes ──▶ WS  (binary frames the client renders)
//	WS             ──▶ terminal stdin  (keystrokes/control bytes the client sends)
//
// Two backends, chosen by pane kind, behind one unchanged WS contract:
//
//   - Agent panes keep the high-fidelity path: `herdr agent attach <pane>` under
//     a PTY, copied byte-for-byte both ways (identical to before).
//   - Plain panes have no agent to attach, so the bridge polls
//     `herdr pane read` and repaints the socket, and forwards inbound bytes to
//     `herdr pane send-text` (which passes raw bytes — Enter, arrows, Ctrl-C —
//     straight to the pane's PTY).
//
// Clients MUST send binary frames (raw terminal bytes — the accessory key row
// writes control bytes straight into this stream, D6); a non-binary frame tears
// the connection down. The backend process/poller is stopped when the WS closes.
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

	if info.IsAgent() {
		attachAgentPTY(conn, c, bare)
		return
	}
	attachPaneStream(conn, c, bare)
}

// attachAgentPTY streams an agent pane via `herdr agent attach` under a PTY,
// copying raw bytes both ways. This is the original attach behaviour, unchanged.
func attachAgentPTY(conn *websocket.Conn, c *herdr.Client, pane string) {
	cmd := c.AttachCommand(pane)
	// A sane default geometry; the client re-renders from Herdr's own repaint.
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

	// A background-derived context bounds the net.Conn's lifetime independent of
	// the (hijacked) request context; cancelling it unblocks both copy loops.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	nc := websocket.NetConn(ctx, conn, websocket.MessageBinary)

	log.Info("attach: streaming agent", "pane", pane)

	// Bridge both directions. Whichever side ends first (client disconnects, or
	// the attach process exits) unblocks the other via the deferred teardown.
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(nc, ptmx); done <- struct{}{} }() // pty -> WS
	go func() { _, _ = io.Copy(ptmx, nc); done <- struct{}{} }() // WS -> pty
	<-done

	log.Info("attach: closed", "pane", pane)
	conn.Close(websocket.StatusNormalClosure, "")
}

// attachPaneStream bridges a non-agent pane: it repaints the pane's visible
// frame to the WS on change, and forwards inbound WS bytes to the pane verbatim
// via `herdr pane send-text` (which delivers raw bytes to the pane's PTY, so
// Enter/arrows/Ctrl-C all work). The WS contract is identical to the agent
// path — binary frames of raw terminal bytes in both directions.
func attachPaneStream(conn *websocket.Conn, c *herdr.Client, pane string) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	nc := websocket.NetConn(ctx, conn, websocket.MessageBinary)

	log.Info("attach: streaming pane", "pane", pane)

	done := make(chan struct{}, 2)

	// WS -> pane: raw keystrokes/control bytes forwarded to the pane's PTY.
	go func() {
		defer func() { done <- struct{}{} }()
		buf := make([]byte, 4096)
		for {
			n, err := nc.Read(buf)
			if n > 0 {
				if e := c.Send(pane, string(buf[:n])); e != nil {
					log.Error("attach: send-text failed", "pane", pane, "err", e)
				}
			}
			if err != nil {
				return
			}
		}
	}()

	// pane -> WS: poll the visible frame; on change, repaint (home + clear +
	// frame). Repainting only on change keeps an idle pane flicker-free.
	go func() {
		defer func() { done <- struct{}{} }()
		var last []byte
		ticker := time.NewTicker(paneReadInterval)
		defer ticker.Stop()
		for {
			frame, err := c.ReadPane(pane)
			if err != nil {
				return // pane closed / herdr gone
			}
			if !bytes.Equal(frame, last) {
				last = append(last[:0], frame...)
				if _, e := nc.Write(repaint(frame)); e != nil {
					return
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()

	<-done
	cancel()
	log.Info("attach: closed", "pane", pane)
	conn.Close(websocket.StatusNormalClosure, "")
}

// repaint frames a full-screen redraw for the terminal emulator: cursor home +
// erase display, then the pane's rows with CRLF line endings so each row lands
// at column 0 regardless of the emulator's newline mode.
func repaint(frame []byte) []byte {
	frame = bytes.ReplaceAll(frame, []byte("\r\n"), []byte("\n"))
	frame = bytes.ReplaceAll(frame, []byte("\n"), []byte("\r\n"))
	out := make([]byte, 0, len(frame)+8)
	out = append(out, "\x1b[H\x1b[2J"...) // cursor home, erase entire display
	return append(out, frame...)
}
