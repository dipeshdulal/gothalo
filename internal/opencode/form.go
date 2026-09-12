package opencode

import (
	"encoding/json"
	"net/url"
)

// Prompt types carried in Form.Metadata.Kind. The question tool sets
// "question"; a permission prompt travels the service's sibling permission
// API, which this package does not speak yet.
const FormKindQuestion = "question"

// Form is one prompt a session is waiting on, as the service projects it. It is
// the backing store for the question tool: the TUI renders these fields and
// replies through the same API gothalo uses, so reading it needs no screen
// scraping and no guessing at a footer's wording.
type Form struct {
	ID        string   `json:"id"`
	SessionID string   `json:"sessionID"`
	Title     string   `json:"title"`
	Metadata  Metadata `json:"metadata"`
	Fields    []Field  `json:"fields"`
}

// Metadata is the form's free-form origin. The question tool writes
// {"kind":"question","tool":{...}}; a form a plugin created may carry neither.
type Metadata struct {
	Kind string `json:"kind"`
	Tool struct {
		MessageID string `json:"messageID"`
		ID        string `json:"id"`
	} `json:"tool"`
}

// Field is one question. The question tool maps one input question to one field:
// Title is the short header, Description the full question, and Options the
// choices (value == label). Custom means the UI offers "Type your own answer" —
// the answer may then be free text rather than one of Options.
type Field struct {
	Key         string   `json:"key"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Type        string   `json:"type"` // "string" (single choice) | "multiselect" | …
	Options     []Option `json:"options"`
	Custom      bool     `json:"custom"`
}

// Option is one choice. Value is what a reply carries back; the question tool
// sets it equal to Label.
type Option struct {
	Value       string `json:"value"`
	Label       string `json:"label"`
	Description string `json:"description"`
}

// PendingForms lists the forms a session is waiting on, in the order the
// service reports them.
func (s Service) PendingForms(sessionID string) ([]Form, error) {
	body, err := s.Get("/api/session/" + url.PathEscape(sessionID) + "/form")
	if err != nil {
		return nil, err
	}
	var out struct {
		Data []Form `json:"data"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	return out.Data, nil
}

// Question returns the first pending question form, or nil when the session is
// not waiting on one. Other forms (a plugin's create form) are skipped: only
// the question tool's prompt is gothalo's to answer.
func (s Service) Question(sessionID string) (*Form, error) {
	forms, err := s.PendingForms(sessionID)
	if err != nil {
		return nil, err
	}
	for i := range forms {
		if forms[i].Metadata.Kind == FormKindQuestion {
			return &forms[i], nil
		}
	}
	return nil, nil
}

// ReplyForm answers a pending form. answer maps each field key ("q0", "q1", …)
// to its value: a string for a single choice, an array of strings for a
// multiselect. The service rejects a form that is already settled.
func (s Service) ReplyForm(sessionID, formID string, answer map[string]any) error {
	_, err := s.Post(
		"/api/session/"+url.PathEscape(sessionID)+"/form/"+url.PathEscape(formID)+"/reply",
		map[string]any{"answer": answer})
	return err
}

// CancelForm dismisses a pending form — the API equivalent of pressing Esc,
// which the question tool reports to the model as "The user dismissed this
// question".
func (s Service) CancelForm(sessionID, formID string) error {
	_, err := s.Post(
		"/api/session/"+url.PathEscape(sessionID)+"/form/"+url.PathEscape(formID)+"/cancel", nil)
	return err
}
