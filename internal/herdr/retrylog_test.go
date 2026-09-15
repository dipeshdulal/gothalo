package herdr

import (
	"bytes"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/events"
)

// captureLogs redirects the package-level logger into a buffer for the duration
// of a test, at debug so suppressed repeats are still observable. Charm's
// global logger is process-wide; restore it afterward.
func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	prevLevel := log.GetLevel()
	var buf bytes.Buffer
	log.SetOutput(&buf)
	log.SetLevel(log.DebugLevel)
	t.Cleanup(func() {
		log.SetOutput(os.Stderr)
		log.SetLevel(prevLevel)
	})
	return &buf
}

// TestFailureLogWarnsOnChangeAndInterval pins the failure throttle's policy:
// the first failure and a materially different one warn at once, identical
// retries stay quiet until the interval elapses, and a success clears the
// streak so the next failure is reported as new.
func TestFailureLogWarnsOnChangeAndInterval(t *testing.T) {
	clock := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	f := newFailureLog()
	f.now = func() time.Time { return clock }

	first := errors.New("dial herdr socket /home/dev/.config/herdr/herdr.sock: connect: no such file or directory")
	if !f.failed(first) {
		t.Fatal("first failure was suppressed")
	}
	for i := 0; i < 10; i++ {
		clock = clock.Add(reconnectDelay)
		if f.failed(first) {
			t.Fatalf("unchanged failure warned again after %s", time.Duration(i+1)*reconnectDelay)
		}
	}

	// A materially different error is news, not a repeat.
	changed := errors.New("herdr status server: exit status 1")
	if !f.failed(changed) {
		t.Error("a changed error was suppressed")
	}
	if f.failed(changed) {
		t.Error("changed error warned twice in a row")
	}

	// An unchanged error becomes worth repeating once the interval passes.
	clock = clock.Add(failureRepeat)
	if !f.failed(changed) {
		t.Error("an unchanged failure was not repeated after the interval")
	}

	// A success ends the streak; the next identical failure warns as new.
	if !f.recovered() {
		t.Error("recovered after a failure reported nothing")
	}
	if f.recovered() {
		t.Error("recovered reported a second recovery with no failure between")
	}
	if !f.failed(changed) {
		t.Error("failure after a reconnect was suppressed")
	}
}

// TestSessionFailureLoggingIsBoundedAndRecovers is the regression test for the
// flood: with Herdr absent, the reconnect loop retried every ~2s and logged an
// identical WARN every time (~65k lines/day). The loop must keep retrying, but
// the log must not repeat the same failure forever — and it must say so when
// the socket comes back.
func TestSessionFailureLoggingIsBoundedAndRecovers(t *testing.T) {
	buf := captureLogs(t)
	ing := NewIngester(New(), events.New())

	// Drive the throttle from a fake clock so the test is deterministic and
	// does not sleep.
	clock := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	ing.retry.now = func() time.Time { return clock }

	err := errors.New("dial herdr socket /home/dev/.config/herdr/herdr.sock: connect: no such file or directory")
	const attempts = 100 // 200s of retries, well inside one repeat interval
	for i := 0; i < attempts; i++ {
		ing.logSessionEnded(err)
		clock = clock.Add(reconnectDelay)
	}

	if got := strings.Count(buf.String(), "WARN herdr ingester: session ended"); got != 1 {
		t.Errorf("warnings = %d over %d identical failures, want exactly 1", got, attempts)
	}
	// The retries are demoted, not dropped: every one is still there at debug.
	if got := strings.Count(buf.String(), "herdr ingester: session ended"); got != attempts {
		t.Errorf("session-ended lines = %d, want %d (every retry still logged at debug)", got, attempts)
	}

	// A reconnect after the failures is reported.
	ing.logConnected(false, "/home/dev/.config/herdr/herdr.sock", 29)
	if !strings.Contains(buf.String(), "INFO herdr ingester: reconnected") {
		t.Errorf("reconnect after failures was not reported; log:\n%s", buf.String())
	}
}

// TestSecondSuccessIsDebugNotInfo: a socket that connects over and over with no
// intervening failure is repetitive, not a recovery. The first connect keeps
// its "subscribed" line; later ones are debug.
func TestSecondSuccessIsDebugNotInfo(t *testing.T) {
	buf := captureLogs(t)
	ing := NewIngester(New(), events.New())

	ing.logConnected(false, "/tmp/herdr.sock", 29)
	if got := strings.Count(buf.String(), "INFO herdr ingester: subscribed"); got != 0 {
		t.Errorf("a repeat connect (no prior failure) logged %d info lines, want 0", got)
	}
	if !strings.Contains(buf.String(), "herdr ingester: subscribed") {
		t.Errorf("repeat connect was dropped entirely; it should still be debug; log:\n%s", buf.String())
	}
}
