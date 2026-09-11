package server

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"sync"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/agentstate"
	"github.com/dipeshdulal/gothalo/internal/events"
	"github.com/dipeshdulal/gothalo/internal/push"
)

// Notification channel ids. These are a contract with the app: they must match
// the channels it creates at launch, because a notification naming a channel
// that does not exist is dropped silently on Android 8+. Blocked and done are
// separate channels so "an agent wants you" can ring while "an agent finished"
// stays quiet — and so the user can tune or mute them independently.
// See docs/CONTRACT-notifications.md.
const (
	ChannelBlocked = "gothalo_blocked"
	ChannelDone    = "gothalo_done"
)

// maxBodyRunes caps what we put in a notification body. A tray notification
// shows two or three lines collapsed; anything past this is noise that only eats
// into FCM's 4KB payload budget.
const maxBodyRunes = 240

// maxOptions is how many of a prompt's choices ride along in the payload. The
// tray shows at most two action buttons; the rest is context for the app.
const maxOptions = 4

// Notify fans one agent transition out to every registered device.
//
// The push has to answer, from the lock screen alone: WHICH machine, WHICH
// agent, and WHY it woke you. So it carries the server identity (a phone is
// paired with several bridges and registers the same FCM token with each — the
// payload is the only thing that can disambiguate them) and, for a block, the
// agent's actual question rather than just the pane's terminal title.
func (s *Server) Notify(paneID, status, title string, seq int) {
	log.Info("notify", "agent", paneID, "status", status, "title", title, "seq", seq)

	st := s.promptState(paneID, status)
	n := s.compose(paneID, status, title, seq, st)

	sent, total := s.fanout(n)
	log.Info("pushed", "sent", sent, "total", total, "agent", paneID, "status", status)

	// The bus mirrors the FCM fan-out as a gothalo.push_sent system event, which
	// is also what arms the notification-clearer.
	s.publish(events.TypePushSent, map[string]any{
		"agent": paneID, "status": status, "title": title, "seq": seq,
		"sent": sent, "total": total, "server_id": s.cfg.ServerID,
	})
}

// notification is one composed alert, before it is addressed to a device.
type notification struct {
	title   string
	body    string
	tag     string
	channel string
	data    map[string]string
}

// compose builds the user-visible notification for one transition.
//
// Title carries the WHERE — "<server> · <agent>" — because that is the line a
// locked phone always shows, and "which of my machines is this?" was previously
// unanswerable. Body carries the WHY: the agent's real question when we could
// read one, its last headline otherwise.
func (s *Server) compose(paneID, status, title string, seq int, st *agentstate.State) notification {
	agent := strings.TrimSpace(title)
	if agent == "" {
		agent = paneID
	}
	server := strings.TrimSpace(s.cfg.ServerName)

	n := notification{
		tag: s.cfg.ServerID + "/" + paneID,
		data: map[string]string{
			"type":             "alert",
			"agent":            paneID,
			"status":           status,
			"state_change_seq": strconv.Itoa(seq),
			"server_id":        s.cfg.ServerID,
			"server_name":      server,
			"agent_title":      agent,
		},
	}

	n.title = agent
	if server != "" {
		n.title = server + " · " + agent
	}

	switch status {
	case "blocked":
		n.channel = ChannelBlocked
		n.body = "Needs you"
		if q := prompt(st); q != "" {
			n.body = "Needs you — " + q
			n.data["question"] = q
		}
		if st != nil && st.Blocked != nil {
			if opts := options(st.Blocked); len(opts) > 0 {
				if b, err := json.Marshal(opts); err == nil {
					n.data["options"] = string(b)
				}
				n.body += " · " + labels(opts)
			}
			if st.Blocked.Category != "" {
				n.data["category"] = st.Blocked.Category
			}
		}
	default: // "done", and anything else we are told to announce
		n.channel = ChannelDone
		n.body = "Finished"
		if st != nil {
			if h := strings.TrimSpace(st.Headline); h != "" {
				n.body = "Finished — " + h
			} else if d := strings.TrimSpace(firstLine(st.Detail)); d != "" {
				n.body = "Finished — " + d
			}
		}
	}

	n.body = truncate(n.body, maxBodyRunes)
	n.data["title"] = n.title
	n.data["body"] = n.body
	return n
}

// fanout delivers one notification to every registered device, concurrently.
//
// Each device gets TWO messages, because on Android no single message can both
// arrive reliably and be actionable:
//
//   - a DISPLAY message, carrying a notification block Android renders itself.
//     This is the one that survives a swiped-away, frozen or killed app — but
//     Android does not hand a notification-bearing message to the app while it is
//     backgrounded, so it can never grow action buttons.
//   - a DATA message with the same tag. Data-only messages *do* reach the app's
//     handler, which redraws the notification in place with Approve/Reject.
//
// So the notification always appears, and upgrades itself to an actionable one
// whenever there is a live process to do it. Delivery is counted on the display
// message: that is the one whose failure means the user saw nothing.
//
// A token FCM rejects as dead is pruned from the store instead of being retried
// on every future notification.
func (s *Server) fanout(n notification) (sent, total int) {
	if s.push == nil {
		return 0, 0
	}
	tokens := s.store.FCMTokens()
	if len(tokens) == 0 {
		return 0, 0
	}

	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, t := range tokens {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if s.send(push.Message{
				Token: t, Kind: push.KindDisplay,
				Title: n.title, Body: n.body,
				Tag: n.tag, ChannelID: n.channel, HighPriority: true,
				Data: withRender(n.data, renderOS),
			}) {
				mu.Lock()
				sent++
				mu.Unlock()
			}
			// The upgrade. Best-effort by definition — a frozen app never sees
			// it, and the display message above already covered that case.
			s.send(push.Message{
				Token: t, Kind: push.KindData,
				Tag: n.tag, ChannelID: n.channel, HighPriority: true,
				Data: withRender(n.data, renderApp),
			})
		}()
	}
	wg.Wait()
	return sent, len(tokens)
}

// Values of the `render` payload key, which tells the app which of the two
// messages it is looking at. Without it, a foreground app — which receives BOTH
// — would log every alert to its history twice.
const (
	renderOS  = "os"
	renderApp = "app"
)

// withRender copies the payload with a render marker. A copy, not a mutation:
// the two messages share everything else and go out concurrently.
func withRender(data map[string]string, render string) map[string]string {
	out := make(map[string]string, len(data)+1)
	for k, v := range data {
		out[k] = v
	}
	out["render"] = render
	return out
}

// send delivers one message, pruning the device token if FCM says it is dead.
// It reports whether the message was accepted.
func (s *Server) send(m push.Message) bool {
	err := s.push.SendMessage(m)
	if err == nil {
		return true
	}
	if errors.Is(err, push.ErrTokenInvalid) {
		cleared := s.store.ClearFCMToken(m.Token)
		log.Warn("push token dead, cleared", "token", redact(m.Token), "devices", cleared)
		return false
	}
	log.Error("push failed", "token", redact(m.Token), "kind", m.Kind, "err", err)
	return false
}

// promptState reads the live state behind a transition, so the notification can
// say what the agent is actually asking.
//
// Best-effort by design: this runs on the notification path, and a notification
// that says a little less is far better than one that never goes out. Every
// failure degrades to nil and the caller falls back to the pane title.
func (s *Server) promptState(paneID, status string) *agentstate.State {
	c, _, bare, err := s.target(paneID)
	if err != nil {
		return nil
	}
	agent, err := c.Get(bare)
	if err != nil {
		return nil
	}
	// The blocked form is UI the agent is drawing right now, so it can only come
	// from the current screen — see handleAgentState for why this read and not
	// the transcript.
	detection, derr := c.ReadText(bare, "detection", 0)
	if derr != nil {
		log.Warn("notify: detection read failed", "pane", paneID, "err", derr)
	}
	st := agentstate.Build(agentstate.Input{
		PaneID:    paneID,
		Kind:      agent.Kind,
		Status:    agent.Status,
		Title:     agent.Title,
		Detection: detection,
	})
	// Prefer the service's own question form over the screen scrape: it carries
	// the exact choices, which ride into the notification's actions.
	if status == "blocked" {
		if _, form, qerr := opencodeQuestion(agent); qerr == nil {
			if b := opencodeBlocked(form); b != nil {
				st.Blocked = b
			}
		}
	}
	if status == "blocked" && st.AgentStatus == "blocked" {
		if det, eerr := c.Explain(bare); eerr == nil && det != nil && det.RuleID != "" {
			if st.Blocked == nil {
				st.Blocked = &agentstate.Blocked{}
			}
			st.Blocked.Category = det.RuleID
		}
	}
	return &st
}

// prompt picks the question to show for a block: the parsed prompt line, or the
// headline the parser fell back to.
func prompt(st *agentstate.State) string {
	if st == nil {
		return ""
	}
	if st.Blocked != nil {
		if q := strings.TrimSpace(st.Blocked.Question); q != "" {
			return q
		}
	}
	return strings.TrimSpace(firstLine(st.Headline))
}

// options trims a prompt's choices to what is worth carrying in a payload.
func options(b *agentstate.Blocked) []agentstate.Option {
	if len(b.Options) <= maxOptions {
		return b.Options
	}
	return b.Options[:maxOptions]
}

// labels renders choices for the notification body, e.g. "1. Yes / 2. No".
func labels(opts []agentstate.Option) string {
	parts := make([]string, 0, len(opts))
	for _, o := range opts {
		l := strings.TrimSpace(o.Label)
		if l == "" {
			continue
		}
		if o.Index > 0 {
			l = strconv.Itoa(o.Index) + ". " + l
		}
		parts = append(parts, l)
	}
	return strings.Join(parts, " / ")
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func truncate(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return strings.TrimSpace(string(r[:max-1])) + "…"
}

// redact shortens a device token for logs — enough to correlate, not enough to
// send with.
func redact(t string) string {
	return t[:min(8, len(t))] + "…"
}
