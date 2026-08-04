package transcript

import (
	"fmt"
	"strings"
)

// Source is one agent's transcript, opened for reading and streaming.
//
// It exists because agents do not agree on where a conversation lives. Claude
// Code appends JSONL files; Hermes keeps every session in a SQLite database.
// Those have nothing in common at the storage layer — one is tailed by byte
// offset, the other queried by row id — but they produce the same normalized
// Entry stream, page the same way, and drive the same WebSocket framing. Source
// is the seam: everything above it (internal/server/transcript.go, the wire
// protocol, the Entry schema) is storage-agnostic.
//
// The three methods mirror the three things the endpoint does: send the newest
// page on connect, serve load_older cursor reads, and poll for new entries.
//
// Seq is an absolute 1-based position in the session's normalized entry stream
// and is the cursor the client pages on. A Source must stamp it consistently:
// Backlog and Older return entries with Seq set, Poll leaves it 0 for the caller
// to continue from Backlog.Total. Implementations are used by a single
// connection goroutine plus its read goroutine, so Older must be safe to call
// concurrently with Poll.
type Source interface {
	// Backlog returns the newest page of up to cap entries and positions the
	// source so the next Poll returns only what arrives after it. Call it exactly
	// once, before Poll.
	Backlog(cap int) (Backlog, error)

	// Older returns up to limit entries strictly older than beforeSeq, oldest
	// first. An empty page means nothing older exists.
	Older(beforeSeq, limit int) (OlderPage, error)

	// Poll returns entries that appeared since Backlog or the previous Poll, nil
	// when there is nothing new. It must not replay history if the underlying
	// store is truncated or rewritten.
	Poll() ([]Entry, error)

	// Close releases whatever the source holds. Safe to call once, always.
	Close() error
}

// Opener resolves a pane to an open Source for one agent kind. Each kind
// registers one from its own file's init, exactly like Reader.
//
// Open receives the pane's cwd and the agent's own session id
// (herdr's agent_session.value). An opener that cannot resolve a transcript
// returns ErrNoTranscript so the endpoint answers 404.
type Opener interface {
	// Kind is the herdr agent kind this opener handles ("claude", "hermes", …).
	Kind() string
	// Open resolves and opens the transcript for a pane.
	Open(cwd, sessionID string) (Source, error)
}

// openers maps agent kind -> opener, populated by each kind's init via
// RegisterOpener. Written only at startup; read-only after.
var openers = map[string]Opener{}

// RegisterOpener adds an opener to the registry, keyed by o.Kind(). Call it from
// a kind's init(). A later RegisterOpener for the same kind wins.
func RegisterOpener(o Opener) { openers[o.Kind()] = o }

// Open resolves a pane's transcript and returns it ready to stream.
//
// A kind with no registered opener returns ErrUnsupportedKind — that is how
// codex/opencode report "recognized, not wired up" today, and it maps to a 404
// with a clear message rather than a broken stream.
func Open(kind, cwd, sessionID string) (Source, error) {
	o, ok := openers[strings.ToLower(strings.TrimSpace(kind))]
	if !ok {
		return nil, ErrUnsupportedKind
	}
	return o.Open(cwd, sessionID)
}

// SupportedKinds lists the kinds with a registered opener, for diagnostics.
func SupportedKinds() []string {
	out := make([]string, 0, len(openers))
	for k := range openers {
		out = append(out, k)
	}
	return out
}

// errUnexpected wraps a storage error with the kind that produced it, so a
// failure in one backend is attributable in logs.
func errUnexpected(kind string, err error) error {
	return fmt.Errorf("transcript/%s: %w", kind, err)
}
