package transcript

import (
	"bufio"
	"bytes"
	"io"
	"os"
)

// DefaultBacklogCap is how many trailing normalized entries the backlog keeps. A
// transcript can hold thousands of entries; the socket sends at most this many
// newest ones (older are elided, signalled by Backlog.HasMore) so a connect can't
// buffer an unbounded history. One transcript line can expand into several
// entries, so this caps entries, not lines.
const DefaultBacklogCap = 2000

// Backlog is the newest page of normalized history sent on connect.
type Backlog struct {
	// Entries are the newest (up to cap) normalized entries, in file order, with
	// their absolute Seq stamped (see OldestSeq).
	Entries []Entry
	// HasMore is true when older entries exist before this page (seq < OldestSeq).
	HasMore bool
	// Total is how many normalized entries the whole file produced. The newest
	// entry's absolute seq is Total.
	Total int
	// OldestSeq is the absolute 1-based seq of the first (oldest) entry in this
	// page, or 0 when the file is empty. It is the cursor a client passes back as
	// load_older's before_seq to fetch the page immediately older than this one.
	OldestSeq int
}

// ReadBacklog scans the transcript once, normalizing every line, and returns the
// last cap entries plus the byte offset to resume tailing from (the end of the
// last complete line). Every returned entry carries its ABSOLUTE 1-based seq (its
// position in the whole file's normalized stream), so the page's oldest seq is a
// stable cursor into the file even though older entries were elided. Memory is
// bounded to cap entries via a ring buffer — the whole file is never held. A
// trailing partial line (mid-append) is left for the tailer and excluded from the
// offset.
func ReadBacklog(path string, r Reader, cap int) (Backlog, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return Backlog{}, 0, err
	}
	defer f.Close()

	rb := newRing(cap)
	br := bufio.NewReaderSize(f, 128*1024)
	var offset int64
	total := 0
	dropped := false
	for {
		lineBytes, rerr := br.ReadBytes('\n')
		if len(lineBytes) > 0 && rerr == nil { // a complete line (had a newline)
			offset += int64(len(lineBytes))
			if trimmed := bytes.TrimRight(lineBytes, "\r\n"); len(trimmed) > 0 {
				for _, e := range r.Normalize(trimmed) {
					total++
					if rb.push(e) {
						dropped = true
					}
				}
			}
		}
		if rerr != nil {
			// io.EOF with a leftover partial line (no newline) — leave it for the
			// tailer; offset already excludes it.
			if rerr != io.EOF {
				return Backlog{}, 0, rerr
			}
			break
		}
	}
	entries := rb.slice()
	// The kept slice is the tail of the stream, so its entries occupy the absolute
	// seq range [total-len+1 .. total]. Stamp each so the client has a real cursor.
	base := total - len(entries)
	for i := range entries {
		entries[i].Seq = base + i + 1
	}
	oldest := 0
	if len(entries) > 0 {
		oldest = base + 1
	}
	return Backlog{Entries: entries, HasMore: dropped, Total: total, OldestSeq: oldest}, offset, nil
}

// OlderPage is a page of history strictly older than a cursor, returned by
// ReadOlder to service a client's load_older request.
type OlderPage struct {
	// Entries are up to `limit` normalized entries immediately older than the
	// requested before_seq, in oldest→newest order, with absolute Seq stamped.
	Entries []Entry
	// OldestSeq is the absolute seq of the first (oldest) entry in this page. When
	// the page is empty (nothing older existed) it is 0.
	OldestSeq int
	// HasOlder is true when entries older than this page still exist (OldestSeq > 1).
	HasOlder bool
}

// ReadOlder returns the page of up to `limit` normalized entries immediately older
// than beforeSeq — entries whose absolute 1-based seq is < beforeSeq — in
// oldest→newest order, each with its absolute Seq stamped. Memory is bounded to
// `limit` entries via a ring buffer (the whole file is never held), and scanning
// stops as soon as the seq counter reaches beforeSeq, so paging near the head of a
// large file stays cheap. This is the load_older cursor read; the live tail is
// unaffected and keeps running independently.
func ReadOlder(path string, r Reader, beforeSeq, limit int) (OlderPage, error) {
	if limit < 1 {
		limit = 1
	}
	// Nothing can be older than the first entry.
	if beforeSeq <= 1 {
		return OlderPage{}, nil
	}

	f, err := os.Open(path)
	if err != nil {
		return OlderPage{}, err
	}
	defer f.Close()

	rb := newRing(limit)
	br := bufio.NewReaderSize(f, 128*1024)
	seq := 0
scan:
	for {
		lineBytes, rerr := br.ReadBytes('\n')
		if len(lineBytes) > 0 && rerr == nil {
			if trimmed := bytes.TrimRight(lineBytes, "\r\n"); len(trimmed) > 0 {
				for _, e := range r.Normalize(trimmed) {
					seq++
					if seq >= beforeSeq {
						break scan // reached the cursor; entries from here are not older
					}
					e.Seq = seq
					rb.push(e)
				}
			}
		}
		if rerr != nil {
			if rerr != io.EOF {
				return OlderPage{}, rerr
			}
			break
		}
	}

	entries := rb.slice()
	page := OlderPage{Entries: entries}
	if len(entries) > 0 {
		page.OldestSeq = entries[0].Seq
		page.HasOlder = entries[0].Seq > 1
	}
	return page, nil
}

// Tailer follows a transcript file from a byte offset, yielding newly-appended
// normalized entries. It holds no file handle between polls (it opens, reads new
// complete lines, closes), so the only per-socket state is the offset.
type Tailer struct {
	path   string
	r      Reader
	offset int64
}

// NewTailer returns a Tailer positioned at offset (typically the value returned by
// ReadBacklog, so the tail begins exactly where the backlog ended).
func NewTailer(path string, r Reader, offset int64) *Tailer {
	return &Tailer{path: path, r: r, offset: offset}
}

// Poll reads any complete lines appended since the last call and returns their
// normalized entries (nil when nothing new). A trailing partial line is left for
// the next poll. If the file shrank (truncated/rotated), the offset is reset to
// the new size and no entries are returned, so a rewrite doesn't replay history.
func (t *Tailer) Poll() ([]Entry, error) {
	f, err := os.Open(t.path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	switch {
	case fi.Size() < t.offset:
		t.offset = fi.Size() // truncated/rotated — realign, don't replay
		return nil, nil
	case fi.Size() == t.offset:
		return nil, nil
	}

	if _, err := f.Seek(t.offset, io.SeekStart); err != nil {
		return nil, err
	}
	br := bufio.NewReaderSize(f, 128*1024)
	var out []Entry
	for {
		lineBytes, rerr := br.ReadBytes('\n')
		if len(lineBytes) > 0 && rerr == nil {
			t.offset += int64(len(lineBytes))
			if trimmed := bytes.TrimRight(lineBytes, "\r\n"); len(trimmed) > 0 {
				out = append(out, t.r.Normalize(trimmed)...)
			}
		}
		if rerr != nil {
			break // partial trailing line stays for the next poll
		}
	}
	return out, nil
}

// ring is a fixed-capacity ring buffer of entries keeping the last cap pushed.
type ring struct {
	buf  []Entry
	cap  int
	next int
	full bool
}

func newRing(c int) *ring {
	if c < 1 {
		c = 1
	}
	return &ring{buf: make([]Entry, c), cap: c}
}

// push stores e, returning true if it overwrote (evicted) an older entry.
func (r *ring) push(e Entry) (evicted bool) {
	evicted = r.full
	r.buf[r.next] = e
	r.next = (r.next + 1) % r.cap
	if r.next == 0 {
		r.full = true
	}
	return evicted
}

// slice returns the buffered entries oldest-to-newest.
func (r *ring) slice() []Entry {
	if !r.full {
		out := make([]Entry, r.next)
		copy(out, r.buf[:r.next])
		return out
	}
	out := make([]Entry, r.cap)
	n := copy(out, r.buf[r.next:])
	copy(out[n:], r.buf[:r.next])
	return out
}
