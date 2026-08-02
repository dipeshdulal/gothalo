// Package watcher detects agent transitions into blocked/done and invokes a
// callback. It is event-driven by default (one `herdr agent wait` goroutine per
// agent, discovered via periodic snapshots), with a snapshot-poll fallback.
// A state an agent is already in when watching starts is never re-notified, so
// a (re)start doesn't replay every currently-blocked/done agent.
package watcher

import (
	"sync"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// NotifyFunc is called once per transition into blocked/done. seq is the
// agent's state_change_seq at the transition — carried into the push so a
// lock-screen approve can be idempotent (D8).
type NotifyFunc func(paneID, status, title string, seq int)

// Watcher observes Herdr agents via a herdr.Client.
type Watcher struct {
	h       *herdr.Client
	notify  NotifyFunc
	usePoll bool
}

// New builds a Watcher. If usePoll is true it uses the snapshot-poll fallback
// instead of the event-driven `herdr agent wait` path.
func New(h *herdr.Client, notify NotifyFunc, usePoll bool) *Watcher {
	return &Watcher{h: h, notify: notify, usePoll: usePoll}
}

// Run blocks, watching forever. Call it in its own goroutine.
func (w *Watcher) Run() {
	if w.usePoll {
		log.Info("watcher started", "mode", "poll")
		w.pollLoop()
		return
	}
	log.Info("watcher started", "mode", "event-driven (herdr agent wait)")
	w.waitLoop()
}

// waitLoop discovers agents from periodic snapshots and runs one event-driven
// watchAgent goroutine per agent. Discovery never calls notify.
func (w *Watcher) waitLoop() {
	var mu sync.Mutex
	watched := map[string]bool{}

	for {
		agents, err := w.h.Agents()
		if err != nil {
			log.Error("watcher discover failed", "err", err)
			time.Sleep(5 * time.Second)
			continue
		}
		for _, a := range agents {
			pane, status := a.PaneID, a.Status
			mu.Lock()
			if watched[pane] {
				mu.Unlock()
				continue
			}
			watched[pane] = true
			mu.Unlock()
			go w.watchAgent(pane, status, func() {
				mu.Lock()
				delete(watched, pane)
				mu.Unlock()
			})
		}
		time.Sleep(10 * time.Second)
	}
}

// watchAgent fires notify() on each transition INTO blocked/done via
// `herdr agent wait`. A pre-existing blocked/done state at watch-start is
// skipped (not re-notified).
func (w *Watcher) watchAgent(pane, initialStatus string, done func()) {
	defer done()

	if initialStatus == "blocked" || initialStatus == "done" {
		if _, ok := w.h.Wait(pane, "idle", "working", "unknown"); !ok {
			return
		}
	}

	for {
		r, ok := w.h.Wait(pane, "blocked", "done")
		if !ok {
			return // agent gone
		}
		if r.Status == "blocked" || r.Status == "done" {
			w.notify(pane, r.Status, r.Title, r.StateChangeSeq)
		}
		// Wait for it to leave blocked/done before looping, so we catch the
		// NEXT entry instead of re-firing the same still-current state.
		if _, ok := w.h.Wait(pane, "idle", "working", "unknown"); !ok {
			return
		}
	}
}

// pollLoop is the snapshot-poll fallback. It seeds a baseline on the first pass
// so a (re)start doesn't re-notify every already-blocked/done agent.
func (w *Watcher) pollLoop() {
	seen := map[string]string{}
	first := true
	for {
		agents, err := w.h.Agents()
		if err != nil {
			log.Error("watcher poll failed", "err", err)
			time.Sleep(5 * time.Second)
			continue
		}
		for _, a := range agents {
			prev := seen[a.PaneID]
			if !first && a.Status != prev && (a.Status == "blocked" || a.Status == "done") {
				w.notify(a.PaneID, a.Status, a.Title, a.StateChangeSeq)
			}
			seen[a.PaneID] = a.Status
		}
		first = false
		time.Sleep(3 * time.Second)
	}
}
