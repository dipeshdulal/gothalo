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
}

/// Herdr's session handle for an agent — `{ "value": "<uuid>" }`.
@freezed
sealed class AgentSession with _$AgentSession {
  const factory AgentSession({String? value}) = _AgentSession;

  factory AgentSession.fromJson(Map<String, dynamic> json) =>
      _$AgentSessionFromJson(json);
}

/// The `snapshot` object inside the bridge response envelope
/// (`{ result: { snapshot: { agents: [...] } } }`). The client unwraps the
/// envelope and hands us just this node.
@freezed
sealed class Snapshot with _$Snapshot {
  const Snapshot._();

  const factory Snapshot({@Default(<Agent>[]) List<Agent> agents}) = _Snapshot;

  factory Snapshot.fromJson(Map<String, dynamic> json) =>
      _$SnapshotFromJson(json);

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
