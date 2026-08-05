package server

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/charmbracelet/log"
	"github.com/coder/websocket"

	"github.com/dipeshdulal/gothalo/internal/events"
)

// eventsBufferSize bounds how many envelopes a single WS client may fall behind
// before the bus drops it. The bus is coarse and low-volume, so a few hundred is
// generous; a client that still can't keep up is closed with resyncCloseCode and
// expected to reconnect + re-snapshot.
const eventsBufferSize = 256

// eventsWriteTimeout bounds a single frame write so one stuck client can't wedge
// its own stream (the bus already protects other clients via the bounded buffer).
const eventsWriteTimeout = 10 * time.Second

// eventsPingInterval is how often an idle connection is pinged. It has to be
// short enough that a client notices a dead socket in seconds rather than
// whenever the next agent happens to change state — which on a quiet tailnet
// can be never. It also keeps NAT/proxy idle timers from reaping the connection
// underneath us.
const eventsPingInterval = 20 * time.Second

// resyncCloseCode is the WS close code sent when a client is dropped for lagging
// (or the Herdr side is being torn down): reconnect and re-snapshot. 4000 is in
// the private-use range so it can't collide with a protocol code.
const resyncCloseCode = websocket.StatusCode(4000)

// snapshotFrame is the first frame every /events client receives: the current
// /snapshot payload (for a full resync) plus the bus seq it is consistent with.
// Subsequent frames are events.Envelope deltas with seq strictly greater than
// this one. A client that sees a gap in seq re-connects (re-snapshots).
type snapshotFrame struct {
	Type     string          `json:"type"` // always "snapshot"
	Source   string          `json:"source"`
	Seq      uint64          `json:"seq"`
	TS       int64           `json:"ts"`
	Snapshot json.RawMessage `json:"snapshot"` // identical JSON to GET /snapshot
}

// heartbeatFrame is the periodic "still here" frame. It has no seq on purpose:
// clients treat a seq-bearing frame as a change signal and re-snapshot, and a
// heartbeat means nothing changed. Clients that don't recognise the type can
// ignore it — receiving it at all is the point.
type heartbeatFrame struct {
	Type string `json:"type"` // always "heartbeat"
	TS   int64  `json:"ts"`
}

// GET /events?token=<bearer> — upgraded to a WebSocket carrying the unified
// gothalo event stream (Herdr events normalized as herdr.*, plus gothalo.* system
// events). The framing is text JSON:
//
//   - one snapshot frame on connect ({"type":"snapshot", seq, snapshot}),
//   - then a stream of envelope deltas ({source,type,seq,ts,payload}).
//
// This is the push replacement for the app's per-action /snapshot refetch: the
// app seeds its store from the snapshot frame and applies deltas thereafter,
// re-snapshotting on a seq gap, a gothalo.herdr_resync, or a socket close.
//
// One process-wide Herdr subscription feeds the bus; every /events client is just
// another bus subscriber, so clients never open their own Herdr connections. Auth
// is the same authorize() path as /attach, accepting ?token= for WS clients.
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authorize(r); !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.bus == nil {
		http.Error(w, "event bus not enabled", http.StatusServiceUnavailable)
		return
	}

	// Auth is by token, not Origin (a phone connects cross-origin), so origin
	// verification is disabled — same rationale as /attach.
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		log.Error("events: ws accept failed", "err", err)
		return
	}
	defer conn.CloseNow()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Subscribe BEFORE snapshotting so no event that occurs during the snapshot
	// fetch is lost: such events queue in the sub and are delivered after the
	// snapshot frame (their seq > baseline, so the client applies them cleanly).
	sub := s.bus.Subscribe(eventsBufferSize)
	defer sub.Close()
	baseline := s.bus.CurrentSeq()

	// A reader goroutine turns a client disconnect (or any inbound frame) into a
	// ctx cancel; /events is server->client only, so inbound data just ends it.
	go func() {
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				cancel()
				return
			}
		}
	}()

	if err := s.writeSnapshot(ctx, conn, baseline); err != nil {
		log.Error("events: snapshot write failed", "err", err)
		return
	}
	log.Info("events: client attached", "baseline_seq", baseline, "subscribers", s.bus.SubscriberCount())

	// Heartbeat. A quiet tailnet can go many minutes without an event, and a
	// connection that dies in a way neither side observes — the bridge killed
	// behind `tailscale serve`, a phone's radio sleeping, a NAT entry expiring —
	// leaves a HALF-OPEN socket: the client's stream never ends, so it never
	// reconnects and silently serves stale state forever. Regular pings give both
	// ends traffic to fail on, which is what turns a dead socket into a
	// detectable one.
	ticker := time.NewTicker(eventsPingInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Info("events: client detached")
			conn.Close(websocket.StatusNormalClosure, "")
			return
		case <-ticker.C:
			// An application-level frame, not just a protocol ping. A WS ping is
			// answered by the client's networking stack and never surfaces to app
			// code, so it cannot drive a client-side liveness check — and in a
			// half-open socket the client is exactly the side that learns nothing.
			// A real frame the client can observe is what lets it time out and
			// reconnect. Deliberately carries no seq: it means "still here", not
			// "something changed", so it must not trigger a re-snapshot.
			if err := writeJSONFrame(ctx, conn, heartbeatFrame{
				Type: "heartbeat",
				TS:   time.Now().UnixMilli(),
			}); err != nil {
				log.Info("events: client unreachable, closing", "err", err)
				return
			}
		case env, ok := <-sub.C():
			if !ok {
				// Dropped for lagging: tell the client to reconnect + re-snapshot.
				log.Warn("events: client dropped (lagging)")
				conn.Close(resyncCloseCode, "resync: subscriber lagged")
				return
			}
			if err := writeJSONFrame(ctx, conn, env); err != nil {
				return
			}
		}
	}
}

// writeSnapshot sends the initial snapshot frame. A herdr failure is fatal to the
// connection (there is nothing to seed the client with).
func (s *Server) writeSnapshot(ctx context.Context, conn *websocket.Conn, baseline uint64) error {
	raw, err := s.sessions.MergedSnapshotRaw()
	if err != nil {
		conn.Close(websocket.StatusInternalError, "snapshot failed")
		return err
	}
	return writeJSONFrame(ctx, conn, snapshotFrame{
		Type:     "snapshot",
		Source:   events.SourceGothalo,
		Seq:      baseline,
		TS:       time.Now().UnixMilli(),
		Snapshot: raw,
	})
}

func writeJSONFrame(ctx context.Context, conn *websocket.Conn, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	wctx, cancel := context.WithTimeout(ctx, eventsWriteTimeout)
	defer cancel()
	return conn.Write(wctx, websocket.MessageText, b)
}
