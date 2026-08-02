package herdr

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"
)

// Herdr's control socket speaks newline-delimited JSON (reverse-engineered
// against herdr 0.7.5, protocol 17; see CONTRACT.md). A request is one JSON
// object per line with an `id`, a `method`, and `params`. The server replies
// with one JSON line: {"id","result":…} or {"id","error":…}. For
// `events.subscribe` the reply is {"id","result":{"type":"subscription_started"}},
// after which the SAME connection becomes a one-way stream of
// {"event":<kind>,"data":{…}} lines until the connection closes. A second
// request on a subscribed connection is ignored, so the full subscription set
// must be sent in the one events.subscribe call.

// Subscription is one entry in an events.subscribe request. Type is the dotted
// Herdr subscription kind (e.g. "pane.created", "pane.agent_status_changed").
// PaneID targets a single pane and is required by the per-pane kinds
// (pane.agent_status_changed, pane.output_matched, pane.scroll_changed); it is
// omitted for the global structural kinds.
type Subscription struct {
	Type   string `json:"type"`
	PaneID string `json:"pane_id,omitempty"`
}

type socketRequest struct {
	ID     string `json:"id"`
	Method string `json:"method"`
	Params any    `json:"params"`
}

// SocketMessage is one decoded line from the event stream. For an event line
// Event is the kind (underscore for global EventKinds like "pane_created", or
// dotted for targeted subscription events like "pane.agent_status_changed") and
// Data is its payload object. Ack/error lines carry ID and Result/Error instead.
type SocketMessage struct {
	Event  string          `json:"event"`
	Data   json.RawMessage `json:"data"`
	ID     string          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
}

// SocketConn is a live connection to the Herdr control socket.
type SocketConn struct {
	conn net.Conn
	r    *bufio.Reader
}

// DialSocket opens a connection to the Herdr control socket at path.
func DialSocket(path string) (*SocketConn, error) {
	c, err := net.DialTimeout("unix", path, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("dial herdr socket %s: %w", path, err)
	}
	// A generous read buffer: layout_updated payloads can be large.
	return &SocketConn{conn: c, r: bufio.NewReaderSize(c, 1<<20)}, nil
}

// Subscribe sends one events.subscribe request for subs and waits for the
// subscription_started acknowledgement. After it returns nil the connection is a
// pure event stream; call ReadMessage in a loop.
func (s *SocketConn) Subscribe(subs []Subscription) error {
	req := socketRequest{
		ID:     "gothalo-events",
		Method: "events.subscribe",
		Params: map[string]any{"subscriptions": subs},
	}
	line, err := json.Marshal(req)
	if err != nil {
		return err
	}
	if _, err := s.conn.Write(append(line, '\n')); err != nil {
		return fmt.Errorf("write subscribe: %w", err)
	}
	// Read lines until our ack arrives (events could in theory interleave, though
	// in practice the ack is first).
	for {
		msg, err := s.ReadMessage()
		if err != nil {
			return err
		}
		if msg.Event != "" {
			// An event before the ack — ignore; the ingester re-reads the stream.
			continue
		}
		if msg.ID != req.ID {
			continue
		}
		if len(msg.Error) > 0 {
			return fmt.Errorf("herdr rejected subscribe: %s", msg.Error)
		}
		return nil
	}
}

// ReadMessage reads and decodes the next newline-delimited JSON message. It
// blocks until a full line is available or the connection errors/closes.
func (s *SocketConn) ReadMessage() (SocketMessage, error) {
	line, err := s.r.ReadBytes('\n')
	if err != nil {
		return SocketMessage{}, err
	}
	var msg SocketMessage
	if err := json.Unmarshal(line, &msg); err != nil {
		return SocketMessage{}, fmt.Errorf("decode socket message: %w", err)
	}
	return msg, nil
}

// Close closes the underlying connection.
func (s *SocketConn) Close() error { return s.conn.Close() }

type serverStatus struct {
	Socket string `json:"socket"`
}

// ServerSocketPath resolves the Herdr control-socket path without hardcoding a
// user path: HERDR_SOCK wins if set, otherwise it asks the running server via
// `herdr status server --json` (the authoritative source, which prints the
// active `socket`).
func (c *Client) ServerSocketPath() (string, error) {
	if v := os.Getenv("HERDR_SOCK"); v != "" {
		return v, nil
	}
	out, err := c.run("status", "server", "--json")
	if err != nil {
		return "", err
	}
	var st serverStatus
	if err := json.Unmarshal(out, &st); err != nil {
		return "", fmt.Errorf("parse herdr status: %w", err)
	}
	if st.Socket == "" {
		return "", fmt.Errorf("herdr status reported no socket path")
	}
	return st.Socket, nil
}
