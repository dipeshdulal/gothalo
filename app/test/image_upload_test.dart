import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';

/// A stand-in for the network. Records the request the client actually built —
/// which is the interesting half of these tests, since `POST /image` is picky
/// about the body shape (raw bytes, a real Content-Length, no filename
/// anywhere) and none of that is observable from the response.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({required this.status, required this.body});

  final int status;
  final Object body;

  RequestOptions? seen;
  List<int> seenBody = const [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen = options;
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      seenBody = chunks.expand((c) => c).toList();
    }
    // The bridge answers success as JSON and every error as plain text (see
    // CONTRACT-image.md). That distinction is load-bearing: dio only tries to
    // JSON-decode a JSON content type, and a text error body mislabelled as
    // JSON would blow up in the transformer before the status code was ever
    // looked at — so the fake has to get it right or the error-mapping tests
    // would be testing a situation that never happens.
    final isJson = body is! String;
    return ResponseBody.fromString(
      isJson ? jsonEncode(body) : body as String,
      status,
      headers: {
        Headers.contentTypeHeader: [
          isJson ? Headers.jsonContentType : Headers.textPlainContentType,
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

BridgeClient _clientWith(_RecordingAdapter adapter) {
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

/// A PNG as far as the bridge's sniffer is concerned — the magic number is all
/// `http.DetectContentType` reads, so a real encoded image would test nothing
/// extra here either.
Uint8List _png([int pad = 32]) =>
    Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(pad, 0)]);

void main() {
  group('uploadImage request shape', () {
    test('posts raw bytes to /image with the pane and a real length', () async {
      final adapter = _RecordingAdapter(
        status: 200,
        body: {
          'path': '/repo/.gothalo/images/20260805-142530-9f86d081.png',
          'relative_path': '.gothalo/images/20260805-142530-9f86d081.png',
          'content_type': 'image/png',
          'bytes': 40,
        },
      );
      final bytes = _png();
      final drop = await _clientWith(adapter).uploadImage('w1:p2', bytes);

      final req = adapter.seen!;
      expect(req.method, 'POST');
      expect(req.path, '/image');
      expect(req.queryParameters['pane'], 'w1:p2');
      // Raw bytes, byte-for-byte — not multipart, not base64, no JSON envelope.
      expect(adapter.seenBody, bytes);
      // The bridge's over-cap fast path keys off Content-Length; dio won't
      // length a raw stream by itself, so the client must set it.
      expect(req.headers[Headers.contentLengthHeader], bytes.length);
      expect(req.headers[Headers.contentTypeHeader], 'application/octet-stream');

      expect(drop.path, '/repo/.gothalo/images/20260805-142530-9f86d081.png');
      expect(drop.contentType, 'image/png');
    });

    test('sends the session-qualified pane id unmangled', () async {
      final adapter = _RecordingAdapter(status: 200, body: {'path': '/repo/a.png'});
      await _clientWith(adapter).uploadImage('acme/w1:p2', _png());
      expect(adapter.seen!.queryParameters['pane'], 'acme/w1:p2');
    });

    test('reports upload progress', () async {
      final adapter = _RecordingAdapter(status: 200, body: {'path': '/repo/a.png'});
      final seen = <int>[];
      await _clientWith(adapter).uploadImage(
        'w1:p2',
        _png(1024),
        onProgress: (sent, total) => seen.add(sent),
      );
      expect(seen, isNotEmpty, reason: 'a silent upload reads as a hang');
    });
  });

  group('uploadImage guards and failures', () {
    test('refuses an over-cap image locally, before any request', () async {
      final adapter = _RecordingAdapter(status: 200, body: {'path': '/x'});
      final tooBig = Uint8List(BridgeClient.maxImageBytes + 1);

      await expectLater(
        _clientWith(adapter).uploadImage('w1:p2', tooBig),
        throwsA(
          isA<BridgeException>().having((e) => e.message, 'message', contains('10MB')),
        ),
      );
      // The point of the local check: a slow tailnet upload never happens.
      expect(adapter.seen, isNull);
    });

    test('accepts an image exactly at the cap', () async {
      final adapter = _RecordingAdapter(status: 200, body: {'path': '/repo/a.png'});
      final atCap = Uint8List(BridgeClient.maxImageBytes);
      await _clientWith(adapter).uploadImage('w1:p2', atCap);
      expect(adapter.seen, isNotNull);
    });

    test('refuses an empty image', () async {
      final adapter = _RecordingAdapter(status: 200, body: {'path': '/x'});
      await expectLater(
        _clientWith(adapter).uploadImage('w1:p2', Uint8List(0)),
        throwsA(isA<BridgeException>()),
      );
      expect(adapter.seen, isNull);
    });

    // A 404 on /image means the bridge predates the endpoint, NOT "no such
    // agent" — the one failure a user would otherwise spend a while misreading.
    test('maps 404 to an out-of-date bridge, not a missing agent', () async {
      final adapter = _RecordingAdapter(status: 404, body: 'not found');
      await expectLater(
        _clientWith(adapter).uploadImage('w1:p2', _png()),
        throwsA(
          isA<BridgeException>()
              .having((e) => e.message, 'message', contains('too old'))
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('maps 413 and 415 to what the user can act on', () async {
      for (final (status, fragment) in [(413, 'too large'), (415, 'PNG')]) {
        final adapter = _RecordingAdapter(status: status, body: 'nope');
        await expectLater(
          _clientWith(adapter).uploadImage('w1:p2', _png()),
          throwsA(
            isA<BridgeException>().having((e) => e.message, 'message', contains(fragment)),
          ),
          reason: 'status $status',
        );
      }
    });

    test('a 200 with no path is a failure, not a silent empty attach', () async {
      final adapter = _RecordingAdapter(status: 200, body: {'bytes': 40});
      await expectLater(
        _clientWith(adapter).uploadImage('w1:p2', _png()),
        throwsA(isA<BridgeException>()),
      );
    });

    // A captive portal or a proxy can answer 200 with HTML. That must still be
    // a BridgeException the UI can show, not a raw TypeError from a bad cast.
    test('a 200 that is not JSON is still a BridgeException', () async {
      final adapter = _RecordingAdapter(status: 200, body: '<html>hi</html>');
      await expectLater(
        _clientWith(adapter).uploadImage('w1:p2', _png()),
        throwsA(isA<BridgeException>()),
      );
    });
  });

  group('uploadFile', () {
    // A PDF as far as the bridge's sniffer is concerned — same reasoning as
    // _png: the magic bytes are all that is read.
    Uint8List pdf([int pad = 32]) => Uint8List.fromList([
      ...utf8.encode('%PDF-1.7\n'),
      ...List.filled(pad, 0),
    ]);

    test('posts raw bytes to /file with the pane and a real length', () async {
      final adapter = _RecordingAdapter(
        status: 200,
        body: {
          'path': '/repo/.gothalo/files/20260805-142530-9f86d081.pdf',
          'relative_path': '.gothalo/files/20260805-142530-9f86d081.pdf',
          'content_type': 'application/pdf',
          'bytes': 41,
        },
      );
      final bytes = pdf();
      final drop = await _clientWith(adapter).uploadFile('w1:p2', bytes);

      final req = adapter.seen!;
      expect(req.method, 'POST');
      expect(req.path, '/file');
      expect(req.queryParameters['pane'], 'w1:p2');
      // Same wire discipline as /image: raw bytes, a real length, no filename.
      expect(adapter.seenBody, bytes);
      expect(req.headers[Headers.contentLengthHeader], bytes.length);
      expect(req.headers[Headers.contentTypeHeader], 'application/octet-stream');

      expect(drop.path, '/repo/.gothalo/files/20260805-142530-9f86d081.pdf');
      expect(drop.contentType, 'application/pdf');
    });

    test('refuses an over-cap file locally, before any request', () async {
      final adapter = _RecordingAdapter(status: 200, body: {'path': '/x'});
      final tooBig = Uint8List(BridgeClient.maxFileBytes + 1);

      await expectLater(
        _clientWith(adapter).uploadFile('w1:p2', tooBig),
        throwsA(
          isA<BridgeException>().having((e) => e.message, 'message', contains('25MB')),
        ),
      );
      expect(adapter.seen, isNull);
    });

    test('maps 404 to an out-of-date bridge, not a missing agent', () async {
      final adapter = _RecordingAdapter(status: 404, body: 'not found');
      await expectLater(
        _clientWith(adapter).uploadFile('w1:p2', pdf()),
        throwsA(
          isA<BridgeException>()
              .having((e) => e.message, 'message', contains('too old'))
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('maps 413 and 415 to what the user can act on', () async {
      for (final (status, fragment) in [(413, 'too large'), (415, 'PDF')]) {
        final adapter = _RecordingAdapter(status: status, body: 'nope');
        await expectLater(
          _clientWith(adapter).uploadFile('w1:p2', pdf()),
          throwsA(
            isA<BridgeException>().having((e) => e.message, 'message', contains(fragment)),
          ),
          reason: 'status $status',
        );
      }
    });
  });
}
