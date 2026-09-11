package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/opencode"
)

// TestOpencodeBlockedProjectsSingleQuestion pins the projection: the actual
// question text comes from the field description, choices carry their display
// order, the first is the default, and Esc rides as a keyed dismiss.
func TestOpencodeBlockedProjectsSingleQuestion(t *testing.T) {
	form := &opencode.Form{
		ID: "frm_1", SessionID: "ses_1",
		Fields: []opencode.Field{{
			Key:         "q0",
			Title:       "Storage",
			Description: "Which storage should we use?",
			Options: []opencode.Option{
				{Value: "SQLite", Label: "SQLite"},
				{Value: "JSONL", Label: "A JSONL file"},
			},
			Custom: true,
		}},
	}

	b := opencodeBlocked(form)
	if b == nil {
		t.Fatal("Blocked = nil, want the projected question")
	}
	if b.Question != "Which storage should we use?" {
		t.Errorf("Question = %q", b.Question)
	}
	if b.Category != "question_panel" {
		t.Errorf("Category = %q, want question_panel", b.Category)
	}
	if len(b.Options) != 3 {
		t.Fatalf("options = %+v, want 2 choices + esc", b.Options)
	}
	if b.Options[0].Index != 1 || b.Options[0].Label != "SQLite" || !b.Options[0].Selected {
		t.Errorf("option 1 = %+v, want the selected default", b.Options[0])
	}
	if b.Options[1].Index != 2 || b.Options[1].Selected {
		t.Errorf("option 2 = %+v", b.Options[1])
	}
	if b.Options[2].Key != "esc" || b.Options[2].Index != 0 {
		t.Errorf("last option = %+v, want the keyed esc dismiss", b.Options[2])
	}
}

// TestOpencodeBlockedFallsBack: a form the app cannot model (multi-question,
// empty) yields nil so the screen parser keeps its turn.
func TestOpencodeBlockedFallsBack(t *testing.T) {
	cases := map[string]*opencode.Form{
		"nil":       nil,
		"no fields": {ID: "frm", Fields: nil},
		"multi":     {ID: "frm", Fields: []opencode.Field{{Key: "q0"}, {Key: "q1"}}},
		"empty":     {ID: "frm", Fields: []opencode.Field{{Key: "q0"}}},
	}
	for name, form := range cases {
		if got := opencodeBlocked(form); got != nil {
			t.Errorf("%s: Blocked = %+v, want nil", name, got)
		}
	}
}

// TestOpencodeAnswerRepliesOverAPI drives both app conventions — a bare menu
// number and free-form text — through the service's reply endpoint.
func TestOpencodeAnswerRepliesOverAPI(t *testing.T) {
	var answers []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/session/ses_1/form/frm_1/reply" {
			http.NotFound(w, r)
			return
		}
		var body struct {
			Answer map[string]any `json:"answer"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		answers = append(answers, body.Answer)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	svc := opencode.Service{URL: srv.URL, Password: "secret"}
	form := &opencode.Form{ID: "frm_1", SessionID: "ses_1", Fields: []opencode.Field{{
		Key:     "q0",
		Custom:  true,
		Options: []opencode.Option{{Value: "SQLite"}, {Value: "JSONL"}},
	}}}

	if !opencodeAnswer(svc, form, "2\n") {
		t.Fatal("numbered choice was not answered")
	}
	if !opencodeAnswer(svc, form, "neither, use Postgres\r") {
		t.Fatal("free-form answer was not answered")
	}
	if len(answers) != 2 {
		t.Fatalf("replies = %d, want 2", len(answers))
	}
	if answers[0]["q0"] != "JSONL" {
		t.Errorf("numbered reply = %+v, want the 2nd option's value", answers[0])
	}
	if answers[1]["q0"] != "neither, use Postgres" {
		t.Errorf("free-form reply = %+v", answers[1])
	}
}

// TestOpencodeAnswerMultiselectSendsArray: a multiselect field validates an
// array even for a single choice.
func TestOpencodeAnswerMultiselectSendsArray(t *testing.T) {
	var answer map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Answer map[string]any `json:"answer"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		answer = body.Answer
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	svc := opencode.Service{URL: srv.URL, Password: "secret"}
	form := &opencode.Form{ID: "frm_1", SessionID: "ses_1", Fields: []opencode.Field{{
		Key: "q0", Type: "multiselect", Custom: true,
		Options: []opencode.Option{{Value: "A"}, {Value: "B"}},
	}}}
	if !opencodeAnswer(svc, form, "1\n") {
		t.Fatal("multiselect choice was not answered")
	}
	arr, ok := answer["q0"].([]any)
	if !ok || len(arr) != 1 || arr[0] != "A" {
		t.Errorf("multiselect reply = %#v, want [A]", answer["q0"])
	}
}

// TestOpencodeAnswerIgnoresOutOfRange guards the fallback: a number the form
// has no choice for is not answered here, so handleSend still types it.
func TestOpencodeAnswerIgnoresOutOfRange(t *testing.T) {
	svc := opencode.Service{URL: "http://127.0.0.1:0", Password: "x"}
	form := &opencode.Form{ID: "frm_1", SessionID: "ses_1", Fields: []opencode.Field{{
		Key: "q0", Options: []opencode.Option{{Value: "only"}},
	}}}
	if opencodeAnswer(svc, form, "9\n") {
		t.Error("out-of-range choice was answered")
	}
}

// TestOpencodeDefaultPicksFirstChoice pins the /approve mapping.
func TestOpencodeDefaultPicksFirstChoice(t *testing.T) {
	var answer map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Answer map[string]any `json:"answer"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		answer = body.Answer
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	svc := opencode.Service{URL: srv.URL, Password: "secret"}
	form := &opencode.Form{ID: "frm_1", SessionID: "ses_1", Fields: []opencode.Field{{
		Key:     "q0",
		Options: []opencode.Option{{Value: "SQLite"}, {Value: "JSONL"}},
	}}}
	if !opencodeDefault(svc, form) {
		t.Fatal("default was not answered")
	}
	if answer["q0"] != "SQLite" {
		t.Errorf("default answer = %+v, want the first choice", answer)
	}
}

// TestOpencodeQuestionNonOpencodeIsNil: other kinds never touch the service.
func TestOpencodeQuestionNonOpencodeIsNil(t *testing.T) {
	if _, form, err := opencodeQuestion(herdr.Agent{Kind: "claude"}); err != nil || form != nil {
		t.Errorf("claude: form=%v err=%v, want nil/nil", form, err)
	}
}
