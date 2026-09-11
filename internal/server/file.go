package server

import (
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/imagedrop"
)

// POST /file?pane=<pane_id> — body is the raw document bytes — writes a
// document (pdf, docx, pptx) into that pane's working directory and returns
// the absolute path it wrote.
//
// The image mechanism, applied to documents: a spec PDF or a slide deck
// becomes something an agent can read the moment its path is inside the
// agent's tree, so this handler is POST /image with a different allowlist, a
// different drop directory (.gothalo/files), and a larger cap — documents run
// bigger than screenshots. Everything structural is shared with handleImage;
// see that handler and internal/imagedrop for the reasoning.
//
// The wire format is raw bytes for the same reason as /image: a filename is
// the one thing this endpoint must never accept. A zip is stored as .docx
// because of the Word parts inside it, never because of what it was called.
func (s *Server) handleFile(w http.ResponseWriter, r *http.Request) {
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

	// A declared length over the cap is refusable without reading a byte —
	// same reasoning as /image, and more valuable here where the cap is 25 MiB.
	if r.ContentLength > imagedrop.MaxDocumentBytes {
		http.Error(w, imagedrop.ErrDocumentTooLarge.Error(), http.StatusRequestEntityTooLarge)
		return
	}

	// One byte past the cap keeps "exactly at the limit" and "over it"
	// distinguishable; the LimitReader keeps the response ours to write.
	data, err := io.ReadAll(io.LimitReader(r.Body, imagedrop.MaxDocumentBytes+1))
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if _, _, err := imagedrop.DetectDocument(data); err != nil {
		http.Error(w, err.Error(), fileErrorStatus(err))
		return
	}

	cwd, status, err := s.paneDropCwd(pane)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}

	res, err := imagedrop.SaveDocument(cwd, data, time.Now())
	if err != nil {
		log.Warn("file: save failed", "pane", pane, "cwd", cwd, "err", err)
		http.Error(w, err.Error(), fileErrorStatus(err))
		return
	}

	log.Info("file dropped", "pane", pane, "path", res.Path, "bytes", res.Bytes, "type", res.ContentType)
	writeJSON(w, res)
}

// fileErrorStatus maps a document drop failure to its status, mirroring
// imageErrorStatus: too large is a 413, a body that isn't an accepted document
// a 415, an empty body a 400, anything else a 500.
func fileErrorStatus(err error) int {
	switch {
	case errors.Is(err, imagedrop.ErrEmpty):
		return http.StatusBadRequest
	case errors.Is(err, imagedrop.ErrDocumentTooLarge):
		return http.StatusRequestEntityTooLarge
	case errors.Is(err, imagedrop.ErrUnsupportedDocument):
		return http.StatusUnsupportedMediaType
	default:
		return http.StatusInternalServerError
	}
}
