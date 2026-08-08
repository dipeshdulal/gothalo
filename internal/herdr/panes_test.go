package herdr

import (
	"encoding/json"
	"reflect"
	"testing"
)

// The collector walks for `pane_id` wherever it appears rather than following a
// fixed workspace->tab->pane path, so a Herdr release that adds a level (or
// moves panes under a split tree) keeps working. This fixture nests them two
// different depths to hold that property down.
const snapshotFixture = `{
  "type": "snapshot",
  "snapshot": {
    "focused_workspace_id": "wN",
    "focused_pane_id": "wN:p2",
    "workspaces": [
      {
        "workspace_id": "wN",
        "active_tab_id": "wN:t1",
        "tabs": [
          {
            "tab_id": "wN:t1",
            "panes": [
              {"pane_id": "wN:p2", "agent": "claude", "agent_status": "working"},
              {"pane_id": "wN:p3", "agent": "", "split_from": "wN:p2"}
            ]
          },
          {
            "tab_id": "wN:t2",
            "panes": [
              {"pane_id": "wN:p9", "children": [{"pane_id": "wN:p10"}]}
            ]
          }
        ]
      }
    ]
  }
}`

func TestCollectPaneIDs(t *testing.T) {
	var tree any
	if err := json.Unmarshal([]byte(snapshotFixture), &tree); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	got := map[string]bool{}
	collectPaneIDs(tree, got)

	// wN:p3 is the plain pane a dev server actually runs in — if the collector
	// ever regresses to agent panes only, this is the one that disappears.
	want := map[string]bool{"wN:p2": true, "wN:p3": true, "wN:p9": true, "wN:p10": true}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("collectPaneIDs = %v, want %v", keys(got), keys(want))
	}
}

// focused_pane_id points at a pane already listed in the tree. Counting it as
// its own pane would be harmless here but wrong in principle, and would break
// the moment focus pointed at a pane in another workspace.
func TestCollectPaneIDsIgnoresFocusPointers(t *testing.T) {
	var tree any
	if err := json.Unmarshal([]byte(`{"focused_pane_id":"wN:p99","panes":[{"pane_id":"wN:p1"}]}`), &tree); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	got := map[string]bool{}
	collectPaneIDs(tree, got)
	if len(got) != 1 || !got["wN:p1"] {
		t.Errorf("collectPaneIDs = %v, want just wN:p1", keys(got))
	}
}

func TestCollectPaneIDsSkipsEmpty(t *testing.T) {
	var tree any
	if err := json.Unmarshal([]byte(`{"panes":[{"pane_id":""},{"pane_id":"wN:p1"}]}`), &tree); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	got := map[string]bool{}
	collectPaneIDs(tree, got)
	if len(got) != 1 || !got["wN:p1"] {
		t.Errorf("collectPaneIDs = %v, want just wN:p1", keys(got))
	}
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
