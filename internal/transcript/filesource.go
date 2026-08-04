package transcript

import (
	"errors"
	"io/fs"
	"sync"
)

// fileSource is the Source for agents that append a line-oriented transcript
// file (Claude Code's JSONL today). It is a thin adapter over the functions in
// tail.go: the byte offset that used to live in the endpoint now lives here,
// which is the whole point of the Source seam — no caller needs to know this
// backend is a file, let alone where its read cursor is.
//
// Older re-scans from the top rather than seeking, exactly as ReadOlder always
// has: entries are normalized, so an absolute seq has no fixed byte position and
// there is nothing to seek to. It stays cheap because the scan stops at the
// cursor and memory is bounded by a ring buffer.
type fileSource struct {
	path   string
	reader Reader

	// mu guards offset: Poll runs on the connection goroutine while Older runs on
	// the socket's read goroutine. Older does not touch offset, but Poll mutates
	// it on every call, so the tailer must not be shared unguarded.
	mu     sync.Mutex
	tailer *Tailer
}

func newFileSource(path string, r Reader) *fileSource {
	return &fileSource{path: path, reader: r}
}

// Backlog reads the newest page and arms the tailer at the offset where that
// page ended, so Poll resumes exactly where the backlog stopped.
//
// A file that does not exist yet is an empty transcript, not an error: an agent
// that has not spoken has nothing to show, and Claude only creates the .jsonl on
// its first message. The tailer is armed at offset 0 so entries stream in as
// soon as the file appears.
func (s *fileSource) Backlog(cap int) (Backlog, error) {
	b, offset, err := ReadBacklog(s.path, s.reader, cap)
	if errors.Is(err, fs.ErrNotExist) {
		s.mu.Lock()
		s.tailer = NewTailer(s.path, s.reader, 0)
		s.mu.Unlock()
		return Backlog{}, nil
	}
	if err != nil {
		return Backlog{}, err
	}
	s.mu.Lock()
	s.tailer = NewTailer(s.path, s.reader, offset)
	s.mu.Unlock()
	return b, nil
}

func (s *fileSource) Older(beforeSeq, limit int) (OlderPage, error) {
	page, err := ReadOlder(s.path, s.reader, beforeSeq, limit)
	if errors.Is(err, fs.ErrNotExist) {
		return OlderPage{}, nil // nothing written yet, so nothing older
	}
	return page, err
}

// Poll returns entries appended since the last call. It is a no-op before
// Backlog has armed the tailer, so a caller that polls early gets nothing rather
// than a nil dereference.
//
// A missing file yields nothing rather than an error — the transcript may not
// have been created yet (a pane whose agent has not spoken), and the next poll
// will pick it up the moment it is.
func (s *fileSource) Poll() ([]Entry, error) {
	s.mu.Lock()
	t := s.tailer
	s.mu.Unlock()
	if t == nil {
		return nil, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ents, err := t.Poll()
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	return ents, err
}

// Close is a no-op: the tailer holds no handle between polls (it opens, reads,
// closes), so there is nothing to release.
func (s *fileSource) Close() error { return nil }
