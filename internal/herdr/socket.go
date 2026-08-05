package herdr

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"sync/atomic"
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

// reqSeq mints a monotonically increasing suffix so concurrent Request calls
// (the app may fire several at once) never collide on a correlation id.
var reqSeq atomic.Uint64

// requestTimeout bounds a single request/response round-trip on the dedicated
// connection. Herdr's control ops are local and fast; this is a safety net so a
// wedged socket surfaces as a 502 instead of hanging the HTTP handler.
const requestTimeout = 15 * time.Second

// SocketError is a structured error returned by the socket when Herdr rejects a
// request ({"id","error":{"code","message"}}). The code (e.g. "pane_not_found")
// lets callers map to an HTTP status; Raw preserves the original object so the
// proxy can pass Herdr's error through verbatim.
type SocketError struct {
	Code    string
	Message string
	Raw     json.RawMessage
}

func (e *SocketError) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("herdr: %s: %s", e.Code, e.Message)
	}
	return fmt.Sprintf("herdr: %s", e.Code)
}

// Request performs one id-correlated request/response round-trip against the
// Herdr control socket over a dedicated short-lived connection — deliberately
// NOT the event ingester's long-lived subscription connection, which is a
// one-way stream after subscribe. It resolves the socket path, dials, sends
// {id,method,params}, and returns the raw `result` for the matching id (or a
// *SocketError when Herdr replies with an error). params may be any
// JSON-marshalable value, including a json.RawMessage passed straight through
// from an HTTP body. Safe for concurrent use: each call gets its own connection
// and a unique id.
func (c *Client) Request(method string, params any) (json.RawMessage, error) {
	return c.RequestFor(requestTimeout, method, params)
}

// RequestFor is Request under an explicit deadline, for calls that legitimately
// block. `agent.wait` parks until the agent transitions — up to its own
// timeout_ms — so the default 15s would abort a perfectly healthy wait.
func (c *Client) RequestFor(d time.Duration, method string, params any) (json.RawMessage, error) {
	path, err := c.socketPath()
	if err != nil {
		return nil, err
	}
	conn, err := DialSocket(path)
	if err != nil {
		// A stale memoised path (Herdr restarted onto a new socket) looks exactly
		// like this. Drop it so the next call re-resolves instead of failing
		// forever against a socket that no longer exists.
		c.forgetSocketPath(path)
		return nil, err
	}
	defer conn.Close()
	return conn.DoFor(d, method, params)
}

// socketPath returns the memoised control-socket path, resolving it once.
func (c *Client) socketPath() (string, error) {
	c.sockMu.Lock()
	cached := c.sockPath
	c.sockMu.Unlock()
	if cached != "" {
		return cached, nil
	}

	// Resolved outside the lock: it shells out, and holding a mutex across an
	// exec would serialise every caller behind the slowest one.
	path, err := c.ServerSocketPath()
	if err != nil {
		return "", err
	}
	c.sockMu.Lock()
	if c.sockPath == "" {
		c.sockPath = path
	}
	path = c.sockPath
	c.sockMu.Unlock()
	return path, nil
}

// forgetSocketPath clears the memo if it still holds stale, so a concurrent
// caller that already re-resolved isn't undone.
func (c *Client) forgetSocketPath(stale string) {
	c.sockMu.Lock()
	if c.sockPath == stale {
		c.sockPath = ""
	}
	c.sockMu.Unlock()
}

// Do sends one request on this connection and reads back the response whose id
// matches. It is used by Request on a fresh connection; any interleaved event
// lines (there should be none without a subscription) are skipped. A read/write
// deadline bounds the round-trip.
func (s *SocketConn) Do(method string, params any) (json.RawMessage, error) {
	return s.DoFor(requestTimeout, method, params)
}

// DoFor is Do under an explicit deadline. See [Client.RequestFor].
func (s *SocketConn) DoFor(d time.Duration, method string, params any) (json.RawMessage, error) {
	id := fmt.Sprintf("gothalo-req-%d", reqSeq.Add(1))
	req := socketRequest{ID: id, Method: method, Params: params}
	line, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}
	if err := s.conn.SetDeadline(time.Now().Add(d)); err != nil {
		return nil, err
	}
	if _, err := s.conn.Write(append(line, '\n')); err != nil {
		return nil, fmt.Errorf("write request: %w", err)
	}
	for {
		msg, err := s.ReadMessage()
		if err != nil {
			return nil, fmt.Errorf("read response: %w", err)
		}
		if msg.Event != "" || msg.ID != id {
			continue // an event or a stray id — not our reply
		}
		if len(msg.Error) > 0 {
			serr := &SocketError{Raw: msg.Error}
			var body struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			}
			if json.Unmarshal(msg.Error, &body) == nil {
				serr.Code, serr.Message = body.Code, body.Message
			}
			return nil, serr
		}
		return msg.Result, nil
	}
}

type serverStatus struct {
	Socket string `json:"socket"`
}

// ServerSocketPath resolves the Herdr control-socket path without hardcoding a
// user path: HERDR_SOCK wins if set, otherwise it asks the running server via
// `herdr status server --json` (the authoritative source, which prints the
// active `socket`).
func (c *Client) ServerSocketPath() (string, error) {
	// HERDR_SOCK overrides only the default session; named sessions always
	// resolve their own socket.
	if v := os.Getenv("HERDR_SOCK"); v != "" && c.session == "" {
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
