import 'package:dio/dio.dart';

import '../../core/connection/connection.dart';
import 'models/snapshot.dart';

/// Outcome of a `POST /approve`. The bridge always returns `200`; [applied]
/// says whether the confirm keystroke was actually sent, and [reason] explains
/// a no-op (stale seq, agent no longer blocked, no such agent). See D8.
class ApproveResult {
  const ApproveResult({required this.applied, this.reason});

  final bool applied;
  final String? reason;
}

/// Identity of a pane created by `POST /pane/new` — enough to immediately
/// `/attach` to it (and later close it).
class NewPaneResult {
  const NewPaneResult({
    required this.paneId,
    required this.tabId,
    required this.workspaceId,
  });

  final String paneId;
  final String tabId;
  final String workspaceId;
}

/// One agent kind this host can actually launch, from `GET /agents/available`.
///
/// The list is discovered on the bridge (Herdr's kind catalog ∩ what resolves on
/// PATH), never assembled here — the app must not offer a kind that isn't
/// installed, and it has no way to know what is.
class AvailableAgent {
  const AvailableAgent({
    required this.kind,
    required this.path,
    required this.stateReporting,
  });

  /// Herdr's kind id — `claude`, `codex`, `opencode`… Also the executable name.
  final String kind;

  /// Where the executable was found on the host. Shown as the reassurance that
  /// "installed" is a fact about that machine, not a guess.
  final String path;

  /// Whether Herdr can classify this kind's state. False means it will run but
  /// never leave `unknown` — no idle/working/blocked, so no push, no approval
  /// bar. Worth warning about before launch, not after.
  final bool stateReporting;

  factory AvailableAgent.fromJson(Map<String, dynamic> j) => AvailableAgent(
        kind: (j['kind'] as String?) ?? '',
        path: (j['path'] as String?) ?? '',
        stateReporting: j['state_reporting'] == true,
      );
}

/// The outcome of `POST /agent/start` — enough to navigate straight to the new
/// agent without re-reading the snapshot first.
class StartAgentResult {
  const StartAgentResult({
    required this.paneId,
    required this.kind,
    required this.name,
    required this.promptSent,
  });

  /// Session-qualified, so it addresses `/transcript`, `/attach` and `/send`
  /// directly.
  final String paneId;
  final String kind;

  /// The agent's Herdr name, minted by the bridge when the caller gave none.
  final String name;

  /// False when no opening prompt was asked for — and also when one was asked
  /// for but didn't land. The agent is up either way; the prompt is not.
  final bool promptSent;

  factory StartAgentResult.fromJson(Map<String, dynamic> j) => StartAgentResult(
        paneId: (j['pane_id'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        promptSent: j['prompt_sent'] == true,
      );
}

/// One changed file from `GET /diff` — a unified diff for this file alone,
/// plus enough metadata to render a file-list row without parsing the diff.
class DiffFile {
  const DiffFile({
    required this.path,
    required this.status,
    required this.additions,
    required this.deletions,
    required this.diff,
    this.oldPath,
  });

  final String path;

  /// Set only for a rename/copy — the path it moved from.
  final String? oldPath;

  /// `"modified"` | `"added"` | `"deleted"` | `"renamed"` | `"untracked"`.
  final String status;
  final int additions;
  final int deletions;

  /// A unified diff for this file alone. For an untracked file this is a
  /// synthetic "every line added" diff (see CONTRACT-diff.md) — the app
  /// renders every entry the same way regardless of status.
  final String diff;

  factory DiffFile.fromJson(Map<String, dynamic> j) => DiffFile(
        path: (j['path'] as String?) ?? '',
        oldPath: j['old_path'] as String?,
        status: (j['status'] as String?) ?? 'modified',
        additions: (j['additions'] as num?)?.toInt() ?? 0,
        deletions: (j['deletions'] as num?)?.toInt() ?? 0,
        diff: (j['diff'] as String?) ?? '',
      );
}

/// The full `GET /diff` payload — an agent pane's working-tree changes.
class DiffResult {
  const DiffResult({required this.branch, required this.files});

  /// Best-effort; "" on a detached HEAD or if git couldn't resolve one.
  final String branch;
  final List<DiffFile> files;

  factory DiffResult.fromJson(Map<String, dynamic> j) {
    final files = j['files'];
    return DiffResult(
      branch: (j['branch'] as String?) ?? '',
      files: files is List
          ? files
              .whereType<Map>()
              .map((f) => DiffFile.fromJson(Map<String, dynamic>.from(f)))
              .toList()
          : const [],
    );
  }
}

/// One slash command the pane's agent will accept, from `GET /commands` — the
/// composer typeahead's unit. See `docs/CONTRACT-commands.md`.
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.source,
    this.description = '',
    this.argumentHint = '',
    this.scope = '',
  });

  /// The invocation WITHOUT the leading slash — "compact", "frontend:component".
  final String name;

  /// One-line summary. May be empty; a command with no description is still
  /// perfectly invocable, so this must never gate whether the row renders.
  final String description;

  /// e.g. "[pr-number]" — shown dimmed after the name when the command wants an
  /// argument, which is the hint that stops a bare `/review` doing nothing.
  final String argumentHint;

  /// `builtin` | `command` | `skill`.
  final String source;

  /// `user` | `project`, empty for a built-in.
  final String scope;

  /// True for a command compiled into the agent rather than read off disk. The
  /// only entries that can drift from what the agent really accepts, so the UI
  /// badges them honestly instead of implying they were discovered.
  bool get isBuiltin => source == 'builtin';

  /// What the typeahead row shows as its badge.
  String get badge => switch (source) {
        'builtin' => 'built-in',
        'skill' => scope == 'project' ? 'project skill' : 'skill',
        _ => scope == 'project' ? 'project' : 'user',
      };

  factory SlashCommand.fromJson(Map<String, dynamic> j) => SlashCommand(
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        argumentHint: (j['argument_hint'] as String?) ?? '',
        source: (j['source'] as String?) ?? '',
        scope: (j['scope'] as String?) ?? '',
      );
}

/// One recorded agent status transition from `GET /timeline` — see
/// `docs/CONTRACT-timeline.md`.
///
/// Every other bridge read describes the PRESENT. This is the only one that
/// describes the past, and [previous] is the reason it exists: a status alone
/// cannot distinguish an agent that blocked fifty minutes ago from one that
/// blocked ten seconds ago, and that difference is the whole question you have
/// when you pick the phone up.
class TimelineEntry {
  const TimelineEntry({
    required this.at,
    required this.pane,
    required this.agent,
    required this.to,
    this.from,
    this.session,
    this.workspace,
    this.previous,
    this.title,
  });

  /// When the bridge observed the transition.
  final DateTime at;

  /// Session-qualified pane id — the same id `/attach`, `/send` and
  /// `/transcript` take, so a row can open the agent it describes.
  final String pane;

  /// Agent kind (`claude`, `codex`, …). May be empty for a pane whose kind the
  /// bridge never learned.
  final String agent;

  final String? session;
  final String? workspace;

  /// The pane's human name at the time of the transition ("Fix the failing
  /// parser test").
  ///
  /// This, not [agent], is what identifies a row to a person: [agent] is a KIND,
  /// so a host running a dozen Claudes yields a dozen rows that all read
  /// "Claude". Null for a pane the bridge never learned a title for.
  final String? title;

  /// The status being left. **Null for a first sighting** — a newly detected
  /// agent, not a transition out of an unnamed state.
  final String? from;

  /// The status entered: a Herdr agent status, or `"gone"` when the pane closed
  /// or its process exited.
  final String to;

  /// How long the agent spent in [from].
  ///
  /// **Null means unknown, not zero.** The bridge omits it when it cannot see
  /// where the span began (the first transition after a restart for a pane that
  /// had moved on while the bridge was down). `Duration.zero` is a real value —
  /// an instantaneous flip — so a renderer must not conflate the two.
  final Duration? previous;

  /// The pane stopped existing rather than changing status.
  bool get isGone => to == 'gone';

  factory TimelineEntry.fromJson(Map<String, dynamic> j) {
    final prevMs = (j['prev_ms'] as num?)?.toInt();
    String? nonEmpty(Object? v) {
      final s = v as String?;
      return (s == null || s.isEmpty) ? null : s;
    }

    return TimelineEntry(
      at: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num?)?.toInt() ?? 0),
      pane: (j['pane'] as String?) ?? '',
      agent: (j['agent'] as String?) ?? '',
      session: nonEmpty(j['session']),
      workspace: nonEmpty(j['workspace']),
      title: nonEmpty(j['title']),
      from: nonEmpty(j['from']),
      to: (j['to'] as String?) ?? '',
      previous: prevMs == null ? null : Duration(milliseconds: prevMs),
    );
  }
}

/// One selectable choice on a blocked agent's prompt (from `/agent-state`).
class BlockedOption {
  const BlockedOption({
    required this.index,
    required this.label,
    required this.selected,
    this.key,
  });

  /// The number to type to pick it (1-based); 0 if unnumbered (see [key]).
  final int index;
  final String label;

  /// The highlighted default — the one a bare Enter (`/approve`) accepts.
  final bool selected;

  /// Set instead of a usable [index] for a choice with no menu number, only
  /// reachable via a raw keystroke — e.g. `"esc"` for the decline action on
  /// Claude's single-choice approval form (`❯ 1. Yes` with no numbered "No").
  /// Dispatch via [BridgeClient.sendKey], not [BridgeClient.sendText].
  final String? key;

  bool get isKeyed => key != null && key!.isNotEmpty;

  factory BlockedOption.fromJson(Map<String, dynamic> j) => BlockedOption(
        index: (j['index'] as num?)?.toInt() ?? 0,
        label: (j['label'] as String?) ?? '',
        selected: j['selected'] == true,
        key: j['key'] as String?,
      );
}

/// Coarse visual severity for a blocked agent, derived from `blocked.category`
/// (Herdr's own detection rule id, filled server-side via `agent.explain`).
///
/// The category is **optional** — an older bridge, an unrecognised prompt, or a
/// failed `agent.explain` all leave it absent. We degrade to [permission] in
/// that case: still clearly an approval (lock, elevated), but we never *upgrade*
/// an unknown prompt to [danger].
enum BlockSeverity {
  /// Approving runs a command / grants a tool — the highest-stakes prompts.
  /// `dangerous_command_approval`, `tool_approval`.
  danger,

  /// A permission grant that isn't a raw command: file writes, generic
  /// permission prompts, or an absent/unknown category.
  permission,

  /// A plain choice with no permission stakes — `question_panel`.
  question,
}

/// The parsed agent card from `GET /agent-state` — what the agent is doing and,
/// when blocked, the exact question + options it's waiting on.
class AgentState {
  const AgentState({
    required this.paneId,
    required this.agentKind,
    required this.agentStatus,
    required this.headline,
    required this.detail,
    required this.blockedQuestion,
    required this.blockedCategory,
    required this.options,
    required this.parsed,
    this.permissionMode,
  });

  final String paneId;
  final String agentKind;
  final String agentStatus;
  final String headline;
  final String detail;

  /// The prompt the agent is waiting on — present only when blocked.
  final String? blockedQuestion;

  /// Coarse semantic class of the block from Herdr's own detection
  /// (`blocked.category`), e.g. `tool_approval`, `dangerous_command_approval`,
  /// `question_panel`, `write_file_approval`, `generic_permission_prompt`.
  /// **Optional** — absent on an older bridge or an unrecognised prompt. Style
  /// off [blockSeverity] rather than matching the raw string, so a new rule id
  /// degrades cleanly instead of falling through unstyled.
  final String? blockedCategory;

  /// Selectable choices in display order — empty for a free-form prompt.
  final List<BlockedOption> options;
  final bool parsed;

  /// Claude's permission mode (`default`/`acceptEdits`/`plan`/`auto`/…). Present
  /// only for Claude panes when readable; absent for other kinds — treat the
  /// value as an opaque label and offer a single "cycle" action.
  final String? permissionMode;

  bool get isBlocked => agentStatus == 'blocked';

  /// The agent is actively producing output (generating a reply, running a
  /// tool) — drives the chat's "thinking…" indicator.
  bool get isWorking => agentStatus == 'working';

  /// Visual severity for the current block, mapped from [blockedCategory].
  /// Absent/unknown → [BlockSeverity.permission] (never over-warns as danger).
  BlockSeverity get blockSeverity => switch (blockedCategory) {
        'dangerous_command_approval' || 'tool_approval' => BlockSeverity.danger,
        'question_panel' => BlockSeverity.question,
        _ => BlockSeverity.permission,
      };

  /// A short human label for the block category (for a badge/pill), or null
  /// when there's nothing worth labelling (a plain question, or absent).
  String? get blockedCategoryLabel => switch (blockedCategory) {
        'dangerous_command_approval' => 'Dangerous command',
        'tool_approval' => 'Tool permission',
        'write_file_approval' => 'File write',
        'generic_permission_prompt' => 'Permission',
        _ => null,
      };

  factory AgentState.fromJson(Map<String, dynamic> j) {
    final blocked = j['blocked'];
    final opts = (blocked is Map ? blocked['options'] : null);
    return AgentState(
      paneId: (j['pane_id'] as String?) ?? '',
      agentKind: (j['agent_kind'] as String?) ?? '',
      agentStatus: (j['agent_status'] as String?) ?? 'unknown',
      headline: (j['headline'] as String?) ?? '',
      detail: (j['detail'] as String?) ?? '',
      blockedQuestion: blocked is Map ? blocked['question'] as String? : null,
      blockedCategory: blocked is Map ? blocked['category'] as String? : null,
      options: opts is List
          ? opts
              .whereType<Map>()
              .map((o) => BlockedOption.fromJson(Map<String, dynamic>.from(o)))
              .toList()
          : const [],
      parsed: j['parsed'] != false,
      permissionMode: j['permission_mode'] as String?,
    );
  }
}

/// Where an uploaded image landed, from `POST /image`.
///
/// [path] is the whole point: an absolute path inside the pane's own working
/// directory. Coding agents read an image when handed a path, so putting this
/// where the user is typing — the composer, or the terminal — *is* the
/// attachment; no agent protocol is involved. See docs/CONTRACT-image.md.
class ImageDrop {
  const ImageDrop({
    required this.path,
    required this.relativePath,
    required this.contentType,
    required this.bytes,
  });

  /// Absolute path to the written file — what gets typed.
  final String path;

  /// The same file relative to the pane's cwd (`.gothalo/images/…`). Display
  /// only; the agent gets [path], since its cwd isn't necessarily the shell's.
  final String relativePath;

  /// What the bridge *sniffed* the bytes as, not what we claimed they were.
  final String contentType;
  final int bytes;
}

/// Thrown for any bridge call that fails — network down, non-2xx, or a body we
/// couldn't parse. Carries a human message for the UI and the status code when
/// there was one (e.g. 401 bad token, 502 bridge daemon not running).
class BridgeException implements Exception {
  BridgeException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isAuth => statusCode == 401 || statusCode == 403;
  bool get isBridgeDown => statusCode == 502 || statusCode == 503;

  @override
  String toString() => 'BridgeException($statusCode): $message';
}

/// The one seam the app talks to the bridge through.
///
/// Built from a [Connection] ({baseUrl, bearer}); a single dio interceptor
/// injects `Authorization: Bearer <token>` on every request, so no call site
/// ever handles the token. Swap the [Connection] (manual settings today, QR
/// pairing later) and every call re-targets — nothing here is hardcoded.
class BridgeClient {
  BridgeClient(this.connection, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: connection.baseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: {'Accept': 'application/json'},
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Authorization'] = 'Bearer ${connection.bearer}';
          handler.next(options);
        },
      ),
    );
  }

  final Connection connection;
  final Dio _dio;

  /// `GET /snapshot` → the current Herdr state. Unwraps the
  /// `{ result: { snapshot: {...} } }` envelope and returns just the snapshot.
  Future<Snapshot> getSnapshot() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/snapshot');
      final body = res.data;
      if (body == null) {
        throw BridgeException('Empty snapshot response');
      }
      // Be tolerant of envelope shape: prefer result.snapshot, but accept a
      // bare snapshot or a bare agents list too.
      final result = body['result'];
      final snapNode = (result is Map ? result['snapshot'] : null) ??
          body['snapshot'] ??
          body;
      if (snapNode is! Map) {
        throw BridgeException('Unexpected snapshot shape');
      }
      return Snapshot.fromJson(Map<String, dynamic>.from(snapNode));
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /info` → this bridge's own identity: `server_id` and `server_name`.
  ///
  /// The app stores the id against the saved server so an incoming push, which
  /// carries only `server_id`, can be traced back to the server it came from —
  /// for attribution in the alerts log and for routing a notification tap. A
  /// bridge older than this endpoint 404s; callers treat that as "unknown" and
  /// carry on.
  /// `version` is the bridge's capability level, hand-bumped on the bridge when
  /// it gains something the app may branch on. Zero means a bridge old enough
  /// not to report one.
  Future<({String serverId, String serverName, int version})> info() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/info');
      final body = res.data ?? const <String, dynamic>{};
      return (
        serverId: (body['server_id'] as String?) ?? '',
        serverName: (body['server_name'] as String?) ?? '',
        version: (body['version'] as num?)?.toInt() ?? 0,
      );
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /send {pane, text}` → types [text] into the given Herdr pane. Include
  /// a trailing `\n` in [text] to submit.
  Future<void> sendText(String pane, String text) async {
    try {
      await _dio.post<dynamic>('/send', data: {'pane': pane, 'text': text});
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /send {pane, key}` → sends a raw keystroke instead of typed text —
  /// for a [BlockedOption] that has no [BlockedOption.index] and is only
  /// reachable via a keystroke (e.g. `"esc"` to decline a single-choice
  /// approval form).
  Future<void> sendKey(String pane, String key) async {
    try {
      await _dio.post<dynamic>('/send', data: {'pane': pane, 'key': key});
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /approve {agent, seq}` → one-tap idempotent approval for a blocked
  /// agent (D8). [agent] is the pane id; [seq] is that agent's
  /// `state_change_seq` from the snapshot. The confirm keystroke is chosen
  /// server-side per agent kind, so the app sends none itself. The bridge no-ops
  /// (`applied:false` + a [ApproveResult.reason]) when the agent is no longer
  /// blocked at [seq]; the call is always `200`.
  Future<ApproveResult> approve(String agent, int seq) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/approve',
        data: {'agent': agent, 'seq': seq},
      );
      final body = res.data ?? const <String, dynamic>{};
      return ApproveResult(
        applied: body['applied'] == true,
        reason: body['reason'] as String?,
      );
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /pane/new` → creates a terminal and returns its identity so we can
  /// `/attach` to it. Provide [workspaceId] to open a fresh tab in that space,
  /// or [splitFrom] to split an existing pane ([splitFrom] wins if both given).
  /// [command], when set, is typed and run in the new pane; a command that fails
  /// still yields a created pane (the bridge returns 200 either way).
  Future<NewPaneResult> createPane({
    String? workspaceId,
    String? splitFrom,
    String? direction,
    String? cwd,
    String? label,
    String? command,
  }) async {
    if ((workspaceId == null || workspaceId.isEmpty) &&
        (splitFrom == null || splitFrom.isEmpty)) {
      throw BridgeException('createPane needs a workspaceId or splitFrom');
    }
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/pane/new',
        data: {
          if (splitFrom != null && splitFrom.isNotEmpty) 'split_from': splitFrom,
          if (workspaceId != null && workspaceId.isNotEmpty)
            'workspace_id': workspaceId,
          if (direction != null && direction.isNotEmpty) 'direction': direction,
          if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
          if (label != null && label.isNotEmpty) 'label': label,
          if (command != null && command.isNotEmpty) 'command': command,
        },
      );
      final body = res.data ?? const <String, dynamic>{};
      final paneId = body['pane_id'] as String?;
      if (paneId == null || paneId.isEmpty) {
        throw BridgeException('Bridge did not return a new pane id');
      }
      return NewPaneResult(
        paneId: paneId,
        tabId: body['tab_id'] as String? ?? '',
        workspaceId: body['workspace_id'] as String? ?? workspaceId ?? '',
      );
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /agent-state?pane=<id>` → the parsed agent card (status, headline, and
  /// when blocked the question + options). Agent panes only; a non-agent or
  /// unsupported pane throws.
  ///
  /// The card is built from the pane's current screen. The bridge can also read
  /// the pane's SCROLLBACK for a richer detail/transcript (`?recent=1`), but
  /// Herdr can only capture that by physically scrolling the pane — visible as a
  /// jump to whoever is watching it on the desktop, once per call. Nothing in the
  /// app needs it: the chat screen streams the real transcript, and the activity
  /// line wants current state rather than history. So we never ask.
  Future<AgentState> getAgentState(String pane) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/agent-state',
        queryParameters: {'pane': pane},
      );
      final body = res.data;
      if (body == null) throw BridgeException('Empty agent-state response');
      return AgentState.fromJson(body);
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /diff?pane=<id>` → an agent pane's working-tree changes (branch +
  /// one unified diff per changed file). Agent panes only — a non-agent pane
  /// throws (404). See CONTRACT-diff.md.
  Future<DiffResult> getDiff(String pane) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/diff',
        queryParameters: {'pane': pane},
      );
      final body = res.data;
      if (body == null) throw BridgeException('Empty diff response');
      return DiffResult.fromJson(body);
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /commands?pane=<id>` → the slash commands this pane's agent accepts,
  /// for the composer typeahead. See CONTRACT-commands.md.
  ///
  /// Returns an empty list rather than throwing for every "no typeahead here"
  /// case — an agent kind with no command surface, a plain pane, or a bridge too
  /// old to have the endpoint (404). The composer degrades to a plain text field
  /// and the user is told nothing, because there is nothing they could do about
  /// it. A genuine transport failure still throws.
  Future<List<SlashCommand>> getCommands(String pane) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/commands',
        queryParameters: {'pane': pane},
      );
      final list = (res.data ?? const {})['commands'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((c) => SlashCommand.fromJson(Map<String, dynamic>.from(c)))
          .where((c) => c.name.isNotEmpty)
          .toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      throw _asBridgeException(e);
    }
  }

  /// `GET /timeline` → the recent agent-activity log, **newest first**: one
  /// entry per status transition, each carrying how long the agent spent in the
  /// status it just left. See CONTRACT-timeline.md.
  ///
  /// Purely a read of the bridge's in-memory ring — no Herdr call — so it is
  /// cheap enough to poll and still answers while Herdr itself is down. [limit]
  /// is clamped server-side; [pane] restricts the log to one agent.
  ///
  /// A bridge older than this endpoint 404s and a bridge with recording
  /// disabled 503s; both surface as a [BridgeException] the caller renders as
  /// "no history".
  Future<List<TimelineEntry>> getTimeline({int? limit, String? pane}) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/timeline',
        queryParameters: {
          'limit': ?limit,
          if (pane != null && pane.isNotEmpty) 'pane': pane,
        },
      );
      final entries = (res.data ?? const {})['entries'];
      if (entries is! List) return const [];
      return entries
          .whereType<Map>()
          .map((e) => TimelineEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /agents/available` → the agent kinds this host can actually launch.
  ///
  /// Empty is a meaningful answer and never an error: a bridge older than the
  /// lifecycle endpoints 404s, and a host with no agents installed answers an
  /// empty list. Both mean the same thing to the UI — don't offer to start one —
  /// so both collapse to `[]` here rather than making every caller branch.
  Future<List<AvailableAgent>> availableAgents() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/agents/available');
      final agents = (res.data ?? const {})['agents'];
      if (agents is! List) return const [];
      return agents
          .whereType<Map>()
          .map((a) => AvailableAgent.fromJson(Map<String, dynamic>.from(a)))
          .toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      throw _asBridgeException(e);
    }
  }

  /// `POST /agent/start` → launch [kind] and return where it landed.
  ///
  /// Exactly one target: [paneId] reuses an existing idle shell pane,
  /// [splitFrom] splits one, [workspaceId] opens a new tab. [cwd] must be an
  /// absolute, existing directory (the bridge validates and rejects otherwise)
  /// and is only accepted for the two creating forms — an existing pane keeps
  /// its own directory. [prompt] is submitted as the agent's first message.
  Future<StartAgentResult> startAgent({
    required String kind,
    String? paneId,
    String? splitFrom,
    String? workspaceId,
    String? direction,
    String? label,
    String? cwd,
    String? prompt,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/agent/start',
        data: {
          'kind': kind,
          if (paneId != null && paneId.isNotEmpty) 'pane_id': paneId,
          if (splitFrom != null && splitFrom.isNotEmpty) 'split_from': splitFrom,
          if (workspaceId != null && workspaceId.isNotEmpty)
            'workspace_id': workspaceId,
          if (direction != null && direction.isNotEmpty) 'direction': direction,
          if (label != null && label.isNotEmpty) 'label': label,
          if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
          if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
        },
        options: _launchOptions,
      );
      final body = res.data ?? const <String, dynamic>{};
      final result = StartAgentResult.fromJson(body);
      if (result.paneId.isEmpty) {
        throw BridgeException('Bridge did not return a pane for the new agent');
      }
      return result;
    } on DioException catch (e) {
      throw _asLaunchException(e);
    }
  }

  /// `POST /agent/restart {pane_id}` → stop the agent in [paneId] and start the
  /// same kind again in the same pane and directory.
  ///
  /// Destructive: the running turn is killed and the replacement starts with no
  /// conversation history. Confirm before calling.
  Future<void> restartAgent(String paneId, {String? prompt}) async {
    try {
      await _dio.post<dynamic>(
        '/agent/restart',
        data: {
          'pane_id': paneId,
          if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
        },
        options: _launchOptions,
      );
    } on DioException catch (e) {
      throw _asLaunchException(e);
    }
  }

  /// `POST /agent/stop {pane_id}` → quit the agent in [paneId], leaving the pane
  /// open at a shell prompt.
  ///
  /// Destructive: whatever it was doing is interrupted. The bridge only answers
  /// `200` once it has *observed* the pane back at its prompt — a `409` means the
  /// agent ignored the interrupts and is still running, so treat it as "not
  /// stopped", never as a slow success. Confirm before calling.
  Future<void> stopAgent(String paneId) async {
    try {
      await _dio.post<dynamic>(
        '/agent/stop',
        data: {'pane_id': paneId},
        options: _launchOptions,
      );
    } on DioException catch (e) {
      throw _asLaunchException(e);
    }
  }

  /// The lifecycle endpoints are the only ones that legitimately take tens of
  /// seconds: Herdr blocks a start until it has *verified* the agent is up, and
  /// blocks a stop until the pane is back at its shell. The default 8s receive
  /// timeout would abort those mid-flight and report a failure for a launch that
  /// then succeeds on the host — the worst possible outcome, since the app would
  /// show an error next to a real running agent.
  static final _launchOptions = Options(
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 30),
  );

  /// Lifecycle failures are explained in the bridge's plain-text body — "cwd
  /// does not exist: /nope", "pane w1:p3 is busy running npm run dev", "the
  /// claude agent did not exit within 12s and is still running". Those sentences
  /// are the whole value of the response, and the generic mapper would throw
  /// them away for "Bridge request failed", so this prefers the body and falls
  /// back to the generic mapping when there isn't one.
  BridgeException _asLaunchException(DioException e) {
    final data = e.response?.data;
    if (data is String) {
      final message = data.trim();
      if (message.isNotEmpty && message.length <= 400) {
        return BridgeException(message, statusCode: e.response?.statusCode);
      }
    }
    return _asBridgeException(e);
  }

  /// `POST /register-token {token}` → registers this device's FCM token so the
  /// bridge can push `blocked`/`done` notifications to it.
  Future<void> registerToken(String fcmToken) async {
    try {
      await _dio.post<dynamic>('/register-token', data: {'token': fcmToken});
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /herdr {method, params}` — the allowlisted generic proxy onto Herdr's
  /// command surface (worktree/tab/pane create+close, plus reads). Returns the
  /// `result` object verbatim. A disallowed method (`403`), unknown target
  /// (`404`), or Herdr error (`502`) throws a [BridgeException] carrying the
  /// proxy's `{error}` message.
  Future<Map<String, dynamic>> herdrCommand(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/herdr',
        data: {'method': method, 'params': params},
      );
      final result = (res.data ?? const {})['result'];
      return result is Map ? Map<String, dynamic>.from(result) : {};
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['error'] is String) {
        throw BridgeException(
          data['error'] as String,
          statusCode: e.response?.statusCode,
        );
      }
      throw _asBridgeException(e);
    }
  }

  // Herdr's `agent.view.*` projection is deliberately NOT used. Herdr accepts
  // `agent.view.set` and reports the view active, but as of herdr 0.8.0
  // (protocol 19) no read applies it — `agent.list` and `session.snapshot` both
  // return the unprojected list, and there is no projected read method — so the
  // handshake ordered nothing. Attention ordering is the bridge's job instead:
  // it stamps `attention_rank` on every agent in `/snapshot` (see
  // `Agent.attention`), which is authoritative and shared by every surface.

  /// `POST /agent-mode/cycle {pane}` → advance a Claude pane's permission mode
  /// by one Shift+Tab. Returns the new mode (best-effort read-back; null if it
  /// didn't settle in time). Throws `409` for a non-Claude pane.
  Future<String?> cycleAgentMode(String pane) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/agent-mode/cycle',
        data: {'pane': pane},
      );
      return (res.data ?? const {})['permission_mode'] as String?;
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// The largest upload `POST /image` accepts (10 MiB, inclusive) — mirrors
  /// `imagedrop.MaxBytes` on the bridge. Checked client-side in [uploadImage]
  /// so the common mistake ("I picked the 40 MP one") fails instantly instead
  /// of after a slow tailnet upload that ends in a 413.
  static const int maxImageBytes = 10 * 1024 * 1024;

  /// `POST /image?pane=…` with the raw bytes → the absolute path the bridge
  /// wrote inside that pane's working directory (the agent's when the pane
  /// hosts one, the pane's own when it doesn't — a plain shell pane can be
  /// handed a path just as well).
  ///
  /// The body is raw bytes, **not** multipart: a filename is the one thing the
  /// endpoint refuses to accept, so we have nothing to name a part with. The
  /// bridge sniffs the type from the bytes and derives both the extension and
  /// the filename itself (CONTRACT-image.md).
  ///
  /// [onProgress] reports sent/total. A phone pushing a few megabytes over a
  /// tailnet is slow enough that a silent upload reads as a hang, so the caller
  /// is expected to show it. The timeouts are raised well past the client's
  /// 8-second default for the same reason — that default is tuned for small
  /// JSON calls and would abort a perfectly healthy photo upload.
  ///
  /// Throws [BridgeException]; a `404` here means the bridge predates the
  /// endpoint rather than "no such agent", so it gets its own message.
  Future<ImageDrop> uploadImage(
    String pane,
    List<int> bytes, {
    void Function(int sent, int total)? onProgress,
  }) async {
    if (bytes.isEmpty) {
      throw BridgeException('That image is empty.');
    }
    if (bytes.length > maxImageBytes) {
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      throw BridgeException(
        'That image is ${mb}MB — the limit is '
        '${maxImageBytes ~/ (1024 * 1024)}MB.',
      );
    }
    try {
      // Typed `dynamic`, not `Map`, on purpose: a 200 whose body isn't the JSON
      // we expect (a captive portal, a proxy's HTML) would fail the cast
      // *outside* the DioException catch below and surface as a raw TypeError.
      // Shape-check it here instead so every failure is a BridgeException.
      final res = await _dio.post<dynamic>(
        '/image',
        data: Stream.fromIterable([bytes]),
        queryParameters: {'pane': pane},
        onSendProgress: onProgress,
        options: Options(
          headers: {
            Headers.contentTypeHeader: 'application/octet-stream',
            // Dio won't length a raw stream by itself, and the bridge's
            // over-cap fast path keys off Content-Length — without this an
            // oversized body would be buffered before being refused.
            Headers.contentLengthHeader: bytes.length,
          },
          sendTimeout: const Duration(seconds: 90),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final data = res.data;
      if (data is! Map) {
        throw BridgeException('The bridge returned an unexpected response.');
      }
      final body = Map<String, dynamic>.from(data);
      final path = body['path'] as String?;
      if (path == null || path.isEmpty) {
        throw BridgeException(
          'The bridge stored the image but returned no path.',
        );
      }
      return ImageDrop(
        path: path,
        relativePath: (body['relative_path'] as String?) ?? path,
        contentType: (body['content_type'] as String?) ?? '',
        bytes: (body['bytes'] as num?)?.toInt() ?? bytes.length,
      );
    } on DioException catch (e) {
      throw _asImageException(e);
    }
  }

  /// [uploadImage]'s error mapping. `/image` has failure modes the generic
  /// mapper has no words for — and its `404` means something different here
  /// (an old bridge, not a missing agent), which is exactly the case a user
  /// would otherwise spend a while misreading.
  BridgeException _asImageException(DioException e) {
    final code = e.response?.statusCode;
    final message = switch (code) {
      404 =>
        'This bridge is too old to accept images. Update it and try again.',
      413 => 'That image is too large for the bridge (10MB limit).',
      415 => 'That file isn\'t a PNG, JPEG, GIF or WebP.',
      _ => null,
    };
    if (message != null) return BridgeException(message, statusCode: code);
    if (e.type == DioExceptionType.sendTimeout) {
      return BridgeException(
        'Upload timed out. The tailnet may be slow — try again.',
        statusCode: code,
      );
    }
    return _asBridgeException(e);
  }

  BridgeException _asBridgeException(DioException e) {
    final code = e.response?.statusCode;
    final message = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        'Timed out reaching the bridge. Is the tailnet up?',
      DioExceptionType.connectionError =>
        'Could not reach the bridge. Check the URL and that you\'re on the tailnet.',
      _ => switch (code) {
        401 || 403 => 'Unauthorized — the bearer token was rejected.',
        502 || 503 => 'Bridge is unreachable (502/503). Is the daemon running?',
        _ => e.message ?? 'Bridge request failed',
      },
    };
    return BridgeException(message, statusCode: code);
  }
}
