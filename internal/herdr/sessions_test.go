package herdr

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestQualifyAndSplitTarget(t *testing.T) {
	cases := []struct {
		session, id, qualified string
	}{
		{"", "w1:p2", "w1:p2"},
		{"default", "w1:p2", "w1:p2"},
		{"acme", "w1:p2", "acme/w1:p2"},
		{"acme", "", ""},
	}
	for _, c := range cases {
		if got := Qualify(c.session, c.id); got != c.qualified {
			t.Errorf("Qualify(%q,%q) = %q, want %q", c.session, c.id, got, c.qualified)
		}
	}

	splits := []struct {
		target, session, id string
	}{
		{"w1:p2", "", "w1:p2"},
		{"acme/w1:p2", "acme", "w1:p2"},
		{"default/w1:p2", "", "w1:p2"},
	}
	for _, c := range splits {
		s, id := SplitTarget(c.target)
		if s != c.session || id != c.id {
			t.Errorf("SplitTarget(%q) = (%q,%q), want (%q,%q)", c.target, s, id, c.session, c.id)
		}
	}
}

func TestQualifyIDsWalksNestedPayloads(t *testing.T) {
	raw := `{
		"focused_pane_id": "w1:p1",
		"agents": [{"pane_id":"w1:p1","workspace_id":"w1","cwd":"/tmp/x"}],
		"layouts": [{"panes":[{"pane_id":"w1:p2"}],"area":{"x":1}}]
	}`
	var v any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		t.Fatal(err)
	}
	QualifyIDs(v, "acme")
	m := v.(map[string]any)
	if m["focused_pane_id"] != "acme/w1:p1" {
		t.Errorf("focused_pane_id = %v", m["focused_pane_id"])
	}
	agent := m["agents"].([]any)[0].(map[string]any)
	if agent["pane_id"] != "acme/w1:p1" || agent["workspace_id"] != "acme/w1" {
		t.Errorf("agent ids not qualified: %v", agent)
	}
	if agent["cwd"] != "/tmp/x" {
		t.Errorf("non-id field rewritten: %v", agent["cwd"])
	}
	layoutPane := m["layouts"].([]any)[0].(map[string]any)["panes"].([]any)[0].(map[string]any)
	if layoutPane["pane_id"] != "acme/w1:p2" {
		t.Errorf("nested layout pane not qualified: %v", layoutPane)
	}
}

func TestQualifyIDsDefaultSessionIsNoop(t *testing.T) {
	var v any
	_ = json.Unmarshal([]byte(`{"pane_id":"w1:p1"}`), &v)
	QualifyIDs(v, "")
	if !reflect.DeepEqual(v, map[string]any{"pane_id": "w1:p1"}) {
		t.Errorf("default session must not rewrite ids: %v", v)
	}
}

func TestManagerClientResolution(t *testing.T) {
	m := NewManager(nil)

	for _, name := range []string{"", "default"} {
		c, err := m.Client(name)
		if err != nil || c.Session() != "" {
			t.Errorf("Client(%q) = (%v, %v), want default client", name, c, err)
		}
	}

	if _, err := m.Client("nope"); err == nil || !IsNotFound(err) {
		t.Errorf("unknown session error should satisfy IsNotFound, got %v", err)
	}
}
