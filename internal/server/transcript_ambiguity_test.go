package server

import (
	"testing"

	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// A transcript is resolved by the agent's session id, and falls back to matching
// on working directory when there is none. The fallback cannot fail loudly — it
// returns the newest transcript in the directory, which is the WRONG agent's
// conversation whenever two agents share a directory.
//
// Observed live, three times: an agent started in a directory Claude had not
// trusted parked on a permission prompt, so it had no session id, and the phone
// was served an unrelated agent's 259-message history. The first agent in a new
// directory is exactly when that prompt appears.

func agentAt(pane, cwd, session string) herdr.Agent {
	return herdr.Agent{
		PaneID: pane,
		Cwd:    cwd,
		AgentSession: herdr.AgentSession{
			Value: session,
		},
	}
}

func agentKindAt(pane, kind, cwd, session string) herdr.Agent {
	a := agentAt(pane, cwd, session)
	a.Kind = kind
	return a
}

func TestSiblingInSameCwd(t *testing.T) {
	cases := []struct {
		name        string
		agents      []herdr.Agent
		subject     herdr.Agent
		wantAmbig   bool
		wantSibling string
	}{
		{
			// The live failure: no session id yet, another agent in the same
			// directory. Resolution would coin-flip between two transcripts.
			name: "no session id and a sibling shares the cwd",
			agents: []herdr.Agent{
				agentAt("w4:pJ", "/Users/d", "b711dd17"),
				agentAt("w4:pT", "/Users/d", ""),
			},
			subject:     agentAt("w4:pT", "/Users/d", ""),
			wantAmbig:   true,
			wantSibling: "w4:pJ",
		},
		{
			// A known session id resolves exactly; a sibling is irrelevant and
			// must not cost the operator their transcript.
			name: "session id known, sibling present",
			agents: []herdr.Agent{
				agentAt("w4:pJ", "/Users/d", "b711dd17"),
				agentAt("w4:pT", "/Users/d", "8849a13a"),
			},
			subject:   agentAt("w4:pT", "/Users/d", "8849a13a"),
			wantAmbig: false,
		},
		{
			// No session id, but alone in its directory: the cwd fallback has
			// exactly one candidate and is safe. This is the legitimate
			// no-integration case and must keep working.
			name: "no session id, alone in the cwd",
			agents: []herdr.Agent{
				agentAt("w4:pJ", "/Users/elsewhere", "b711dd17"),
				agentAt("w4:pT", "/Users/d", ""),
			},
			subject:   agentAt("w4:pT", "/Users/d", ""),
			wantAmbig: false,
		},
		{
			name:      "the agent does not count as its own sibling",
			agents:    []herdr.Agent{agentAt("w4:pT", "/Users/d", "")},
			subject:   agentAt("w4:pT", "/Users/d", ""),
			wantAmbig: false,
		},
		{
			// A sibling in a SUBdirectory has its own project dir, so it cannot
			// be confused with this one. Only an exact match is ambiguous.
			name: "a sibling in a subdirectory is not a collision",
			agents: []herdr.Agent{
				agentAt("wN:p2J", "/Users/d/projects/gothalo/app", "b4fca52e"),
				agentAt("wN:p15", "/Users/d/projects/gothalo", ""),
			},
			subject:   agentAt("wN:p15", "/Users/d/projects/gothalo", ""),
			wantAmbig: false,
		},
		{
			// A sibling of a DIFFERENT kind resolves in its own namespace, so
			// it can never be the transcript this pane's fallback lands on. A
			// pi agent next to an id-less opencode pane must not block the
			// opencode service from resolving by cwd.
			name: "a different-kind sibling is not a collision",
			agents: []herdr.Agent{
				agentKindAt("w4:pJ", "pi", "/Users/d", "b711dd17"),
				agentKindAt("w4:pT", "opencode", "/Users/d", ""),
			},
			subject:   agentKindAt("w4:pT", "opencode", "/Users/d", ""),
			wantAmbig: false,
		},
		{
			// Same kind and same directory: the fallback still cannot choose.
			name: "a same-kind sibling is still a collision",
			agents: []herdr.Agent{
				agentKindAt("w4:pJ", "opencode", "/Users/d", "b711dd17"),
				agentKindAt("w4:pT", "opencode", "/Users/d", ""),
			},
			subject:     agentKindAt("w4:pT", "opencode", "/Users/d", ""),
			wantAmbig:   true,
			wantSibling: "w4:pJ",
		},
		{
			name:      "an unknown cwd cannot be reasoned about",
			agents:    []herdr.Agent{agentAt("w4:pJ", "", "")},
			subject:   agentAt("w4:pT", "", ""),
			wantAmbig: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sibling, ambiguous := siblingInSameCwd(tc.agents, tc.subject.PaneID, tc.subject)
			if ambiguous != tc.wantAmbig {
				t.Fatalf("ambiguous = %v, want %v", ambiguous, tc.wantAmbig)
			}
			if tc.wantSibling != "" && sibling != tc.wantSibling {
				t.Errorf("sibling = %q, want %q", sibling, tc.wantSibling)
			}
		})
	}
}
