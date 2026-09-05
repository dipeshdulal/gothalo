package server

import (
	"testing"
	"time"

	"github.com/dipeshdulal/gothalo/internal/transcript"
)

func sub(id string, done bool, ts int64) transcript.Subagent {
	return transcript.Subagent{
		AgentID: id, ToolUseID: "toolu_" + id, AgentType: "general-purpose",
		Description: "d", SpawnDepth: 1, Done: done, LastActivityTS: ts,
	}
}

// The roster used to be sent only in hello — once per connect. A chat left open
// while four agents finished kept saying "4 agents running" forever, and their
// ages kept climbing, so a finished agent rendered as "RUNNING · 47m".
func TestRosterSignatureChangesWhenAnAgentFinishes(t *testing.T) {
	before := rosterSignature([]transcript.Subagent{sub("a1", false, 100)})
	after := rosterSignature([]transcript.Subagent{sub("a1", true, 100)})

	if before == after {
		t.Error("an agent finishing did not change the signature")
	}
}

func TestRosterSignatureChangesWhenAnAgentIsSpawned(t *testing.T) {
	before := rosterSignature([]transcript.Subagent{sub("a1", false, 100)})
	after := rosterSignature([]transcript.Subagent{sub("a1", false, 100), sub("a2", false, 100)})

	if before == after {
		t.Error("a new agent did not change the signature")
	}
}

// Age advances constantly on a working agent; resending the whole roster every
// tick for that alone would be chat noise.
func TestRosterSignatureIgnoresAgeAlone(t *testing.T) {
	before := rosterSignature([]transcript.Subagent{sub("a1", false, 100)})
	after := rosterSignature([]transcript.Subagent{sub("a1", false, 999999)})

	if before != after {
		t.Error("a bare age change resent the roster")
	}
}

func TestRosterSignatureStableForAnUnchangedRoster(t *testing.T) {
	a := []transcript.Subagent{sub("a1", false, 1), sub("a2", true, 2)}
	if rosterSignature(a) != rosterSignature(a) {
		t.Error("signature is not stable")
	}
}

func TestRosterIntervalIsSlowerThanTheTailPoll(t *testing.T) {
	if transcriptRosterInterval <= transcriptPollInterval {
		t.Errorf("roster re-scan (%v) must be slower than the tail poll (%v): it "+
			"lists a directory and scans the parent, and an agent finishing is a "+
			"human-scale event", transcriptRosterInterval, transcriptPollInterval)
	}
	if transcriptRosterInterval > 10*time.Second {
		t.Errorf("roster re-scan %v is slow enough to feel stale", transcriptRosterInterval)
	}
}
