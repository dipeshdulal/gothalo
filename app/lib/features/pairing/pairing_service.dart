import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/connection/connection.dart';

part 'pairing_service.g.dart';

/// The payload a pairing QR encodes (see docs/API.md):
/// `{"url":"https://<host>:5338","code":"<code>"}`.
class ConnectPayload {
  const ConnectPayload({required this.url, required this.code});

  final String url;
  final String code;

  /// Parse a scanned QR string. Returns null if it isn't a valid gothalo
  /// pairing payload (so the scanner can ignore unrelated QR codes).
  static ConnectPayload? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw.trim());
      if (decoded is! Map) return null;
      final url = decoded['url'];
      final code = decoded['code'];
      if (url is! String || code is! String) return null;
      if (!url.startsWith('http') || code.isEmpty) return null;
      return ConnectPayload(url: url.replaceAll(RegExp(r'/+$'), ''), code: code);
    } catch (_) {
      return null;
    }
  }
}

/// A pairing failure with a message ready for the UI.
class PairingException implements Exception {
  PairingException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'PairingException($statusCode): $message';
}

@riverpod
PairingService pairingService(Ref ref) => PairingService();

/// Redeems a pairing code for a per-device bearer.
///
/// This is unauthenticated (there is no bearer yet) — it POSTs to the bridge
/// URL from the QR and returns the resulting [Connection]. Saving it (drift +
/// secure storage) and making it active is the caller's job, done with a live
/// widget ref — so this service holds no provider ref and is safe to `read`.
class PairingService {
  Future<Connection> pair(
    ConnectPayload payload, {
    required String deviceName,
    String fcmToken = '',
  }) async {
    final dio = Dio(
      BaseOptions(
        baseUrl: payload.url,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {'Accept': 'application/json'},
      ),
    );

    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/pair',
        data: {
          'code': payload.code,
          'device_name': deviceName,
          'fcm_token': fcmToken,
        },
      );
      final body = res.data ?? const {};
      final bearer = body['bearer'] as String?;
      if (bearer == null || bearer.isEmpty) {
        throw PairingException('The bridge did not return a token.');
      }
      final id = (body['id'] as String?)?.trim().isNotEmpty == true
          ? body['id'] as String
          : 'srv_${payload.code}';
      // The /pair response's `name` echoes the DEVICE name (this phone). The
      // server's display name should reflect the bridge host, so derive it from
      // the URL. The user can rename it later.
      final name = _serverNameFromUrl(payload.url);

      return Connection(
        id: id,
        name: name,
        baseUrl: payload.url,
        bearer: bearer,
        deviceId: id,
        source: ConnectionSource.paired,
      );
    } on DioException catch (e) {
      throw PairingException(_messageFor(e), statusCode: e.response?.statusCode);
    }
  }

  /// A friendly server name from the bridge URL's first host label, e.g.
  /// `https://my-mac.tail…ts.net:5338` → "My Mac".
  String _serverNameFromUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? url;
    final label = host.split('.').first;
    if (label.isEmpty) return host;
    return label
        .split(RegExp(r'[-_]'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  String _messageFor(DioException e) {
    switch (e.response?.statusCode) {
      case 403:
        return 'That code expired or was already used. Run “gothalo pair” '
            'again and scan the fresh QR.';
      case 400:
        return 'The bridge rejected the request. Try scanning again.';
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        'Timed out reaching the bridge. Are you on the tailnet?',
      DioExceptionType.connectionError =>
        'Couldn\'t reach the bridge. Check you\'re on the same tailnet.',
      _ => e.message ?? 'Pairing failed. Try again.',
    };
  }
}
