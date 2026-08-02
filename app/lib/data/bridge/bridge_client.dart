import 'package:dio/dio.dart';

import '../../core/connection/connection.dart';
import 'models/snapshot.dart';

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
