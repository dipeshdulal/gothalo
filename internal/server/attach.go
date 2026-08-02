package server

import (
	"context"
	"io"
	"net/http"

	"github.com/charmbracelet/log"
	"github.com/coder/websocket"
	"github.com/creack/pty"
)

// GET /attach?pane=<pane_id>&token=<...> — upgraded to a WebSocket that streams
// a live terminal. It runs `herdr agent attach <pane>` under a PTY and bridges:
//
//	pty stdout ──▶ WS  (binary frames the client renders)
//	WS         ──▶ pty stdin  (keystrokes/control bytes the client sends)
//
// Clients MUST send binary frames (raw terminal bytes — the accessory key row
// writes control bytes straight into this stream, D6); a non-binary frame tears
// the connection down. The subprocess is killed when the WebSocket closes.
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

	// Auth is by bearer/token, not Origin, so origin verification is disabled;
	// a phone connects cross-origin and can't forge a valid token.
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		log.Error("attach: ws accept failed", "pane", pane, "err", err)
		return
	}
	defer conn.CloseNow()

	cmd := s.herdr.AttachCommand(pane)
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

	log.Info("attach: streaming", "pane", pane)

	// Bridge both directions. Whichever side ends first (client disconnects, or
	// the attach process exits) unblocks the other via the deferred teardown.
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(nc, ptmx); done <- struct{}{} }() // pty -> WS
	go func() { _, _ = io.Copy(ptmx, nc); done <- struct{}{} }() // WS -> pty
	<-done

	log.Info("attach: closed", "pane", pane)
	conn.Close(websocket.StatusNormalClosure, "")
}
