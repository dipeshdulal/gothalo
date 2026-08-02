package herdr

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeSocketServer accepts one connection, invokes handle with a reader over the
// request lines and the writer, then closes. Returns the socket path.
func fakeSocketServer(t *testing.T, handle func(dec *json.Decoder, w *bufio.Writer)) string {
	t.Helper()
	// Unix socket paths are capped (~104 bytes on macOS), so t.TempDir()'s deep
	// path can overflow; use a short dir directly under the system temp root.
	dir, err := os.MkdirTemp("", "h")
	if err != nil {
		t.Fatalf("mkdtemp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "s.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		handle(json.NewDecoder(bufio.NewReader(conn)), bufio.NewWriter(conn))
	}()
	return path
}

// TestSocketDoCorrelatesID drives SocketConn.Do against a fake server that emits
// a stray event line and a mismatched-id line before the real reply, proving Do
// skips both and returns only the result whose id matches its request.
func TestSocketDoCorrelatesID(t *testing.T) {
	path := fakeSocketServer(t, func(dec *json.Decoder, w *bufio.Writer) {
		var req socketRequest
		if err := dec.Decode(&req); err != nil {
			t.Errorf("decode request: %v", err)
			return
		}
		if req.Method != "pane.get" {
			t.Errorf("method = %q, want pane.get", req.Method)
		}
		// Noise the correlation must ignore: an event line, then a stale-id reply.
		w.WriteString(`{"event":"pane_created","data":{"pane_id":"wX:p9"}}` + "\n")
		w.WriteString(`{"id":"someone-else","result":{"nope":true}}` + "\n")
		// The real reply, keyed to the request's own id.
		w.WriteString(`{"id":"` + req.ID + `","result":{"pane":{"pane_id":"w1:p1"}}}` + "\n")
		w.Flush()
	})

	conn, err := DialSocket(path)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	result, err := conn.Do("pane.get", map[string]any{"pane_id": "w1:p1"})
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	if !json.Valid(result) || !strings.Contains(string(result), "w1:p1") {
		t.Fatalf("result = %s, want the matching-id pane payload", result)
	}
}

// TestSocketDoReturnsStructuredError proves an {"id","error"} reply surfaces as a
// *SocketError with its code/message parsed out.
func TestSocketDoReturnsStructuredError(t *testing.T) {
	path := fakeSocketServer(t, func(dec *json.Decoder, w *bufio.Writer) {
		var req socketRequest
		_ = dec.Decode(&req)
		w.WriteString(`{"id":"` + req.ID + `","error":{"code":"pane_not_found","message":"no pane wX:p9"}}` + "\n")
		w.Flush()
	})

	conn, err := DialSocket(path)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	_, err = conn.Do("pane.get", map[string]any{"pane_id": "wX:p9"})
	serr, ok := err.(*SocketError)
	if !ok {
		t.Fatalf("error = %T (%v), want *SocketError", err, err)
	}
	if serr.Code != "pane_not_found" {
		t.Errorf("code = %q, want pane_not_found", serr.Code)
	}
}
