package server

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestResolveProxySessionVerbatimForDefault(t *testing.T) {
	in := json.RawMessage(`{"workspace_id":"w5","extra":{"pane_id":"w5:p1"}}`)
	session, out, err := resolveProxySession("", in)
	if err != nil {
		t.Fatal(err)
	}
	if session != "" {
		t.Errorf("session = %q, want default", session)
	}
	if string(out) != string(in) {
		t.Errorf("default-session params must pass through verbatim: %s", out)
	}
}

func TestResolveProxySessionStripsAndInfers(t *testing.T) {
	in := json.RawMessage(`{"pane_id":"acme/w1:p2","workspace_id":"acme/w1"}`)
	session, out, err := resolveProxySession("", in)
	if err != nil {
		t.Fatal(err)
	}
	if session != "acme" {
		t.Errorf("session = %q, want acme", session)
	}
	if strings.Contains(string(out), "acme/") {
		t.Errorf("prefixes not stripped: %s", out)
	}
	if !strings.Contains(string(out), `"pane_id":"w1:p2"`) {
		t.Errorf("bare id missing: %s", out)
	}
}

func TestResolveProxySessionConflicts(t *testing.T) {
	if _, _, err := resolveProxySession("",
		json.RawMessage(`{"pane_id":"acme/w1:p2","tab_id":"wholesale/w1:t1"}`)); err == nil {
		t.Error("mixed sessions should error")
	}
	if _, _, err := resolveProxySession("wholesale",
		json.RawMessage(`{"pane_id":"acme/w1:p2"}`)); err == nil {
		t.Error("explicit session contradicting qualified ids should error")
	}
}

func TestResolveProxySessionExplicit(t *testing.T) {
	session, out, err := resolveProxySession("acme", json.RawMessage(`{"cwd":"/x"}`))
	if err != nil {
		t.Fatal(err)
	}
	if session != "acme" || string(out) != `{"cwd":"/x"}` {
		t.Errorf("got (%q, %s)", session, out)
	}
}
