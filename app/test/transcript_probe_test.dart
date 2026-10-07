import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';

/// `/agent-transcript` resolves the pane, its kind and its session and opens
/// the transcript BEFORE anything socket-related, so a `?probe=1` GET is a
/// real, cheap existence probe: `404` is the bridge saying this pane has no
/// readable conversation, while `204` (or the `426` a pre-probe bridge
/// answers a plain GET with) is a "yes".
///
/// That verdict is what gates the terminal's chat icon, and the icon is the
/// only route into the transcript — so getting it wrong in the *other*
/// direction (hiding a view that exists) costs a feature, which is why only a
/// definitive 404 is a "no".

/// Answers every request with [status], or throws when [offline] is set.
class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status, {this.offline = false});

  final int status;
  final bool offline;
  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    if (offline) {
      throw DioException(requestOptions: options, message: 'offline');
    }
    return ResponseBody.fromString('', status);
  }

  @override
  void close({bool force = false}) {}
}

BridgeClient _client(_StatusAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://bridge.test'));
  dio.httpClientAdapter = adapter;
  return BridgeClient(
    const Connection(
      id: 'test',
      name: 'test bridge',
      baseUrl: 'http://bridge.test',
      bearer: 'tok',
    ),
    dio: dio,
  );
}

void main() {
  test('a 404 means no transcript, so the chat icon stays hidden', () async {
    expect(await _client(_StatusAdapter(404)).hasTranscript('w1:p1'), isFalse);
  });

  test('the 426 a healthy upgrade-only endpoint gives a plain GET is a yes',
      () async {
    expect(await _client(_StatusAdapter(426)).hasTranscript('w1:p1'), isTrue);
  });

  test('any other status offers the view rather than guessing it away',
      () async {
    for (final status in [200, 401, 500, 502, 503]) {
      expect(
        await _client(_StatusAdapter(status)).hasTranscript('w1:p1'),
        isTrue,
        reason: 'status $status should not hide the chat view',
      );
    }
  });

  test('a probe that never lands is not a verdict — offer the view', () async {
    expect(
      await _client(_StatusAdapter(0, offline: true)).hasTranscript('w1:p1'),
      isTrue,
    );
  });

  test('it probes /agent-transcript for the pane', () async {
    final adapter = _StatusAdapter(426);
    await _client(adapter).hasTranscript('w1:p1');

    expect(adapter.calls.single.path, '/agent-transcript');
    expect(adapter.calls.single.queryParameters['pane'], 'w1:p1');
    // The cheap probe: the bridge must not open a socket or log a ws-accept
    // error on an existence check.
    expect(adapter.calls.single.queryParameters['probe'], '1');
  });
}
