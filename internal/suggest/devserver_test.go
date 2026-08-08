package suggest

import (
	"strings"
	"testing"
)

// TestDevServerOffersTheURL is the case the whole preview feature exists for:
// a reachable server becomes a chip that opens the phone's browser.
func TestDevServerOffersTheURL(t *testing.T) {
	got := For(Pane{ID: "w1:p2", Servers: []Server{
		{Port: 5173, Proc: "node", URL: "http://100.84.12.3:5173"},
	}})
	if len(got) != 1 {
		t.Fatalf("suggestions = %v, want one", kinds(got))
	}
	s := got[0]
	if s.Kind != KindDevServer || s.Action != ActionOpenURL {
		t.Errorf("suggestion = %+v, want a dev_server/open_url", s)
	}
	if s.Label != "Open :5173" {
		t.Errorf("label = %q, want the port", s.Label)
	}
	if s.Detail != "node · serving" {
		t.Errorf("detail = %q, want the process named", s.Detail)
	}
	// The url is the entire payload of the action — a chip without it is a dead
	// button, which is the one thing this surface must never render.
	if s.Params["url"] != "http://100.84.12.3:5173" {
		t.Errorf("params[url] = %q, want the scan's url verbatim", s.Params["url"])
	}
	if s.Params["pane"] != "w1:p2" {
		t.Errorf("params[pane] = %q, want the pane id", s.Params["pane"])
	}
}

// TestLoopbackServerExplainsItself: a server bound to 127.0.0.1 is genuinely
// up, and "vite is on :5174, it's just on localhost" is the answer the user is
// looking for when the preview chip they expected isn't there. It must not be
// hidden, and it must not be a chip that does nothing.
func TestLoopbackServerExplainsItself(t *testing.T) {
	got := For(Pane{ID: "w1:p2", Servers: []Server{
		{Port: 5174, Proc: "node", Loopback: true},
	}})
	if len(got) != 1 {
		t.Fatalf("suggestions = %v, want one", kinds(got))
	}
	s := got[0]
	if s.Kind != KindDevServerLocal || s.Action != ActionShowNote {
		t.Errorf("suggestion = %+v, want a dev_server_local/show_note", s)
	}
	if s.Params["url"] != "" {
		t.Error("a loopback server must never carry a url — it cannot connect")
	}
	// The note has to name the fix, not just restate the chip.
	if note := s.Params["note"]; !strings.Contains(note, "--host") {
		t.Errorf("note = %q, want it to name the fix", note)
	}
}

// A listener the scan could not build a URL for is treated as loopback, not as
// a reachable server. FillURLs leaves the URL empty when the bridge is bound to
// every interface and has no single address to hand out, and a chip that opens
// "" is worse than one that explains itself.
func TestMissingURLIsTreatedAsUnreachable(t *testing.T) {
	got := For(Pane{ID: "w1:p2", Servers: []Server{{Port: 3000, Proc: "node"}}})
	if len(got) != 1 || got[0].Kind != KindDevServerLocal {
		t.Fatalf("suggestions = %v, want dev_server_local for a url-less listener", kinds(got))
	}
}

// TestDevServerChipsAreCapped: a pane running a whole stack must not turn the
// row into a port directory and push out the chips that need a person.
func TestDevServerChipsAreCapped(t *testing.T) {
	servers := []Server{
		{Port: 3000, Proc: "node", URL: "http://h:3000"},
		{Port: 4000, Proc: "node", URL: "http://h:4000"},
		{Port: 5000, Proc: "node", URL: "http://h:5000"},
		{Port: 6000, Proc: "node", URL: "http://h:6000"},
	}
	got := devServers(Pane{ID: "w1:p2", Servers: servers})
	if len(got) != maxDevServerChips {
		t.Fatalf("got %d chips from one source, want the cap of %d", len(got), maxDevServerChips)
	}
	// Kept in scan order (ascending port), not reordered by rank — a lower port
	// is not a better server, and reordering on restart would move the chip
	// under the thumb.
	if got[0].Label != "Open :3000" || got[1].Label != "Open :4000" {
		t.Errorf("labels = %q,%q, want the scan's order preserved", got[0].Label, got[1].Label)
	}
}

// TestConflictOutranksDevServer pins the one ordering question the merge of the
// two mechanisms created: when a pane is both serving and stuck, the thing that
// needs a person comes first.
func TestConflictOutranksDevServer(t *testing.T) {
	g := repo()
	g.Operation = "merge"

	got := For(Pane{
		ID: "w1:p1", HasAgent: true, Git: g,
		Servers: []Server{{Port: 5173, Proc: "node", URL: "http://h:5173"}},
	})
	if len(got) != 2 {
		t.Fatalf("suggestions = %v, want the conflict and the server", kinds(got))
	}
	if got[0].Kind != KindGitConflict || got[1].Kind != KindDevServer {
		t.Errorf("order = %v, want the conflict first", kinds(got))
	}
}

// TestDevServerOutranksDirtyTree: a server you came here to look at beats a
// diff you came here to read. Both are useful; only one of them is why you
// opened the pane while it was serving.
func TestDevServerOutranksDirtyTree(t *testing.T) {
	g := repo()
	g.Branch = g.DefaultBranch // keep create_pr out of this comparison
	g.Ahead, g.Dirty, g.Changed = 0, true, 1

	got := For(Pane{
		ID: "w1:p1", HasAgent: true, Git: g,
		Servers: []Server{{Port: 5173, Proc: "node", URL: "http://h:5173"}},
	})
	if len(got) != 2 || got[0].Kind != KindDevServer || got[1].Kind != KindGitDirty {
		t.Fatalf("order = %v, want the dev server first", kinds(got))
	}
}

// A plain pane with a dev server in it is the common shape — the server runs in
// a pane split off beside the agent — so it must produce a chip with no agent
// anywhere in sight.
func TestDevServerNeedsNoAgent(t *testing.T) {
	got := For(Pane{ID: "w1:p3", Servers: []Server{
		{Port: 8080, Proc: "python3", URL: "http://h:8080"},
	}})
	if len(got) != 1 || got[0].Action != ActionOpenURL {
		t.Fatalf("suggestions = %v, want an open_url for a plain pane", kinds(got))
	}
}

// No servers, no chips: the scan failing and the pane simply not serving are
// the same answer here, which is what keeps a missing `lsof` from costing a
// pane its other suggestions.
func TestNoServersNoChips(t *testing.T) {
	if got := devServers(Pane{ID: "w1:p2"}); len(got) != 0 {
		t.Errorf("suggestions = %v, want none", kinds(got))
	}
	if got := devServers(Pane{ID: "w1:p2", Servers: []Server{{Port: 0}}}); len(got) != 0 {
		t.Errorf("suggestions = %v, want a portless listener ignored", kinds(got))
	}
}

// ---- the relay ----
//
// A loopback-bound server used to be an explanation. The bridge runs on the
// host, so it can dial 127.0.0.1 when the phone cannot; these pin the three
// outcomes that now exist and, above all, that the DIRECT path is unaffected.

// TestRelayedLoopbackServerBecomesALink is what the relay bought.
func TestRelayedLoopbackServerBecomesALink(t *testing.T) {
	got := For(Pane{ID: "w1:p2", Servers: []Server{{
		Port: 8124, Proc: "node", Loopback: true, Relayed: true,
		URL: "http://host.ts.net:54321/?gothalo_preview=abc",
	}}})
	s := only(t, got, KindDevServerLocal)

	if s.Action != ActionOpenURL {
		t.Errorf("action = %q, want %q — the chip is a link now", s.Action, ActionOpenURL)
	}
	if s.Label != "Open :8124" {
		t.Errorf("label = %q, want the server's own port", s.Label)
	}
	if s.Detail != "node · via the bridge" {
		t.Errorf("detail = %q, want the extra hop said out loud", s.Detail)
	}
	if s.Params["url"] == "" {
		t.Error("no url — the chip would be a dead button")
	}
	// The explanation survives: a user who would rather rebind than proxy still
	// wants to know about --host.
	note := s.Params["note"]
	if !strings.Contains(note, "--host") {
		t.Errorf("note = %q, want it to still name the fix", note)
	}
	if !strings.Contains(note, "relaying") {
		t.Errorf("note = %q, want it to say what is actually happening", note)
	}
}

// TestDirectServerIsNeverRelayed is the no-regression guarantee. A server
// already bound wide must keep its direct URL: relaying it would add a hop, a
// listener and a token exchange to reach something the phone can already dial.
func TestDirectServerIsNeverRelayed(t *testing.T) {
	got := For(Pane{ID: "w1:p2", Servers: []Server{
		{Port: 5173, Proc: "node", URL: "http://host.ts.net:5173"},
	}})
	s := only(t, got, KindDevServer)
	if s.Params["url"] != "http://host.ts.net:5173" {
		t.Errorf("url = %q, want the direct one untouched", s.Params["url"])
	}
	if s.Rank != RankDevServer {
		t.Errorf("rank = %d, want the direct rank %d", s.Rank, RankDevServer)
	}
	if s.Params["note"] != "" {
		t.Errorf("a directly reachable server carries a note (%q) — nothing to explain",
			s.Params["note"])
	}
}

// No relay could be opened: back to explaining the bind, exactly as before.
func TestUnrelayedLoopbackServerStillExplainsItself(t *testing.T) {
	got := For(Pane{ID: "w1:p2", Servers: []Server{{Port: 8124, Proc: "node", Loopback: true}}})
	s := only(t, got, KindDevServerLocal)
	if s.Action != ActionShowNote {
		t.Errorf("action = %q, want %q when there is no relay", s.Action, ActionShowNote)
	}
	if s.Params["url"] != "" {
		t.Errorf("url = %q, want none", s.Params["url"])
	}
	if !strings.Contains(s.Params["note"], "--host") {
		t.Errorf("note = %q, want it to name the fix", s.Params["note"])
	}
}

// A relayed chip ranks below a direct one, so a pane serving both puts the
// faster path first.
func TestDirectOutranksRelayed(t *testing.T) {
	got := For(Pane{ID: "w1:p2", Servers: []Server{
		{Port: 5173, Proc: "node", URL: "http://host.ts.net:5173"},
		{Port: 8124, Proc: "node", Loopback: true, Relayed: true, URL: "http://host.ts.net:54321/"},
	}})
	if len(got) != 2 {
		t.Fatalf("suggestions = %v, want both servers", kinds(got))
	}
	if got[0].Kind != KindDevServer || got[1].Kind != KindDevServerLocal {
		t.Errorf("order = %v, want the direct server first", kinds(got))
	}
}
