package transcript

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestNormalizeOpencodeV2(t *testing.T) {
	raw := `{"id":"msg_1","type":"assistant","time":{"created":1700000000000},"content":[{"type":"reasoning","text":"think"},{"type":"text","text":"hello"},{"type":"tool","id":"call_1","name":"bash","state":{"status":"completed","input":{"command":"pwd"},"content":[{"type":"text","text":"/tmp"}]}}]}`
	got := normalizeOpencodeV2Message([]byte(raw))
	if len(got) != 4 {
		t.Fatalf("entries = %d, want 4", len(got))
	}
	if got[0].Kind != KindThinking || got[1].Text != "hello" {
		t.Fatalf("entries = %+v", got)
	}
	if got[2].Tool == nil || got[2].Tool.ID != "call_1" || got[2].Tool.Command != "pwd" {
		t.Fatalf("tool = %+v", got[2].Tool)
	}
	if got[3].Result == nil || got[3].Result.ForID != "call_1" || got[3].Result.OutputSummary != "/tmp" {
		t.Fatalf("result = %+v", got[3].Result)
	}
}

func TestOpenOpencodeV2Service(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	state := filepath.Join(os.Getenv("HOME"), ".local", "state", "opencode")
	if err := os.MkdirAll(state, 0700); err != nil {
		t.Fatal(err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/session/ses_test" {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"location": map[string]string{"directory": "/tmp/project"}}})
			return
		}
		if r.URL.Path == "/api/session/ses_test/message" {
			w.Header().Set("Content-Type", "application/json")
			if r.URL.Query().Get("cursor") == "page-2" {
				json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{
					"id": "msg_2", "type": "assistant", "time": map[string]int64{"created": 1700000001000},
					"content": []any{map[string]any{"type": "text", "text": "world"}},
				}}, "cursor": map[string]any{"next": nil}})
				return
			}
			if got := r.URL.Query().Get("limit"); got != "" {
				t.Errorf("initial message request set limit=%q; use the server default", got)
			}
			json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{
				"id": "msg_1", "type": "user", "time": map[string]int64{"created": 1700000000000}, "text": "hello",
			}}, "cursor": map[string]any{"next": "page-2"}})
			return
		}
		http.NotFound(w, r)
	}))
	defer server.Close()
	service, _ := json.Marshal(map[string]string{"url": server.URL, "password": "secret"})
	if err := os.WriteFile(filepath.Join(state, "service.json"), service, 0600); err != nil {
		t.Fatal(err)
	}

	src, err := openOpencodeV2Source("/tmp/project", "ses_test")
	if err != nil {
		t.Fatal(err)
	}
	b, err := src.Backlog(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Entries) != 2 || b.Entries[0].Text != "hello" || b.Entries[1].Text != "world" {
		t.Fatalf("backlog = %+v", b)
	}
}

func TestNormalizeOpencodeV2SystemAndShell(t *testing.T) {
	system := `{"id":"msg_sys","type":"system","time":{"created":1700000000000},"text":"context loaded"}`
	got := normalizeOpencodeV2Message([]byte(system))
	if len(got) != 1 || got[0].Role != RoleSystem || got[0].Text != "context loaded" {
		t.Fatalf("system = %+v", got)
	}

	shell := `{"id":"msg_sh","type":"shell","time":{"created":1700000001000},"callID":"call_sh","command":"ls -la","output":"total 0\n"}`
	got = normalizeOpencodeV2Message([]byte(shell))
	if len(got) != 2 {
		t.Fatalf("shell entries = %d, want 2 (%+v)", len(got), got)
	}
	if got[0].Kind != KindToolCall || got[0].Tool == nil || got[0].Tool.Command != "ls -la" {
		t.Fatalf("shell call = %+v", got[0].Tool)
	}
	if got[1].Kind != KindToolResult || got[1].Result == nil || got[1].Result.OutputSummary == "" {
		t.Fatalf("shell result = %+v", got[1].Result)
	}
}

// TestOpencodeV2PollStreamsCompletionAndNewMessages drives the source through a
// live-ish sequence: a running assistant turn that finishes and gains a block,
// followed by a new user message. Poll must emit only the block it has not sent
// before plus the new message — never the blocks already delivered by Backlog.
func TestOpencodeV2PollStreamsCompletionAndNewMessages(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	state := filepath.Join(os.Getenv("HOME"), ".local", "state", "opencode")
	if err := os.MkdirAll(state, 0700); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	msgs := []map[string]any{
		{"id": "msg_1", "type": "user", "time": map[string]any{"created": 1}, "text": "hi"},
		{"id": "msg_2", "type": "assistant", "time": map[string]any{"created": 2},
			"content": []any{map[string]any{"type": "text", "text": "par"}}},
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/session/ses_test":
			json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
				"location": map[string]string{"directory": "/tmp/project"}}})
		case "/api/session/ses_test/message":
			mu.Lock()
			all := append([]map[string]any(nil), msgs...)
			mu.Unlock()
			if r.URL.Query().Get("order") == "desc" {
				for i, j := 0, len(all)-1; i < j; i, j = i+1, j-1 {
					all[i], all[j] = all[j], all[i]
				}
			}
			json.NewEncoder(w).Encode(map[string]any{"data": all, "cursor": map[string]any{"next": nil}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	service, _ := json.Marshal(map[string]string{"url": server.URL, "password": "secret"})
	if err := os.WriteFile(filepath.Join(state, "service.json"), service, 0600); err != nil {
		t.Fatal(err)
	}

	src, err := openOpencodeV2Source("/tmp/project", "ses_test")
	if err != nil {
		t.Fatal(err)
	}
	b, err := src.Backlog(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Entries) != 2 || b.Total != 2 {
		t.Fatalf("backlog = %+v", b)
	}

	// Nothing new yet: the same running turn must not re-emit.
	if got, err := src.Poll(); err != nil || len(got) != 0 {
		t.Fatalf("quiet poll = %+v, %v; want empty", got, err)
	}

	// The turn finishes with an extra block and the user replies.
	mu.Lock()
	msgs[1] = map[string]any{"id": "msg_2", "type": "assistant",
		"time": map[string]any{"created": 2, "completed": 3},
		"content": []any{
			map[string]any{"type": "text", "text": "par"},
			map[string]any{"type": "text", "text": "tial"},
		}}
	msgs = append(msgs, map[string]any{"id": "msg_3", "type": "user",
		"time": map[string]any{"created": 4}, "text": "next"})
	mu.Unlock()

	got, err := src.Poll()
	if err != nil {
		t.Fatal(err)
	}
	var texts []string
	for _, e := range got {
		texts = append(texts, e.Text)
	}
	if len(got) != 2 || texts[0] != "tial" || texts[1] != "next" {
		t.Fatalf("poll = %+v (texts %v); want [tial next]", got, texts)
	}
}

// TestOpenOpencodeV2ResolvesByCwdWhenSessionIDMissing covers the pane whose
// herdr integration never reported a session id: the service is asked for the
// newest session at the pane's cwd instead of 404ing.
func TestOpenOpencodeV2ResolvesByCwdWhenSessionIDMissing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	state := filepath.Join(os.Getenv("HOME"), ".local", "state", "opencode")
	if err := os.MkdirAll(state, 0700); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/session":
			json.NewEncoder(w).Encode(map[string]any{"data": []any{
				map[string]any{"id": "ses_new", "location": map[string]string{"directory": "/tmp/project"}},
				map[string]any{"id": "ses_other", "location": map[string]string{"directory": "/tmp/elsewhere"}},
			}})
		case "/api/session/ses_new/message":
			json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{
				"id": "msg_1", "type": "user", "time": map[string]int64{"created": 1}, "text": "hi",
			}}, "cursor": map[string]any{"next": nil}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	service, _ := json.Marshal(map[string]string{"url": server.URL, "password": "secret"})
	if err := os.WriteFile(filepath.Join(state, "service.json"), service, 0600); err != nil {
		t.Fatal(err)
	}

	src, err := openOpencodeV2Source("/tmp/project", "")
	if err != nil {
		t.Fatal(err)
	}
	b, err := src.Backlog(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Entries) != 1 || b.Entries[0].Text != "hi" {
		t.Fatalf("backlog = %+v", b)
	}
}

func TestOpencodeV2RejectsWrongCwd(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	state := filepath.Join(os.Getenv("HOME"), ".local", "state", "opencode")
	if err := os.MkdirAll(state, 0700); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
			"location": map[string]string{"directory": "/tmp/project"}}})
	}))
	defer server.Close()
	service, _ := json.Marshal(map[string]string{"url": server.URL, "password": "secret"})
	if err := os.WriteFile(filepath.Join(state, "service.json"), service, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := openOpencodeV2Source("/tmp/other", "ses_test"); err != ErrNoTranscript {
		t.Fatalf("wrong cwd error = %v, want ErrNoTranscript", err)
	}
}
