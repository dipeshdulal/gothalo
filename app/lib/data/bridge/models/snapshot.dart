import 'package:freezed_annotation/freezed_annotation.dart';

part 'snapshot.freezed.dart';
part 'snapshot.g.dart';

/// Normalized agent lifecycle state, as reported by Herdr under
/// `agent_status`. Any value the bridge sends that we don't recognize maps to
/// [AgentStatus.unknown] so a new Herdr state can never crash the app.
enum AgentStatus {
  idle,
  working,
  blocked,
  done,
  unknown;

  /// Agents that need a human right now — these are what push notifications and
  /// the top of the inbox are for.
  bool get needsAttention =>
      this == AgentStatus.blocked || this == AgentStatus.done;

  /// Sort rank for the flat "Agents" list — things that need you first.
  int get rank => switch (this) {
    AgentStatus.blocked => 0,
    AgentStatus.done => 1,
    AgentStatus.working => 2,
    AgentStatus.idle => 3,
    AgentStatus.unknown => 4,
  };
}

/// A single agent (Claude Code, Codex, Gemini, …) as it appears in one Herdr
/// pane. Field names mirror the bridge `/snapshot` payload; missing or unknown
/// fields fall back to safe defaults rather than throwing.
@freezed
sealed class Agent with _$Agent {
  const Agent._();

  const factory Agent({
    @Default('') String agent,
    @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)
    @Default(AgentStatus.unknown)
    AgentStatus agentStatus,
    @JsonKey(name: 'pane_id') @Default('') String paneId,
    @JsonKey(name: 'terminal_title_stripped') @Default('') String title,
    @JsonKey(name: 'workspace_id') @Default('') String workspaceId,
    @JsonKey(name: 'tab_id') @Default('') String tabId,
    @Default('') String cwd,
    @Default(false) bool focused,
    @JsonKey(name: 'agent_session') AgentSession? session,

    /// Herdr's monotonic sequence for this agent's state. Backs idempotent
    /// approvals (D8): an approve tap carries this seq and the bridge no-ops if
    /// the agent is no longer blocked at it.
    @JsonKey(name: 'state_change_seq') int? stateChangeSeq,
  }) = _Agent;

  factory Agent.fromJson(Map<String, dynamic> json) => _$AgentFromJson(json);

  /// Stable identity for an agent within a snapshot. The pane id is unique per
  /// Herdr pane and is also the address we type into, so it doubles as the key.
  String get id => paneId.isNotEmpty ? paneId : (session?.value ?? agent);

  /// A human label for the row when the terminal title is empty.
  String get displayTitle => title.isNotEmpty ? title : agent;

  /// Best-effort git context derived from [cwd]. Herdr worktrees live under
  /// `…/.herdr/worktrees/<project>/<worktree>`, where `<worktree>` is
  /// effectively the branch; plain checkouts are just their directory name.
  ///
  /// The bridge does not expose the real branch yet, so this is inferred from
  /// the path. When the bridge adds a branch field, prefer it over this.
  ({String project, String? worktree}) get gitContext =>
      gitContextForCwd(cwd);

  /// The most specific git name to show — the worktree (branch) if this is a
  /// worktree, otherwise the project directory.
  String get gitLabel => gitContext.worktree ?? gitContext.project;

  bool get isWorktree => gitContext.worktree != null;

  /// The Herdr session this agent lives in, derived from the bridge's
  /// session-qualified pane id ("acme/w1:p2"); unqualified ids are the
  /// default session.
  String get sessionName => sessionForId(paneId);

  bool get isDefaultSession => sessionName == 'default';
}

/// Herdr's session handle for an agent — `{ "value": "<uuid>" }`.
@freezed
sealed class AgentSession with _$AgentSession {
  const factory AgentSession({String? value}) = _AgentSession;

  factory AgentSession.fromJson(Map<String, dynamic> json) =>
      _$AgentSessionFromJson(json);
}

/// Session prefix of a bridge id ("acme/w1:p2" → "acme"); the bridge leaves
/// the default session's ids unqualified, so no prefix means "default".
String sessionForId(String id) {
  final i = id.indexOf('/');
  return i > 0 ? id.substring(0, i) : 'default';
}

/// Derive `{project, worktree}` from a cwd. Herdr worktrees live under
/// `…/.herdr/worktrees/<project>/<worktree>`; a plain checkout is just its
/// directory. Shared by agents (their cwd) and spaces (a pane's cwd).
({String project, String? worktree}) gitContextForCwd(String cwd) {
  final parts = cwd.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return (project: '', worktree: null);
  final wt = parts.indexOf('worktrees');
  if (wt > 0 && parts[wt - 1] == '.herdr' && wt + 2 < parts.length) {
    return (project: parts[wt + 1], worktree: parts.sublist(wt + 2).join('/'));
  }
  return (project: parts.last, worktree: null);
}

/// A single terminal pane — **every** pane in the multiplexer, not just the
/// ones running a coding agent. Non-agent panes (shells, dev servers, logs)
/// have `agent_status` too (often idle/unknown).
@freezed
sealed class Pane with _$Pane {
  const Pane._();

  const factory Pane({
    @JsonKey(name: 'pane_id') @Default('') String paneId,
    @JsonKey(name: 'tab_id') @Default('') String tabId,
    @JsonKey(name: 'workspace_id') @Default('') String workspaceId,
    @JsonKey(name: 'terminal_title_stripped') @Default('') String title,
    @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)
    @Default(AgentStatus.unknown)
    AgentStatus agentStatus,
    @Default(false) bool focused,
    @Default('') String cwd,
    @JsonKey(name: 'foreground_cwd') @Default('') String foregroundCwd,
  }) = _Pane;

  factory Pane.fromJson(Map<String, dynamic> json) => _$PaneFromJson(json);

  /// The Herdr session this pane lives in (see [sessionForId]).
  String get sessionName => sessionForId(paneId);

  /// The pane's most telling location (current foreground dir, else cwd).
  String get where => foregroundCwd.isNotEmpty ? foregroundCwd : cwd;

  /// The last one or two path segments of [where] — enough to tell shells in a
  /// `backend`/`frontend`/root apart at a glance.
  String get locationLabel {
    final parts = where.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.last;
    return '${parts[parts.length - 2]}/${parts.last}';
  }

  /// True when [title] is just a shell's *prompt* (`user@host:path`) rather than
  /// the name of a running program. Idle shells set their terminal title to the
  /// prompt; a foreground process replaces it with its command line — so this is
  /// how we tell "sitting at a shell" from "running `./gothalo serve`".
  bool get _looksLikeShellPrompt {
    final t = title.trim();
    if (t.isEmpty) return true;
    // e.g. `alex@my-mac:~/projects/acme/backend`
    return RegExp(r'^[^\s@]+@[^\s:]+:').hasMatch(t);
  }

  /// The foreground command running in this pane, or null if it's an idle shell
  /// sitting at its prompt. Meaningful for non-agent panes; for agent panes the
  /// title is the task, so callers should prefer the agent's own fields.
  String? get command {
    if (_looksLikeShellPrompt) return null;
    final t = title.trim();
    return t.isEmpty ? null : t;
  }
}

/// A tab within a workspace (holds one or more panes).
@freezed
sealed class TabInfo with _$TabInfo {
  const factory TabInfo({
    @JsonKey(name: 'tab_id') @Default('') String tabId,
    @JsonKey(name: 'workspace_id') @Default('') String workspaceId,
    @Default('') String label,
    @Default(0) int number,
    @JsonKey(name: 'pane_count') @Default(0) int paneCount,
    @Default(false) bool focused,
  }) = _TabInfo;

  factory TabInfo.fromJson(Map<String, dynamic> json) =>
      _$TabInfoFromJson(json);
}

/// A workspace ("space") — the top of the Herdr hierarchy, holding tabs.
@freezed
sealed class WorkspaceInfo with _$WorkspaceInfo {
  const factory WorkspaceInfo({
    @JsonKey(name: 'workspace_id') @Default('') String workspaceId,
    @Default('') String label,
    @Default(0) int number,
    @JsonKey(name: 'tab_count') @Default(0) int tabCount,
    @JsonKey(name: 'pane_count') @Default(0) int paneCount,
    @JsonKey(name: 'active_tab_id') @Default('') String activeTabId,
    @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)
    @Default(AgentStatus.unknown)
    AgentStatus agentStatus,
    @Default(false) bool focused,
  }) = _WorkspaceInfo;

  factory WorkspaceInfo.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceInfoFromJson(json);
}

/// The `snapshot` object inside the bridge response envelope
/// (`{ result: { snapshot: { agents: [...] } } }`). The client unwraps the
/// envelope and hands us just this node.
@freezed
sealed class Snapshot with _$Snapshot {
  const Snapshot._();

  const factory Snapshot({
    @Default(<Agent>[]) List<Agent> agents,
    @Default(<Pane>[]) List<Pane> panes,
    @Default(<TabInfo>[]) List<TabInfo> tabs,
    @Default(<WorkspaceInfo>[]) List<WorkspaceInfo> workspaces,
    @JsonKey(name: 'focused_pane_id') @Default('') String focusedPaneId,
  }) = _Snapshot;

  factory Snapshot.fromJson(Map<String, dynamic> json) =>
      _$SnapshotFromJson(json);

  /// Pane ids that have a detected coding agent — used to show the agent's
  /// avatar on a pane in the full-multiplexer overview.
  Set<String> get agentPaneIds => {for (final a in agents) a.paneId};

  /// All agents as one flat list for the "Agents" tab, ordered attention-first
  /// (blocked → done → working → idle → unknown), then by title.
  List<Agent> get agentsSorted {
    final list = [...agents];
    list.sort((x, y) {
      final r = x.agentStatus.rank - y.agentStatus.rank;
      if (r != 0) return r;
      return x.displayTitle.toLowerCase().compareTo(
        y.displayTitle.toLowerCase(),
      );
    });
    return list;
  }

  /// Agents grouped by **project** (the repo folder from `cwd`), which merges a
  /// project's main checkout with its worktrees under one heading — far more
  /// meaningful than Herdr's internal `w5`/`w8` workspace ids. Groups with an
  /// attention-needing agent float up; within a group, attention first, then
  /// the main checkout before worktrees, then by title.
  List<MapEntry<String, List<Agent>>> get byProject {
    final groups = <String, List<Agent>>{};
    for (final a in agents) {
      groups.putIfAbsent(a.gitContext.project, () => <Agent>[]).add(a);
    }
    for (final list in groups.values) {
      list.sort((x, y) {
        final ax = x.agentStatus.needsAttention ? 0 : 1;
        final ay = y.agentStatus.needsAttention ? 0 : 1;
        if (ax != ay) return ax - ay;
        final wx = x.isWorktree ? 1 : 0;
        final wy = y.isWorktree ? 1 : 0;
        if (wx != wy) return wx - wy;
        return x.displayTitle.toLowerCase().compareTo(
          y.displayTitle.toLowerCase(),
        );
      });
    }
    final entries = groups.entries.toList();
    entries.sort((x, y) {
      final ax = x.value.any((a) => a.agentStatus.needsAttention) ? 0 : 1;
      final ay = y.value.any((a) => a.agentStatus.needsAttention) ? 0 : 1;
      if (ax != ay) return ax - ay;
      return x.key.toLowerCase().compareTo(y.key.toLowerCase());
    });
    return entries;
  }

  /// Agents grouped by `workspace_id`, ordered so workspaces with an agent that
  /// [AgentStatus.needsAttention] float to the top, then alphabetically. Within
  /// a group, attention-needing agents come first.
  List<MapEntry<String, List<Agent>>> get byWorkspace {
    final groups = <String, List<Agent>>{};
    for (final a in agents) {
      groups.putIfAbsent(a.workspaceId, () => <Agent>[]).add(a);
    }
    for (final list in groups.values) {
      list.sort((x, y) {
        final ax = x.agentStatus.needsAttention ? 0 : 1;
        final ay = y.agentStatus.needsAttention ? 0 : 1;
        if (ax != ay) return ax - ay;
        return x.displayTitle.toLowerCase().compareTo(
          y.displayTitle.toLowerCase(),
        );
      });
    }
    final entries = groups.entries.toList();
    entries.sort((x, y) {
      final ax = x.value.any((a) => a.agentStatus.needsAttention) ? 0 : 1;
      final ay = y.value.any((a) => a.agentStatus.needsAttention) ? 0 : 1;
      if (ax != ay) return ax - ay;
      return x.key.compareTo(y.key);
    });
    return entries;
  }
}
