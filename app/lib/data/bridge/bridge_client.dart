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
