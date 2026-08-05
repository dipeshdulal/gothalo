package herdr

import (
	"encoding/json"
	"reflect"
	"testing"
)

// startHelpFixture is the real `herdr agent start --help` output (herdr 0.8.0,
// protocol 19), trimmed to the shape the parser walks. Kept verbatim rather than
// hand-written so a clap layout change shows up as a test failure here rather
// than as an empty kind list in production.
const startHelpFixture = `Start a supported interactive agent in an existing pane

Usage: herdr agent start <NAME> --kind <KIND> --pane <ID> [OPTIONS] [-- [AGENT_ARG]...]

Arguments:
  <NAME>


  [AGENT_ARG]...


Options:
      --kind <KIND>
          Supported agent kind and canonical executable

          [possible values: pi, claude, codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, maki]

      --pane <ID>
          Existing pane at an interactive shell prompt

      --timeout <MS>
          Wait for interactive readiness (default: 30000; max: 300000)
`

// groupUsageFixture is the real `herdr agent` usage block (exit 2), the fallback
// source for the kind catalog.
const groupUsageFixture = `herdr agent commands:
  herdr agent list
  herdr agent get <target>
  herdr agent start <name> --kind KIND --pane ID [--timeout MS] [-- <agent-args...>]
  targets accept unique agent names and pane ids that currently host agents
  kinds: pi|claude|codex|gemini|cursor|devin|agy|cline|omp|mastracode|opencode|copilot|kimi|kiro|droid|amp|grok|hermes|kilo|qodercli|maki
`

var wantKinds = []string{
	"pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline", "omp",
	"mastracode", "opencode", "copilot", "kimi", "kiro", "droid", "amp", "grok",
	"hermes", "kilo", "qodercli", "maki",
}

// TestKindsFromStartHelp asserts the primary discovery path reads Herdr's own
// `--kind` enum. This is the list the launch picker is built from, so an empty
// or partial parse means the app offers nothing (or the wrong things).
func TestKindsFromStartHelp(t *testing.T) {
	got := kindsFromStartHelp(startHelpFixture)
	if !reflect.DeepEqual(got, wantKinds) {
		t.Errorf("kinds = %v\nwant %v", got, wantKinds)
	}
}

// TestKindsFromStartHelpAnchorsOnKind guards the reason the parser looks for
// "--kind" first: another option carrying its own possible-values block must not
// be mistaken for the agent catalog.
func TestKindsFromStartHelpAnchorsOnKind(t *testing.T) {
	help := `Options:
      --format <FORMAT>
          [possible values: text, json]

      --kind <KIND>
          [possible values: claude, codex]
`
	got := kindsFromStartHelp(help)
	want := []string{"claude", "codex"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("kinds = %v, want %v", got, want)
	}
}

// TestKindsFromGroupUsage covers the fallback source, used when a future herdr
// drops or reshapes the clap enum.
func TestKindsFromGroupUsage(t *testing.T) {
	got := kindsFromGroupUsage(groupUsageFixture)
	if !reflect.DeepEqual(got, wantKinds) {
		t.Errorf("kinds = %v\nwant %v", got, wantKinds)
	}
}

// TestKindParsersRejectUnrelatedText asserts both parsers fail closed. Returning
// a bogus kind would be worse than returning none: the caller would offer it,
// and the launch would fail 30 seconds later inside a pane it had already made.
func TestKindParsersRejectUnrelatedText(t *testing.T) {
	for _, in := range []string{"", "error: unknown command\n", "herdr 0.8.0\n"} {
		if got := kindsFromStartHelp(in); got != nil {
			t.Errorf("kindsFromStartHelp(%q) = %v, want nil", in, got)
		}
		if got := kindsFromGroupUsage(in); got != nil {
			t.Errorf("kindsFromGroupUsage(%q) = %v, want nil", in, got)
		}
	}
}

// TestPaneProcessInfoParse pins the decode against a real `pane.process_info`
// result and the two readings the lifecycle turns on: a pane sitting at its
// shell prompt (startable, and the proof a stop worked) versus a pane with a
// process in front of the shell.
func TestPaneProcessInfoParse(t *testing.T) {
	cases := []struct {
		name     string
		result   string
		atPrompt bool
		fgCmd    string
	}{
		{
			name:     "idle-shell",
			result:   `{"process_info":{"foreground_process_group_id":34643,"foreground_processes":[{"argv0":"zsh","cmdline":"-zsh","cwd":"/src","name":"zsh","pid":34643}],"pane_id":"wQ:p2","shell_pid":34643}}`,
			atPrompt: true,
			fgCmd:    "",
		},
		{
			name:     "running-agent",
			result:   `{"process_info":{"foreground_process_group_id":77247,"foreground_processes":[{"argv0":"caffeinate","cmdline":"caffeinate -i -t 300","name":"caffeinate","pid":78426},{"argv0":"claude","cmdline":"claude","name":"claude","pid":77247}],"pane_id":"wN:p2N","shell_pid":76674}}`,
			atPrompt: false,
			fgCmd:    "claude",
		},
		{
			name:     "running-command",
			result:   `{"process_info":{"foreground_process_group_id":71510,"foreground_processes":[{"argv0":"gothalo","cmdline":"./gothalo serve","name":"gothalo","pid":71510}],"pane_id":"wN:p16","shell_pid":1637}}`,
			atPrompt: false,
			fgCmd:    "./gothalo serve",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var body struct {
				Info PaneProcessInfo `json:"process_info"`
			}
			if err := json.Unmarshal([]byte(c.result), &body); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if got := body.Info.AtShellPrompt(); got != c.atPrompt {
				t.Errorf("AtShellPrompt() = %v, want %v", got, c.atPrompt)
			}
			if got := body.Info.ForegroundCommand(); got != c.fgCmd {
				t.Errorf("ForegroundCommand() = %q, want %q", got, c.fgCmd)
			}
		})
	}
}

// TestAtShellPromptNeedsAShell asserts a zero shell_pid is never read as "free".
// A pane whose shell is gone (or a payload from a herdr that stopped reporting
// the field) must not be treated as a startable prompt.
func TestAtShellPromptNeedsAShell(t *testing.T) {
	if (PaneProcessInfo{}).AtShellPrompt() {
		t.Error("a zero PaneProcessInfo must not report a shell prompt")
	}
}

// TestAgentManifestKindsParse covers the state-reporting side channel, including
// the case that matters: it is a SUBSET of the startable kinds, so it can never
// be used as the catalog.
func TestAgentManifestKindsParse(t *testing.T) {
	res := json.RawMessage(`{"type":"agent_manifest_status","manifests":[{"agent":"pi","source_kind":"remote"},{"agent":"claude","source_kind":"remote"},{"agent":"","source_kind":"remote"}]}`)
	kinds, err := parseManifestKinds(res)
	if err != nil {
		t.Fatalf("parseManifestKinds: %v", err)
	}
	want := []string{"pi", "claude"}
	if !reflect.DeepEqual(kinds, want) {
		t.Errorf("kinds = %v, want %v (blank entries dropped)", kinds, want)
	}
}
