package herdr

import (
	"encoding/json"
	"fmt"
	"strings"
)

// Detection is the winning agent-detection verdict from `herdr agent explain`:
// the matched rule's id — a semantic category such as "tool_approval",
// "question_panel", "dangerous_command_approval", or "write_file_approval" — plus
// a short preview of the matched screen region. It is how gothalo labels *what
// kind* of thing a blocked agent is waiting on using Herdr's own detection rules,
// with no per-agent plugin required.
type Detection struct {
	// RuleID is the matched detection rule (the semantic category).
	RuleID string `json:"rule_id"`
	// State is the status that rule asserts (idle|working|blocked).
	State string `json:"state"`
	// Region is the screen region the rule matched (e.g. "prompt_box_body").
	Region string `json:"region"`
	// Preview is a short (≤240-char) preview of the matched region text.
	Preview string `json:"preview"`
}

// Explain runs `herdr agent explain --json` for a pane/agent target and returns
// the winning (matched, highest-priority) detection rule, or nil if nothing
// matched. Rules come back priority-ordered, so the first matched is the verdict.
// Best-effort enrichment: callers should treat an error as "no category".
func (c *Client) Explain(target string) (*Detection, error) {
	out, err := c.run("agent", "explain", target, "--json")
	if err != nil {
		return nil, err
	}
	var body struct {
		EvaluatedRules []struct {
			ID       string `json:"id"`
			Matched  bool   `json:"matched"`
			State    string `json:"state"`
			Region   string `json:"region"`
			Evidence struct {
				RegionPreview string `json:"region_preview"`
			} `json:"evidence"`
		} `json:"evaluated_rules"`
	}
	if err := json.Unmarshal(out, &body); err != nil {
		return nil, fmt.Errorf("parse agent.explain: %w", err)
	}
	for _, r := range body.EvaluatedRules {
		if r.Matched {
			return &Detection{
				RuleID:  r.ID,
				State:   r.State,
				Region:  r.Region,
				Preview: strings.TrimSpace(r.Evidence.RegionPreview),
			}, nil
		}
	}
	return nil, nil
}
