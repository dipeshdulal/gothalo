package events

import (
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"
)

// Bus is an in-process fan-out pub/sub. One Publish delivers the same Envelope
// to every current Subscriber over its own bounded channel. A subscriber that
// can't keep up (its buffer fills) is DROPPED — its channel is closed and no
// further events are delivered to it — rather than being allowed to block the
// bus or any other subscriber. The dropped subscriber's reader observes the
// closed channel (Sub.Dropped reports true) and is expected to reconnect and
// re-snapshot. This "never block the bus" rule is what lets a single Herdr
// subscription safely fan out to many app clients of varying speed.
//
// The zero value is not usable; call New.
type Bus struct {
	mu   sync.RWMutex
	subs map[*Sub]struct{}
	seq  atomic.Uint64
	now  func() time.Time
}

// New returns an empty Bus.
func New() *Bus {
	return &Bus{subs: make(map[*Sub]struct{}), now: time.Now}
}

// CurrentSeq returns the sequence number of the most recently published event
// (0 before anything is published). The WS hub records this as the baseline seq
// of its snapshot frame so a client can tell where the delta stream begins.
func (b *Bus) CurrentSeq() uint64 { return b.seq.Load() }

// Publish assigns the next monotonic seq and the current timestamp, wraps
// payload into an Envelope, and fans it out to every subscriber. payload is
// marshalled to JSON once (a json.RawMessage or []byte is used as-is). It never
// blocks on a slow subscriber. The published Envelope is returned (handy for
// logging/tests); a marshalling error returns a zero Envelope and the error and
// publishes nothing.
func (b *Bus) Publish(source, typ string, payload any) (Envelope, error) {
	raw, err := toRaw(payload)
	if err != nil {
		return Envelope{}, err
	}
	env := Envelope{
		Source:  source,
		Type:    typ,
		Seq:     b.seq.Add(1),
		TS:      b.now().UnixMilli(),
		Payload: raw,
	}
	b.mu.RLock()
	for s := range b.subs {
		s.deliver(env)
	}
	b.mu.RUnlock()
	return env, nil
}

func toRaw(payload any) (json.RawMessage, error) {
	switch v := payload.(type) {
	case nil:
		return json.RawMessage("null"), nil
	case json.RawMessage:
		return v, nil
	case []byte:
		return json.RawMessage(v), nil
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return nil, err
		}
		return b, nil
	}
}

// Subscribe registers a new subscriber with a channel buffered to buffer
// envelopes and returns it. buffer bounds how far behind a subscriber may fall
// before it is dropped; a small value (a few hundred) is plenty for the coarse,
// low-volume bus. The caller MUST eventually call Sub.Close to unregister.
func (b *Bus) Subscribe(buffer int) *Sub {
	if buffer < 1 {
		buffer = 1
	}
	s := &Sub{ch: make(chan Envelope, buffer), bus: b}
	b.mu.Lock()
	b.subs[s] = struct{}{}
	b.mu.Unlock()
	return s
}

// SubscriberCount reports how many subscribers are currently registered.
func (b *Bus) SubscriberCount() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return len(b.subs)
}

func (b *Bus) remove(s *Sub) {
	b.mu.Lock()
	delete(b.subs, s)
	b.mu.Unlock()
}
