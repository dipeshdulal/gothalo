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

  /// `POST /register-token {token}` → registers this device's FCM token so the
  /// bridge can push `blocked`/`done` notifications to it.
  Future<void> registerToken(String fcmToken) async {
    try {
      await _dio.post<dynamic>('/register-token', data: {'token': fcmToken});
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
