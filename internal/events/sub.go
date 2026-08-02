package events

import "sync"

// Sub is a single subscription handed out by Bus.Subscribe. Read envelopes from
// C(); when that channel is closed, check Dropped() to tell a lag-drop (true —
// the subscriber fell behind and must reconnect + re-snapshot) from a normal
// Close() by the reader (false). Close() is idempotent and must be called to
// unregister the subscription.
type Sub struct {
	bus *Bus
	ch  chan Envelope

	mu      sync.Mutex
	closed  bool
	dropped bool
}

// C returns the receive channel. A closed channel means either the reader
// Closed the subscription or the bus dropped it for lagging (see Dropped).
func (s *Sub) C() <-chan Envelope { return s.ch }

// Dropped reports whether the bus closed this subscription because it fell
// behind (its buffer filled). Meaningful once C() is observed closed.
func (s *Sub) Dropped() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dropped
}

// deliver attempts a non-blocking send. If the buffer is full the subscriber is
// dropped: its channel is closed once and marked dropped, and all future
// deliveries are no-ops. Called by Bus.Publish under the bus read lock; it takes
// only the per-sub lock, so a slow subscriber never blocks the bus or its peers.
func (s *Sub) deliver(env Envelope) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	select {
	case s.ch <- env:
	default:
		s.dropped = true
		s.closed = true
		close(s.ch)
	}
}

// Close unregisters the subscription and closes its channel (unless the bus
// already dropped it). Safe to call multiple times.
func (s *Sub) Close() {
	s.bus.remove(s)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.closed = true
	close(s.ch)
}
