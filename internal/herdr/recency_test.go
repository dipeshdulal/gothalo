package herdr

import (
	"encoding/json"
	"math/rand"
	"sort"
	"testing"
)

// agentFixture builds one snapshot agent. ts <= 0 means "no last_activity_ts"
// (an agent the bridge could not date); seq < 0 means "no state_change_seq".
// Values arrive as float64 the way a decoded snapshot carries them, except
// last_activity_ts, which the bridge stamps itself as an int64.
func agentFixture(paneID, status string, ts int64, seq int) map[string]any {
	obj := map[string]any{"pane_id": paneID, "agent_status": status}
	if ts > 0 {
		obj["last_activity_ts"] = ts
	}
	if seq >= 0 {
		obj["state_change_seq"] = float64(seq)
	}
	return obj
}

func rankOf(t *testing.T, agents []any, paneID string) int {
	t.Helper()
	for _, it := range agents {
		obj := it.(map[string]any)
		if obj["pane_id"] == paneID {
			r, ok := obj["recency_rank"].(int)
			if !ok {
				t.Fatalf("%s: recency_rank missing or not an int: %#v", paneID, obj["recency_rank"])
			}
			return r
		}
	}
	t.Fatalf("no agent %q in fixture", paneID)
	return -1
}

// paneOrder is the order a client renders: the bridge's attention rank first,
// its recency rank second. Nothing else — the two fields are the whole order.
func paneOrder(agents []any) []string {
	sorted := append([]any(nil), agents...)
	sort.Slice(sorted, func(i, j int) bool {
		a, b := sorted[i].(map[string]any), sorted[j].(map[string]any)
		if a["attention_rank"] != b["attention_rank"] {
			return a["attention_rank"].(int) < b["attention_rank"].(int)
		}
		return a["recency_rank"].(int) < b["recency_rank"].(int)
	})
	out := make([]string, len(sorted))
	for i, it := range sorted {
		out[i] = it.(map[string]any)["pane_id"].(string)
	}
	return out
}

// A dozen-plus agents across every status, some datable and some not — the list
// the ordering exists for. The two-agent case never showed the problem.
func realisticAgents() []any {
	const now = int64(1_785_677_600_000)
	const min = int64(60_000)
	return []any{
		// Dated by their transcripts.
		agentFixture("wN:p41", "idle", now-90*min, 1102),
		agentFixture("wN:p15", "done", now-40*min, 1226),
		agentFixture("w5:p18", "idle", now-8*60*min, 961),
		agentFixture("wN:p42", "done", now-2*min, 1232),
		agentFixture("w4:pJ", "idle", now-15*min, 1204),
		agentFixture("wZ:p1", "done", now-11*min, 1194),
		agentFixture("w1B:p1", "working", now-1*min, 1231),
		agentFixture("wT:p1", "idle", now-3*24*60*min, 1045),
		agentFixture("w5:p1B", "blocked", now-6*min, 1208),
		agentFixture("wW:p1", "blocked", now-55*min, 1183),
		agentFixture("wQ:p1", "idle", now-20*60*min, 518),
		// Undatable: another agent kind (shared session store), so no
		// last_activity_ts — but herdr still knows when each last moved.
		agentFixture("wX:p1", "done", 0, 1190),
		agentFixture("wY:p1", "idle", 0, 1189),
		agentFixture("w8:p1", "working", 0, 10),
		// Just started: no transcript yet, but a very fresh transition.
		agentFixture("w0:p1", "working", 0, 1240),
		// Nothing at all to date it by.
		agentFixture("wP:p1", "unknown", 0, -1),
		agentFixture("w12:p1", "unknown", 0, -1),
	}
}

func TestEnrichAgentRecencyOrdersNewestFirst(t *testing.T) {
	agents := realisticAgents()
	enrichAgentRecency(agents)

	// Every agent gets a rank, and the ranks are 0..N-1 with no duplicates —
	// so (attention_rank, recency_rank) leaves nothing for a client to break.
	seen := map[int]string{}
	for _, it := range agents {
		obj := it.(map[string]any)
		id := obj["pane_id"].(string)
		r, ok := obj["recency_rank"].(int)
		if !ok {
			t.Fatalf("%s: recency_rank missing; it must always be set", id)
		}
		if r < 0 || r >= len(agents) {
			t.Errorf("%s: recency_rank %d outside 0..%d", id, r, len(agents)-1)
		}
		if other, dup := seen[r]; dup {
			t.Errorf("recency_rank %d shared by %s and %s; ranks must be unique", r, other, id)
		}
		seen[r] = id
	}

	// Tier 1, newest transcript activity first, regardless of status: the whole
	// point is that the agent you just touched is near the top of its band.
	dated := []string{
		"w1B:p1", // 1m
		"wN:p42", // 2m
		"w5:p1B", // 6m
		"wZ:p1",  // 11m
		"w4:pJ",  // 15m
		"wN:p15", // 40m
		"wW:p1",  // 55m
		"wN:p41", // 90m
		"w5:p18", // 8h
		"wQ:p1",  // 20h
		"wT:p1",  // 3d
	}
	for i := 1; i < len(dated); i++ {
		if rankOf(t, agents, dated[i-1]) >= rankOf(t, agents, dated[i]) {
			t.Errorf("%s must rank before %s (it was active more recently)", dated[i-1], dated[i])
		}
	}

	// Tier 2 sits entirely below tier 1: an agent the bridge cannot date is
	// unknown, never "just now" — the same rule that makes
	// enrichAgentLastActivity omit the field instead of stamping now().
	oldestDated := rankOf(t, agents, "wT:p1")
	for _, id := range []string{"w0:p1", "wX:p1", "wY:p1", "w8:p1", "wP:p1", "w12:p1"} {
		if rankOf(t, agents, id) <= oldestDated {
			t.Errorf("%s has no last_activity_ts and must rank below every dated agent", id)
		}
	}

	// Within tier 2, herdr's global transition counter orders them — which is
	// what rescues a just-started agent (w0:p1, seq 1240) from the basement.
	byTransition := []string{"w0:p1", "wX:p1", "wY:p1", "w8:p1"}
	for i := 1; i < len(byTransition); i++ {
		if rankOf(t, agents, byTransition[i-1]) >= rankOf(t, agents, byTransition[i]) {
			t.Errorf("%s (higher state_change_seq) must rank before %s", byTransition[i-1], byTransition[i])
		}
	}

	// Tier 3 last, and among themselves by pane id — arbitrary but fixed.
	if rankOf(t, agents, "w8:p1") >= rankOf(t, agents, "w12:p1") {
		t.Error("an agent with a state_change_seq must rank above one with nothing")
	}
	if rankOf(t, agents, "w12:p1") >= rankOf(t, agents, "wP:p1") {
		t.Error("undatable agents must fall back to pane id ascending")
	}
}

// Attention still wins outright: recency only reorders *within* a band. A
// blocked agent idle for an hour must still outrank an idle one touched a
// minute ago, exactly as before this field existed.
func TestRecencyNeverOutranksAttention(t *testing.T) {
	agents := realisticAgents()
	enrichAgentAttention(agents)
	enrichAgentRecency(agents)

	got := paneOrder(agents)
	want := []string{
		// blocked, newest first
		"w5:p1B", "wW:p1",
		// done
		"wN:p42", "wZ:p1", "wN:p15", "wX:p1",
		// working
		"w1B:p1", "w0:p1", "w8:p1",
		// idle
		"w4:pJ", "wN:p41", "w5:p18", "wQ:p1", "wT:p1", "wY:p1",
		// unknown
		"w12:p1", "wP:p1",
	}
	if len(got) != len(want) {
		t.Fatalf("order length = %d, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("list order = %v,\n              want %v", got, want)
		}
	}
}

// The failure mode worth guarding is not a wrong order but a *moving* one: a
// list that reshuffles under a thumb is worse than one that never sorted. The
// same agents in any snapshot order must produce the same list.
func TestRecencyOrderIsStableAcrossSnapshotOrder(t *testing.T) {
	base := realisticAgents()
	enrichAgentAttention(base)
	enrichAgentRecency(base)
	want := paneOrder(base)

	rng := rand.New(rand.NewSource(7))
	for round := range 20 {
		shuffled := realisticAgents()
		rng.Shuffle(len(shuffled), func(i, j int) {
			shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
		})
		enrichAgentAttention(shuffled)
		enrichAgentRecency(shuffled)
		got := paneOrder(shuffled)
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("round %d: snapshot order changed the list:\n got %v\nwant %v", round, got, want)
			}
		}
	}
}

// Agents that share a timestamp to the millisecond (two panes the same sweep
// touched) must not swap places between reads either.
func TestRecencyBreaksIdenticalTimestampsByPaneID(t *testing.T) {
	const ts = int64(1_785_677_600_000)
	agents := []any{
		agentFixture("w2:p9", "idle", ts, 5),
		agentFixture("w1:p1", "idle", ts, 900),
		agentFixture("w1:p2", "idle", ts, 400),
	}
	enrichAgentRecency(agents)
	if got := paneOrder(mustAttention(agents)); got[0] != "w1:p1" || got[1] != "w1:p2" || got[2] != "w2:p9" {
		t.Errorf("identical timestamps must order by pane id, got %v", got)
	}
}

func mustAttention(agents []any) []any {
	enrichAgentAttention(agents)
	return agents
}

// last_activity_ts is stamped by the bridge as an int64, but the same field
// round-trips through JSON as a float64 on any path that re-decodes the
// snapshot. Both must date an agent, or an agent's rank would depend on which
// code path produced the map.
func TestRecencyReadsBothNumberShapes(t *testing.T) {
	const ts = int64(1_785_677_600_000)
	var decoded any
	if err := json.Unmarshal([]byte(`[
		{"pane_id":"w1:p1","last_activity_ts":1785677600000,"state_change_seq":1},
		{"pane_id":"w1:p2","state_change_seq":9}
	]`), &decoded); err != nil {
		t.Fatal(err)
	}
	agents := decoded.([]any)
	enrichAgentRecency(agents)
	if rankOf(t, agents, "w1:p1") != 0 {
		t.Error("a float64 last_activity_ts must still date an agent")
	}

	native := []any{
		agentFixture("w1:p1", "idle", ts, 1),
		agentFixture("w1:p2", "idle", 0, 9),
	}
	enrichAgentRecency(native)
	if rankOf(t, native, "w1:p1") != 0 {
		t.Error("an int64 last_activity_ts must date an agent")
	}
}

// Same tolerance as the other enrichers: they run over whatever the merge
// produced, which may be absent or not an array at all.
func TestEnrichAgentRecencyToleratesMissingAgents(t *testing.T) {
	enrichAgentRecency(nil)
	enrichAgentRecency([]any{})
	enrichAgentRecency("not-an-array")
	enrichAgentRecency([]any{"not-an-object", 42})
}
