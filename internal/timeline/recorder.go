package timeline

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/events"
)

// recorderBuffer bounds how far the consumer may fall behind the bus before it
// is dropped and re-subscribes. Same reasoning as the notification-clearer's:
// the bus is coarse and low-volume, so a few hundred is generous.
const recorderBuffer = 256

// flushInterval is how often a changed ring is written to disk. It is the window
// of history a hard kill can cost — a few seconds of transitions, against
// rewriting the whole file on every flip of a busy agent. See [Log.dirty].
const flushInterval = 5 * time.Second

// PaneState is one agent pane's current status, as an authoritative read reports
// it. Ids are session-qualified, exactly as they appear on the bus and in every
// endpoint, so the recorder's keys line up with the ones its entries carry.
type PaneState struct {
	Pane      string
	Agent     string
	Session   string
	Workspace string
	Status    string
	// Title is the pane's human name. It comes from the authoritative read rather
	// than the bus, because most of the signals a status change is scavenged from
	// do not carry one — and a row that cannot name its work is unreadable on a
	// host running several agents of the same kind.
	Title string
}

// stateReader is an authoritative read of every agent pane's current status.
//
// It exists for exactly one job: rebuilding open spans after a gap in
// observation (see [Recorder.reconcile]). The bus cannot do that — it is a
// change signal, so it says nothing at all about a pane that is sitting still,
// which after a restart is most of them.
type stateReader interface {
	Agents() ([]PaneState, error)
}

// span is a pane's currently-open status interval: what it is in, and since
// when.
type span struct {
	status string
	since  time.Time
	// known distinguishes "this span really started at `since`" from "`since` is
	// just when we started watching". Only a known start can be turned into a
	// duration; an unknown one yields an entry with no prev_ms rather than a
	// plausible-looking lie measured from bridge startup.
	known bool

	// The identifying context, remembered from the transition that opened the
	// span. A pane_closed event carries only a pane id, so without this the entry
	// that closes a span would not know which agent it was about.
	agent     string
	session   string
	workspace string
	title     string
}

// Recorder is the process-wide bus consumer that turns agent status transitions
// into timeline entries. One instance runs for the whole daemon. Its structure
// deliberately mirrors internal/notify.Clearer — subscribe, consume, re-subscribe
// on drop — because it is the same kind of thing: a long-lived observer of the
// unified bus.
//
// Unlike the Clearer, it trusts the bus payload's status. The Clearer must not,
// because it decides whether to retract a notification a user is looking at, and
// a stale read there means an alert vanishing while an agent still waits. Here
// the bus IS the subject: the recorder's job is to log the transitions the bus
// announced, in the order it announced them. Re-reading Herdr per event would
// both cost a socket round-trip per transition and record a different sequence
// of statuses from the one every other client saw.
type Recorder struct {
	log    *Log
	bus    *events.Bus
	agents stateReader // nil disables rehydration (tests)
	now    func() time.Time

	mu sync.Mutex
	// spans maps a session-qualified pane id to its open status interval. This is
	// where the durations come from, and it is the only mutable state the
	// recorder keeps.
	spans map[string]span

	// live is the pane set the last authoritative read saw, and when it was
	// taken. It answers one question — "does this pane still exist?" — for a
	// pane with no open span. See [Recorder.paneExists].
	live   map[string]bool
	liveAt time.Time
}

// liveTTL is how long a pane-existence read is reused before another is taken.
// It gates only FIRST SIGHTINGS of a pane, which are rare in steady state, so a
// short window costs almost nothing while collapsing a replayed burst of dozens
// into a single read.
const liveTTL = 2 * time.Second

// NewRecorder builds a Recorder over the ring, the live bus, and an
// authoritative reader (which may be nil in tests).
func NewRecorder(l *Log, bus *events.Bus, agents stateReader) *Recorder {
	return &Recorder{log: l, bus: bus, agents: agents, now: time.Now, spans: map[string]span{}}
}

// Run rebuilds open spans, then subscribes to the bus and consumes events until
// ctx is cancelled. Call it in its own goroutine. If the subscription is dropped
// for lagging it re-subscribes; the open spans survive across re-subscribes (a
// drop means missed transitions, not a changed present — the next transition per
// pane will simply report a duration spanning the gap).
func (r *Recorder) Run(ctx context.Context) {
	log.Info("timeline-recorder: started", "entries", r.log.Len())
	r.reconcile("startup")
	defer r.flush()
	for {
		if ctx.Err() != nil {
			return
		}
		sub := r.bus.Subscribe(recorderBuffer)
		dropped := r.consume(ctx, sub)
		sub.Close()
		if !dropped || ctx.Err() != nil {
			return
		}
		log.Warn("timeline-recorder: bus subscription dropped, re-subscribing")
	}
}

// consume reads from one subscription until ctx is cancelled or the channel is
// closed, flushing the ring on a timer. It reports whether the channel closed
// because the bus dropped the subscriber (lagging), so Run knows to re-subscribe.
func (r *Recorder) consume(ctx context.Context, sub *events.Sub) (dropped bool) {
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return false
		case <-ticker.C:
			r.flush()
		case env, ok := <-sub.C():
			if !ok {
				return sub.Dropped()
			}
			r.handle(env)
		}
	}
}

// reconcile rebuilds the open spans from an authoritative read, repairing the
// two gaps in observation the bus cannot cover on its own.
//
// **A bridge restart.** The ring is persisted, so the entries survive — but the
// durations do not follow from the entries alone: a span that was already
// running when the bridge stopped has a start time that lived only in memory.
// Without this, the first transition after every restart reports no duration,
// and an agent that has been blocked since before the restart — the single case
// this whole feature exists for — is exactly the one that loses its number.
//
// **A Herdr outage.** The ingester re-seeds its own per-pane status baseline on
// every reconnect, precisely so it does not replay statuses that already held.
// The cost is that a pane which changed status *while the socket was down*
// produces no bus event at all when it comes back. Left alone, this recorder's
// span for that pane would name a status the agent left during the outage, and
// the next real transition would report that stale status as its `from` and a
// duration covering both spans — an entry that is simply wrong.
//
// The rebuild follows the same discipline as the notification-clearer's rearm
// (see internal/notify): ask what is true NOW, and only then decide what the
// stored record means. Per pane Herdr currently reports:
//
//   - we have no span (a restart, or an agent we have never seen). The newest
//     persisted entry decides: if it says the pane entered THIS status at time
//     T, the span is still the one we recorded, so resume it at T and its
//     duration stays honest across the restart. Anything else and the span opens
//     at now, marked UNKNOWN, so its first transition carries no prev_ms rather
//     than a duration measured from bridge startup.
//   - we have a span naming the same status: leave it completely alone. Its
//     start is better information than anything this read can supply.
//   - we have a span naming a DIFFERENT status: a transition happened
//     unobserved. Re-point the span at the truth and mark it UNKNOWN.
//
// **No entry is ever written here**, in any of those cases, and that is
// deliberate. We know a transition happened but not when, and every consumer
// reads an entry's ts as when the agent actually moved — so a row stamped
// "now" would report an agent that has been blocked since before the restart as
// having *just* blocked, inverting the one answer this feature exists to give.
// The record therefore has a hole where the unobserved transition was, and the
// next real entry's `from` names the status the agent genuinely left. A gap in
// the history is honest; a well-formed row with a made-up time is not.
//
// It is safe to call repeatedly: only panes whose span is missing or wrong are
// touched. Panes Herdr no longer reports are deliberately NOT closed — a
// partially reachable multi-session read returns a partial list with no error
// (see the Agents implementation in internal/cli), so "absent" cannot be
// distinguished from "unreadable", and closing on it would fabricate a `gone`
// for every agent on a session that merely hiccuped.
func (r *Recorder) reconcile(reason string) {
	if r.agents == nil {
		return
	}
	states, err := r.agents.Agents()
	if err != nil {
		log.Warn("timeline-recorder: could not rebuild open spans", "reason", reason, "err", err)
		return
	}
	now := r.now()
	var resumed, opened, corrected int
	r.mu.Lock()
	// This read is authoritative and already in hand, so it doubles as the
	// pane-existence cache [Recorder.paneExists] consults.
	live := make(map[string]bool, len(states))
	for _, s := range states {
		if s.Pane != "" {
			live[s.Pane] = true
		}
	}
	r.live, r.liveAt = live, now
	for _, s := range states {
		if s.Pane == "" || s.Status == "" {
			continue
		}
		if cur, open := r.spans[s.Pane]; open {
			if cur.status == s.Status {
				continue
			}
			r.spans[s.Pane] = span{
				status: s.Status, since: now, known: false,
				agent: s.Agent, session: s.Session, workspace: s.Workspace, title: s.Title,
			}
			corrected++
			continue
		}
		sp := span{
			status: s.Status, since: now, known: false,
			agent: s.Agent, session: s.Session, workspace: s.Workspace, title: s.Title,
		}
		if last, ok := r.log.Latest(s.Pane); ok && last.To == s.Status {
			sp.since = time.UnixMilli(last.TS)
			sp.known = true
			resumed++
		}
		r.spans[s.Pane] = sp
		opened++
	}
	r.mu.Unlock()
	if opened == 0 && corrected == 0 {
		return // nothing to say; the common case on a healthy reconnect
	}
	log.Info("timeline-recorder: rebuilt open spans",
		"reason", reason, "panes", len(states),
		"opened", opened, "resumed", resumed, "corrected", corrected)
}

// handle routes one envelope to a recorded transition.
func (r *Recorder) handle(env events.Envelope) {
	// Herdr's socket just (re)connected, so an authoritative read is possible and
	// may be overdue. This is also what makes the startup rebuild reliable at
	// all: `serve` starts this recorder and the Herdr session manager in the same
	// breath, so the read at startup usually finds no sessions yet — this is the
	// event that says "now there is one". See [Recorder.reconcile].
	if env.Source == events.SourceGothalo && env.Type == events.TypeHerdrConnected {
		r.reconcile("herdr connected")
		return
	}

	switch env.Type {
	// The normalized, already-deduplicated agent transition — one per real status
	// change, whichever Herdr signal it was scavenged from (see the ingester).
	case events.TypePaneAgentStatusChanged:
		var p struct {
			PaneID      string `json:"pane_id"`
			WorkspaceID string `json:"workspace_id"`
			Agent       string `json:"agent"`
			AgentStatus string `json:"agent_status"`
			Session     string `json:"session"`
			Title       string `json:"title"`
		}
		if json.Unmarshal(env.Payload, &p) != nil || p.PaneID == "" || p.AgentStatus == "" {
			return
		}
		r.record(p.PaneID, p.Agent, p.Session, p.WorkspaceID, p.AgentStatus, p.Title, env.TS)

	// The pane is gone. Recorded as a transition to StatusGone so the open span
	// is closed with a real duration ("worked for 40m, then finished and the pane
	// closed") instead of being abandoned mid-flight. Both sources are accepted:
	// herdr's own close/exit, and gothalo's POST /pane/close.
	case events.TypePaneClosed, events.TypePaneExited:
		var p struct {
			PaneID string `json:"pane_id"`
		}
		if json.Unmarshal(env.Payload, &p) != nil || p.PaneID == "" {
			return
		}
		r.close(p.PaneID, env.TS)
	}
}

// paneExists reports whether pane is in the authoritative live set, refreshing
// that set when it is stale or does not contain the pane.
//
// The refresh-on-miss is what keeps this from swallowing real work: a genuinely
// new pane is missing from a cached set for exactly the same reason a dead one
// is, so a miss must be re-checked against Herdr rather than believed. A hit
// needs no read at all, which is the steady state.
//
// With no reader configured (tests) everything is treated as live, so this guard
// can never be the reason a unit test sees no entry.
func (r *Recorder) paneExists(pane string) bool {
	if r.agents == nil {
		return true
	}
	r.mu.Lock()
	fresh := r.now().Sub(r.liveAt) < liveTTL
	if fresh && r.live[pane] {
		r.mu.Unlock()
		return true
	}
	if fresh {
		// Cached, current, and this pane is not in it.
		r.mu.Unlock()
		return false
	}
	r.mu.Unlock()

	// Read outside the lock: it is a socket round-trip.
	states, err := r.agents.Agents()
	if err != nil {
		// Can't tell. Prefer recording a possible ghost over silently dropping a
		// real transition — a wrong entry is visible and fixable, a missing one is
		// not.
		log.Warn("timeline-recorder: pane-existence read failed; recording anyway", "pane", pane, "err", err)
		return true
	}
	live := make(map[string]bool, len(states))
	r.mu.Lock()
	for _, s := range states {
		if s.Pane == "" {
			continue
		}
		live[s.Pane] = true
		if sp, open := r.spans[s.Pane]; open && s.Title != "" && sp.title != s.Title {
			sp.title = s.Title
			r.spans[s.Pane] = sp
		}
	}
	r.live, r.liveAt = live, r.now()
	r.mu.Unlock()
	return live[pane]
}

// record appends one transition and re-opens the pane's span.
//
// A repeat of the status already open is dropped. The ingester already dedupes,
// but it dedupes per ingester — a Herdr reconnect re-seeds that baseline, so the
// same status can legitimately be re-announced, and recording it would show the
// user a transition that never happened AND reset the duration that made the row
// worth reading.
func (r *Recorder) record(pane, agent, session, workspace, status, title string, tsMillis int64) {
	at := time.UnixMilli(tsMillis)
	r.mu.Lock()
	prev, open := r.spans[pane]
	if open && prev.status == status {
		r.mu.Unlock()
		return
	}
	if !open {
		// No open span, so this is a first sighting — and a first sighting is the
		// one shape a REPLAYED transition can take. Herdr re-delivers recent
		// events to a new subscriber, and nothing in the pipeline carries the
		// original time (its subscription_event is {event, data} with no
		// timestamp), so the bus stamps the replay with time.Now(). Recording it
		// dates a transition from an hour ago as happening this second.
		//
		// That is fatal for this feature specifically: elapsed time is the only
		// thing it knows that /snapshot does not. Worse, it repeats on every
		// restart — observed 33 entries becoming 61, the extra 28 all for panes
		// closed half an hour earlier — so the bounded ring fills with ghosts
		// that evict the real history it exists to preserve.
		//
		// A pane that no longer exists cannot be transitioning now. Checking
		// existence is what separates a replayed ghost from a genuinely new pane,
		// which is otherwise indistinguishable: both are simply unknown here.
		r.mu.Unlock()
		if !r.paneExists(pane) {
			return
		}
		r.mu.Lock()
		// Re-read: paneExists released the lock, so another event may have opened
		// this span while the read was in flight.
		prev, open = r.spans[pane]
		if open && prev.status == status {
			r.mu.Unlock()
			return
		}
	}
	e := Entry{TS: tsMillis, Pane: pane, Agent: agent, Session: session, Workspace: workspace, Title: title, To: status}
	if open {
		e.From = prev.status
		if prev.known {
			d := at.Sub(prev.since).Milliseconds()
			e.PrevMS = &d
		}
		// Fall back to the span's remembered context for anything this payload
		// left out; a status event is not guaranteed to repeat the agent kind.
		if e.Agent == "" {
			e.Agent = prev.agent
		}
		if e.Session == "" {
			e.Session = prev.session
		}
		if e.Workspace == "" {
			e.Workspace = prev.workspace
		}
		// The span's title WINS over the event's. Herdr's status events carry the
		// raw terminal title, which for a freshly-started agent is the generic
		// "Claude Code" until it renames itself — while the span's came from an
		// authoritative read and is the name a person would recognise. Letting the
		// event overwrite it turns "Evaluate Elasticsearch instance reduction" back
		// into "Claude Code" on the next transition.
		if prev.title != "" {
			e.Title = prev.title
		}
	}
	r.spans[pane] = span{
		status: status, since: at, known: true,
		agent: e.Agent, session: e.Session, workspace: e.Workspace, title: e.Title,
	}
	r.mu.Unlock()
	r.log.Append(e)
}

// close records a pane's disappearance and forgets its span. A pane we have
// never seen an agent in is ignored: a plain shell closing is not agent
// activity, and recording every one of them would bury the rows that matter.
func (r *Recorder) close(pane string, tsMillis int64) {
	r.mu.Lock()
	prev, open := r.spans[pane]
	if !open {
		r.mu.Unlock()
		return
	}
	delete(r.spans, pane)
	r.mu.Unlock()

	e := Entry{
		TS: tsMillis, Pane: pane, Agent: prev.agent, Session: prev.session,
		Workspace: prev.workspace, From: prev.status, To: StatusGone,
	}
	if prev.known {
		d := time.UnixMilli(tsMillis).Sub(prev.since).Milliseconds()
		e.PrevMS = &d
	}
	r.log.Append(e)
}

// flush persists the ring, logging rather than propagating a write failure: the
// recorder has nowhere to return an error to, and a disk problem must not stop
// it recording into memory.
func (r *Recorder) flush() {
	if err := r.log.Flush(); err != nil {
		log.Error("timeline-recorder: flush failed", "err", err)
	}
}
