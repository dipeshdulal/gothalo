// Package events is gothalo's in-process event bus. It sits ABOVE Herdr's own
// socket event stream: a Herdr ingester normalizes Herdr's typed events into a
// unified envelope and publishes them here, gothalo subsystems publish their own
// system events here, and the WS /events hub fans the single unified stream out
// to connected apps. It is a small typed pub/sub — channels with bounded
// per-subscriber buffers and drop-slow-subscriber semantics — with no external
// broker.
package events

import "encoding/json"

// Source namespaces an envelope by who produced it.
const (
	// SourceHerdr marks an event forwarded/normalized from Herdr's socket stream.
	SourceHerdr = "herdr"
	// SourceGothalo marks an event gothalo itself produced (an approval it
	// applied, a pane it created, pairing, push, herdr connectivity) — things
	// Herdr does not know about.
	SourceGothalo = "gothalo"
)

// Herdr event types (source == SourceHerdr). These are the normalized,
// underscore-cased names carried in Envelope.Type — one per Herdr EventKind,
// plus the derived pane_agent_status_changed (synthesized from Herdr's targeted
// pane.agent_status_changed subscription and from pane_updated/pane_agent_detected;
// see the ingester). The full catalog and a real example for each live in
// CONTRACT.md at the repo root.
const (
	TypeWorkspaceCreated         = "workspace_created"
	TypeWorkspaceUpdated         = "workspace_updated"
	TypeWorkspaceMetadataUpdated = "workspace_metadata_updated"
	TypeWorkspaceClosed          = "workspace_closed"
	TypeWorkspaceRenamed         = "workspace_renamed"
	TypeWorkspaceMoved           = "workspace_moved"
	TypeWorkspaceFocused         = "workspace_focused"
	TypeWorktreeCreated          = "worktree_created"
	TypeWorktreeOpened           = "worktree_opened"
	TypeWorktreeRemoved          = "worktree_removed"
	TypeTabCreated               = "tab_created"
	TypeTabClosed                = "tab_closed"
	TypeTabRenamed               = "tab_renamed"
	TypeTabMoved                 = "tab_moved"
	TypeTabFocused               = "tab_focused"
	TypePaneCreated              = "pane_created"
	TypePaneClosed               = "pane_closed"
	TypePaneUpdated              = "pane_updated"
	TypePaneFocused              = "pane_focused"
	TypePaneMoved                = "pane_moved"
	TypePaneOutputChanged        = "pane_output_changed"
	TypePaneExited               = "pane_exited"
	TypePaneAgentDetected        = "pane_agent_detected"
	TypePaneAgentStatusChanged   = "pane_agent_status_changed"
	TypeLayoutUpdated            = "layout_updated"
)

// gothalo system event types (source == SourceGothalo).
const (
	// TypeApproveApplied is emitted by POST /approve on every outcome; payload
	// carries {pane, seq, applied, reason?}.
	TypeApproveApplied = "approve_applied"
	// TypeGothaloPaneCreated is emitted by POST /pane/new (an app-created pane),
	// distinct from Herdr's own pane_created; payload {pane_id, tab_id, workspace_id}.
	TypeGothaloPaneCreated = "pane_created"
	// TypeGothaloPaneClosed is emitted by POST /pane/close; payload {pane_id}.
	TypeGothaloPaneClosed = "pane_closed"
	// TypeModeCycled is emitted by POST /agent-mode/cycle after a Claude pane's
	// permission mode is advanced; payload {pane, permission_mode?} (the new mode is
	// present only when it could be read back — see the /agent-mode/cycle contract).
	TypeModeCycled = "mode_cycled"
	// TypePushSent is emitted after the FCM fan-out; payload {agent, status, title, seq, sent, total}.
	TypePushSent = "push_sent"
	// TypeDevicePaired is emitted by POST /pair; payload {id, name}.
	TypeDevicePaired = "device_paired"
	// TypeHerdrConnected / _Disconnected / _Resync track the Herdr socket
	// subscription lifecycle so clients know when to re-snapshot.
	TypeHerdrConnected    = "herdr_connected"
	TypeHerdrDisconnected = "herdr_disconnected"
	TypeHerdrResync       = "herdr_resync"
)

// Envelope is the unified, stable shape every event on the bus (and every WS
// /events delta frame) takes. Source+Type identify the event; Seq is a
// process-monotonic counter a client uses to detect gaps (a jump => re-snapshot);
// TS is the publish time in unix milliseconds; Payload is the event-specific body
// (for Herdr events it is Herdr's own `data` object verbatim; for gothalo events a
// small documented struct).
type Envelope struct {
	Source  string          `json:"source"`
	Type    string          `json:"type"`
	Seq     uint64          `json:"seq"`
	TS      int64           `json:"ts"`
	Payload json.RawMessage `json:"payload"`
}
