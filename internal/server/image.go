package server

import (
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/imagedrop"
)

// POST /image?pane=<pane_id> — body is the raw image bytes — writes the image
// into that agent's working directory and returns the absolute path it wrote.
//
// The only uniquely-mobile feature on the roadmap: a screenshot or camera roll
// photo becomes something an agent can look at. The trick is that no agent
// protocol is involved — coding agents read an image when handed a path, so the
// bridge's whole job is to put the bytes inside the agent's tree and answer with
// the path. The app inserts that path into the composer WITHOUT sending, so the
// user can write the actual prompt around it ("why is this button misaligned?").
//
// The wire format is raw bytes, not multipart, on purpose: multipart exists to
// carry field names and filenames, and a filename is the one thing this endpoint
// must never accept. Nothing about the written file is client-controlled — the
// pane picks the directory, the sniffed content type picks the extension, and
// the bridge picks the name (see internal/imagedrop).
//
// Validation runs before the Herdr round-trip, so an oversized or non-image body
// is rejected without touching the socket.
func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	pane := r.URL.Query().Get("pane")
	if pane == "" {
		http.Error(w, "want ?pane=<pane_id>", http.StatusBadRequest)
		return
	}

	// A declared length over the cap is refusable without reading a byte. Worth
	// the extra branch: the alternative is buffering however many megabytes a
	// phone decided to send only to throw them away, and the app always sets
	// Content-Length (it uploads a byte list, not a stream), so this is the path
	// an oversized upload actually takes. The LimitReader below still has to
	// exist — a chunked body declares no length at all.
	if r.ContentLength > imagedrop.MaxBytes {
		http.Error(w, imagedrop.ErrTooLarge.Error(), http.StatusRequestEntityTooLarge)
		return
	}

	// Read one byte past the cap so "exactly at the limit" and "over it" are
	// distinguishable; a LimitReader (rather than http.MaxBytesReader) keeps the
	// response ours to write instead of the connection being torn down.
	data, err := io.ReadAll(io.LimitReader(r.Body, imagedrop.MaxBytes+1))
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if _, _, err := imagedrop.Detect(data); err != nil {
		http.Error(w, err.Error(), imageErrorStatus(err))
		return
	}

	cwd, status, err := s.paneCwd(pane)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}

	res, err := imagedrop.Save(cwd, data, time.Now())
	if err != nil {
		log.Warn("image: save failed", "pane", pane, "cwd", cwd, "err", err)
		http.Error(w, err.Error(), imageErrorStatus(err))
		return
	}

	log.Info("image dropped", "pane", pane, "path", res.Path, "bytes", res.Bytes, "type", res.ContentType)
	writeJSON(w, res)
}

// imageErrorStatus maps an imagedrop failure to its status: too large is a 413,
// a body that isn't one of the four accepted image formats a 415, an empty body
// a 400, and anything else (an unwritable directory, an agent with no resolvable
// cwd) a 500 — the bridge's own problem, not the request's.
func imageErrorStatus(err error) int {
	switch {
	case errors.Is(err, imagedrop.ErrEmpty):
		return http.StatusBadRequest
	case errors.Is(err, imagedrop.ErrTooLarge):
		return http.StatusRequestEntityTooLarge
	case errors.Is(err, imagedrop.ErrUnsupported):
		return http.StatusUnsupportedMediaType
	default:
		return http.StatusInternalServerError
	}
}
