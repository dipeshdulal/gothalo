package herdr

import (
	"sync"
	"time"
)

// failureRepeat is how long an unchanged failure stays quiet before it is worth
// a warning again. Between reports it goes to debug, so it is still visible to
// someone looking for it but costs nothing on a production log.
const failureRepeat = 5 * time.Minute

// failureLog collapses a repeating failure into a bounded number of warnings.
//
// It exists for the reconnect loops. When Herdr is not running its socket is
// simply absent, so the ingester retries every [reconnectDelay] and each retry
// used to log an identical WARN — measured at ~65k lines/day in a container that
// stays up for weeks, which buries everything else. The retry itself is correct
// and must not change; only its reporting does. The first failure is worth a
// warning, a materially different failure is worth another, and an unchanged one
// is worth repeating only occasionally. A success after failures clears the
// streak, so the next outage warns again rather than hiding inside the old one.
//
// One failureLog tracks one failure stream. Independent streams — the main
// session, each pane watcher, session discovery — hold their own.
type failureLog struct {
	mu      sync.Mutex
	last    string    // the last error text reported at WARN
	lastAt  time.Time // when that report happened
	failing bool      // whether the current failure streak is unbroken
	repeat  time.Duration
	now     func() time.Time
}

func newFailureLog() *failureLog {
	return &failureLog{repeat: failureRepeat, now: time.Now}
}

// failed records one failure and reports whether it should be logged at WARN.
// True for the first failure of a streak, for an error whose text differs from
// the last reported one, and for an unchanged repeat once repeat has elapsed;
// false for every retry in between.
func (f *failureLog) failed(err error) bool {
	f.mu.Lock()
	defer f.mu.Unlock()

	msg := ""
	if err != nil {
		msg = err.Error()
	}
	now := f.now()
	report := !f.failing || msg != f.last || now.Sub(f.lastAt) >= f.repeat
	f.failing = true
	f.last = msg
	if report {
		f.lastAt = now
	}
	return report
}

// recovered reports whether a success ends a failing streak, and clears it so
// the next failure is reported as new. False when the previous attempt already
// succeeded (there is nothing to recover from).
func (f *failureLog) recovered() bool {
	f.mu.Lock()
	defer f.mu.Unlock()

	was := f.failing
	f.failing = false
	f.last = ""
	return was
}
