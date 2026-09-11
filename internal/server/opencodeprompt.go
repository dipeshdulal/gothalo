package server

import (
	"errors"
	"regexp"
	"strconv"
	"strings"

	"github.com/dipeshdulal/gothalo/internal/agentstate"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/opencode"
)

// OpenCode v2's question tool is not screen furniture to scrape: the agent's
// managed service owns the prompt as a *form* and accepts the answer over HTTP.
// gothalo therefore reads what an opencode pane is blocked on from the service
// rather than the terminal, and answers it through the same API. That is what
// makes the prompt answerable from the phone no matter how the TUI draws it —
// v2 changed the footer wording ("enter choose", "tab next") and defeated
// herdr's screen-detection manifest, so scraping the panel was never going to
// be stable.
//
// herdr still owns the *status*: its opencode integration reports blocked on
// question.asked. This file supplies only the "what", plus the answer path.

// opencodeQuestion returns the pending question form for an agent pane, when
// there is one. The service is returned alongside so a caller can reply without
// discovering it twice. A non-opencode pane, an absent service, or no pending
// question all return a nil form and no error.
func opencodeQuestion(agent herdr.Agent) (opencode.Service, *opencode.Form, error) {
	if agent.Kind != "opencode" {
		return opencode.Service{}, nil, nil
	}
	svc, err := opencode.Discover()
	if err != nil {
		return opencode.Service{}, nil, nil // no v2 service here is normal
	}
	sessionID, err := opencodeSession(svc, agent)
	if err != nil {
		// A session that is not (yet) registered is normal — the pane may have
		// just started — so it is a silent fallback, not a warning.
		if errors.Is(err, opencode.ErrNotFound) {
			return svc, nil, nil
		}
		return svc, nil, err
	}
	form, err := svc.Question(sessionID)
	if err != nil {
		if errors.Is(err, opencode.ErrNotFound) {
			return svc, nil, nil
		}
		return svc, nil, err
	}
	return svc, form, nil
}

// opencodeSession resolves the pane's OpenCode v2 session id: herdr's reported
// id when present (confirmed against the pane's cwd), else the newest top-level
// session at that cwd — the same rule the transcript reader uses when the
// integration has not reported a session id.
func opencodeSession(svc opencode.Service, agent herdr.Agent) (string, error) {
	if id := agent.SessionID(); id != "" {
		if err := svc.Verify(id, agent.Cwd); err != nil {
			return "", err
		}
		return id, nil
	}
	return svc.SessionForCwd(agent.Cwd)
}

// opencodeBlocked projects a pending question form onto the app's Blocked
// shape. A free-form answer is not an option here: the app's options sheet
// already carries a text field, and handleSend routes typed text to the form.
//
// Only a one-field form is projected. The question tool maps each input
// question to its own field and the app models one question at a time, so a
// multi-question prompt falls back to the screen parser (nil here) rather than
// hiding questions the phone cannot answer.
func opencodeBlocked(form *opencode.Form) *agentstate.Blocked {
	if form == nil || len(form.Fields) != 1 {
		return nil
	}
	field := form.Fields[0]
	question := strings.TrimSpace(field.Description)
	if question == "" {
		question = strings.TrimSpace(field.Title)
	}
	if question == "" && len(field.Options) == 0 {
		return nil
	}
	// The form's origin IS the semantic class, so name it: the app styles a
	// plain question neutrally instead of falling back to a permission look.
	b := &agentstate.Blocked{Question: question, Category: "question_panel"}
	for i, opt := range field.Options {
		label := strings.TrimSpace(opt.Label)
		if label == "" {
			label = strings.TrimSpace(opt.Value)
		}
		b.Options = append(b.Options, agentstate.Option{
			Index:    i + 1,
			Label:    label,
			Selected: i == 0,
		})
	}
	// The question dialog is dismissible with Esc; expose that the way the
	// screen parser does, as a keyed choice the app can send.
	b.Options = append(b.Options, agentstate.Option{Key: "esc", Label: "Dismiss"})
	return b
}

// opencodeChoiceRE matches the app's numbered-option wire form: POST /send with
// a bare menu number.
var opencodeChoiceRE = regexp.MustCompile(`^\d+$`)

// opencodeAnswer applies the app's own send conventions to a pending question
// form: a bare menu number picks that option, and any other text is the
// free-form "Type your own answer" when the form offers one. It reports whether
// it answered, so the caller can fall back to typing into the pane.
func opencodeAnswer(svc opencode.Service, form *opencode.Form, text string) bool {
	if form == nil || len(form.Fields) != 1 {
		return false
	}
	field := form.Fields[0]
	answer := strings.TrimRight(text, "\r\n")
	if opencodeChoiceRE.MatchString(answer) {
		n, err := strconv.Atoi(answer)
		if err != nil || n < 1 || n > len(field.Options) {
			return false
		}
		return svc.ReplyForm(form.SessionID, form.ID,
			map[string]any{field.Key: opencodeValue(field, field.Options[n-1].Value)}) == nil
	}
	if !field.Custom {
		return false
	}
	return svc.ReplyForm(form.SessionID, form.ID,
		map[string]any{field.Key: opencodeValue(field, answer)}) == nil
}

// opencodeValue shapes a reply for the field's type: a multiselect expects an
// array even for one choice, a single choice wants the bare string. The question
// tool accepts either shape when reading, but its schema validation does not.
func opencodeValue(field opencode.Field, value string) any {
	if field.Type == "multiselect" {
		return []string{value}
	}
	return value
}

// opencodeDefault answers a question with its first option — the highlighted
// default a bare Enter (POST /approve) accepts. It reports whether it answered.
func opencodeDefault(svc opencode.Service, form *opencode.Form) bool {
	if form == nil || len(form.Fields) != 1 || len(form.Fields[0].Options) == 0 {
		return false
	}
	field := form.Fields[0]
	return svc.ReplyForm(form.SessionID, form.ID,
		map[string]any{field.Key: opencodeValue(field, field.Options[0].Value)}) == nil
}
