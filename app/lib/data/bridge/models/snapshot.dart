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

  /// Locally derived attention rank — things that need you first. This mirrors
  /// the bridge's `attention_rank`, and exists only as the fallback for a
  /// snapshot that doesn't carry one (an older bridge). Sort on
  /// [Agent.attention] instead, which prefers the authoritative value; that
  /// getter is this field's only caller.
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

    /// The pane's **live foreground** working directory (tracks a shell `cd`),
    /// as reported by herdr. This is the "proper pane" cwd — preferred over the
    /// launch [cwd] for git context (see [gitContext]). Falls back to [cwd]
    /// when the bridge doesn't supply it.
    @JsonKey(name: 'foreground_cwd') @Default('') String foregroundCwd,

    /// The agent's checked-out git **branch**, reported authoritatively by the
    /// bridge (it asks git). Empty when the bridge doesn't supply it (an older
    /// bridge, or a cwd that isn't a repo) — the app then falls back to
    /// inferring the branch from [cwd]. See [branchName].
    @Default('') String branch,
    @Default(false) bool focused,
    @JsonKey(name: 'agent_session') AgentSession? session,

    /// Herdr's monotonic sequence for this agent's state. Backs idempotent
    /// approvals (D8): an approve tap carries this seq and the bridge no-ops if
    /// the agent is no longer blocked at it.
    @JsonKey(name: 'state_change_seq') int? stateChangeSeq,

    /// The bridge's authoritative "needs a human first" rank, lowest first. It
    /// is computed server-side so every surface (inbox, priority, counts, the
    /// aggregate header) orders identically instead of each deriving its own.
    /// Null on an older bridge that doesn't send it — see [attention], which
    /// falls back to the local [AgentStatus.rank].
    @JsonKey(name: 'attention_rank') int? attentionRank,

    /// The bridge's authoritative "what did I touch last" rank, lowest first
    /// and unique within a snapshot. It is the tiebreak *within* an
    /// [attentionRank], not a rival to it: what needs you still comes first,
    /// this only decides the order among agents that need you equally — which
    /// the snapshot's own arrival order used to decide, i.e. arbitrarily.
    ///
    /// It is a **position in this snapshot's list**, not an identity: it shifts
    /// as agents come and go. Compare it; never cache or diff it across
    /// snapshots. Null on an older bridge — see [Agent.byAttentionThenRecency],
    /// which falls back to [lastActivityTs].
    @JsonKey(name: 'recency_rank') int? recencyRank,

    /// When this agent last wrote to its transcript, in unix milliseconds —
    /// the bridge's answer to "how long has it been like this".
    ///
    /// Every other field describes NOW. This is the only one that dates it, and
    /// it is what turns "blocked" into "blocked 50m" — the difference that
    /// decides whether you pick the phone up.
    ///
    /// **Null means unknown, never "just now".** Absent for a kind whose
    /// sessions share one store (the bridge refuses to report another agent's
    /// age as this one's) and for an agent that has not spoken yet. Render
    /// nothing rather than "0s".
    @JsonKey(name: 'last_activity_ts') int? lastActivityTs,
  }) = _Agent;

  factory Agent.fromJson(Map<String, dynamic> json) => _$AgentFromJson(json);

  /// Stable identity for an agent within a snapshot. The pane id is unique per
  /// Herdr pane and is also the address we type into, so it doubles as the key.
  String get id => paneId.isNotEmpty ? paneId : (session?.value ?? agent);

  /// A human label for the row when the terminal title is empty.
  String get displayTitle => title.isNotEmpty ? title : agent;

  /// How long since this agent last did anything, or null when the bridge could
  /// not date it.
  ///
  /// Null is not zero: an agent whose age is unknown must render no duration at
  /// all, rather than "0s", which would read as "just now" — the opposite of the
  /// truth for an agent that has been parked for hours.
  Duration? get sinceLastActivity {
    final ts = lastActivityTs;
    if (ts == null || ts <= 0) return null;
    final d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ts),
    );
    return d.isNegative ? Duration.zero : d;
  }

  /// The rank to order this agent by: the bridge's authoritative
  /// [attentionRank] when it sends one, else the locally derived
  /// [AgentStatus.rank]. The two agree by construction — the fallback only
  /// exists so an older bridge still sorts sensibly.
  int get attention => attentionRank ?? agentStatus.rank;

  /// **The** order agents are listed in, anywhere they are listed: what needs a
  /// human first ([attention]), then what you touched last ([recencyRank]),
  /// then title as a last resort.
  ///
  /// It is one function rather than a comparator copied into each screen
  /// because the way these surfaces drift is one of them quietly keeping an
  /// older tiebreak, and two lists of the same agents in two different orders
  /// is worse for finding an agent than either order is good.
  ///
  /// Both keys come from the bridge, which is what makes the order
  /// authoritative rather than re-derived per screen (see `CONTRACT.md`). The
  /// fallbacks below only exist for a bridge too old to send them.
  static int byAttentionThenRecency(Agent a, Agent b) {
    final r = a.attention - b.attention;
    if (r != 0) return r;
    final c = _compareRecency(a, b);
    if (c != 0) return c;
    return a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase());
  }

  /// Most-recently-active first. Reproduces the bridge's `recency_rank` order
  /// exactly for agents out of one snapshot, and stays meaningful for a list
  /// that mixes servers (Priority does) — which the rank alone cannot, being an
  /// index into one bridge's snapshot.
  ///
  /// 1. Both dated → the wall clock. Comparable across snapshots and across
  ///    servers, and within one snapshot it agrees with the bridge's rank by
  ///    construction, since the rank is built from it.
  /// 2. One dated → the dated one first. An agent with no timestamp sorts
  ///    **last**, never first: absent means unknown, not "just now" — the same
  ///    rule [sinceLastActivity] follows.
  /// 3. Neither dated → the bridge's rank, which also orders the agents it
  ///    could not put a clock on (by their last herdr transition).
  static int _compareRecency(Agent a, Agent b) {
    final ta = a.lastActivityTs, tb = b.lastActivityTs;
    final da = ta != null && ta > 0, db = tb != null && tb > 0;
    if (da && db) return tb.compareTo(ta);
    if (da != db) return da ? -1 : 1;
    final ra = a.recencyRank, rb = b.recencyRank;
    if (ra != null && rb != null) return ra.compareTo(rb);
    return 0;
  }

  /// Best-effort git context derived from [cwd]. Herdr worktrees live under
  /// `…/.herdr/worktrees/<project>/<worktree>`, where `<worktree>` is
  /// effectively the branch; plain checkouts are just their directory name.
  ///
  /// This is a *path inference* fallback: it can only reveal the branch for a
  /// Herdr worktree (the branch is in the path). Prefer the authoritative
  /// [branch] the bridge reports — see [branchName], which layers the two.
  ///
  /// Derived from the pane's live [foregroundCwd] when available (the proper
  /// pane cwd), falling back to the launch [cwd].
  ({String project, String? worktree}) get gitContext =>
      gitContextForCwd(foregroundCwd.isNotEmpty ? foregroundCwd : cwd);

  /// The agent's branch, preferring the bridge's authoritative [branch] and
  /// falling back to the cwd-inferred worktree name. Null when neither knows it
  /// — a plain checkout on an older bridge, where the path can't reveal the
  /// branch. Once the bridge reports [branch], this is correct for plain
  /// checkouts too, not just worktrees.
  String? get branchName {
    final b = branch.trim();
    if (b.isNotEmpty) return b;
    return gitContext.worktree;
  }

  /// True when the agent's branch is known (from the bridge or the cwd path).
  bool get hasBranch => branchName?.isNotEmpty ?? false;

  /// The most specific git name to show — the branch if known, otherwise the
  /// project directory.
  String get gitLabel => branchName ?? gitContext.project;

  /// The cwd sits inside a Herdr-managed git worktree (path-based; independent
  /// of whether the bridge reports [branch]).
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

/// The repository a workspace is checked out at, when it has one. Absent for a
/// space that is not a git checkout (a plain `~` workspace, say).
@freezed
sealed class WorktreeInfo with _$WorktreeInfo {
  const factory WorktreeInfo({
    /// The space's own directory — the ONLY authoritative answer to "where does
    /// this space live". Individual panes wander into subdirectories and linked
    /// worktrees, so no pane's cwd can stand in for it.
    @JsonKey(name: 'checkout_path') @Default('') String checkoutPath,
    @JsonKey(name: 'repo_name') @Default('') String repoName,
    @JsonKey(name: 'is_linked_worktree') @Default(false) bool isLinkedWorktree,
  }) = _WorktreeInfo;

  factory WorktreeInfo.fromJson(Map<String, dynamic> json) =>
      _$WorktreeInfoFromJson(json);
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
    WorktreeInfo? worktree,
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
  /// (blocked → done → working → idle → unknown) and, within a rank,
  /// most-recently-active first.
  ///
  /// Both keys are the bridge's ([Agent.byAttentionThenRecency]), so this list
  /// and everything counted off it stay consistent with every other surface
  /// rather than each screen re-deriving priority. Recency is the key that
  /// makes a long list usable: with a dozen-plus agents the one you were just
  /// in used to land wherever herdr happened to list it, which for an idle
  /// agent meant scrolling to the end to find it.
  List<Agent> get agentsSorted =>
      [...agents]..sort(Agent.byAttentionThenRecency);

  /// Agents grouped by **project** (the repo folder from `cwd`), which merges a
  /// project's main checkout with its worktrees under one heading — far more
  /// meaningful than Herdr's internal `w5`/`w8` workspace ids. Groups with an
  /// attention-needing agent float up; within a group, attention first, then
  /// the main checkout before worktrees, then most-recently-active first.
  ///
  /// The main-checkout-before-worktrees rule outranks recency deliberately:
  /// it is structure, not priority — a worktree row reads as belonging under
  /// the checkout above it, and letting recency interleave them would lose
  /// that. Everything below it defers to the shared order.
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
        return Agent.byAttentionThenRecency(x, y);
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
  /// a group, attention-needing agents come first, then the shared order.
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
        return Agent.byAttentionThenRecency(x, y);
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
