import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/data/bridge/bridge_providers.dart';
import 'package:gothalo/features/diff/diff_screen.dart';

/// A whole fake bridge for the two endpoints this screen talks to. Routing by
/// path rather than replaying a fixed response is what lets one test cover the
/// interesting sequence — load the diff, open a file, tap a collapsed region,
/// see the fetched lines land in the right place.
class _FakeBridge implements HttpClientAdapter {
  _FakeBridge({required this.diff, this.fileLines = const []});

  final Map<String, dynamic> diff;

  /// The working-tree content `/diff/expand` serves back.
  final List<String> fileLines;

  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    if (options.path == '/diff') return _json(diff);
    if (options.path == '/diff/expand') {
      final start = options.queryParameters['start'] as int;
      final count = options.queryParameters['count'] as int;
      final end = (start - 1 + count).clamp(0, fileLines.length);
      return _json({
        'path': options.queryParameters['path'],
        'start': start,
        'lines': fileLines.sublist(start - 1, end),
        'eof': end >= fileLines.length,
        'total': fileLines.length,
      });
    }
    return ResponseBody.fromString('not found', 404);
  }

  ResponseBody _json(Object body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

Widget _app(_FakeBridge bridge) {
  final dio = Dio(BaseOptions(baseUrl: 'http://bridge.test'));
  dio.httpClientAdapter = bridge;
  final client = BridgeClient(
    const Connection(
      id: 'test',
      name: 'test bridge',
      baseUrl: 'http://bridge.test',
      bearer: 'tok',
    ),
    dio: dio,
  );
  return ProviderScope(
    overrides: [bridgeClientProvider.overrideWithValue(client)],
    child: const MaterialApp(home: DiffScreen(pane: 'w1:p1')),
  );
}

void main() {
  testWidgets('renders a folded directory tree with rolled-up counts', (
    tester,
  ) async {
    final bridge = _FakeBridge(
      diff: {
        'branch': 'feat/x',
        'files': [
          {
            'path': 'internal/server/diff.go',
            'status': 'modified',
            'additions': 4,
            'deletions': 1,
            'diff': '@@ -1,2 +1,2 @@\n-old\n+new\n ctx',
          },
          {
            'path': 'internal/server/pane.go',
            'status': 'modified',
            'additions': 2,
            'deletions': 0,
            'diff': '@@ -1,1 +1,2 @@\n ctx\n+added',
          },
        ],
      },
    );

    await tester.pumpWidget(_app(bridge));
    await tester.pumpAndSettle();

    // The chain folded to one row, and the counts are the subtree's — once on
    // the summary bar and once on the directory row.
    expect(find.text('internal/server'), findsOneWidget);
    expect(find.text('+6'), findsNWidgets(2));
    // The single deletion shows three times: summary, directory, and the one
    // file it came from.
    expect(find.text('−1'), findsNWidgets(3));
    expect(find.text('2 files'), findsOneWidget);

    // Both files listed; neither diff is rendered until it is opened.
    expect(find.text('diff.go'), findsOneWidget);
    expect(find.text('pane.go'), findsOneWidget);
    expect(find.textContaining('new'), findsNothing);
  });

  testWidgets('opening a file renders its diff lines', (tester) async {
    final bridge = _FakeBridge(
      diff: {
        'branch': 'feat/x',
        'files': [
          {
            'path': 'a.go',
            'status': 'modified',
            'additions': 1,
            'deletions': 1,
            'diff': '@@ -1,2 +1,2 @@\n-alpha one\n+alpha two\n kept',
          },
        ],
      },
    );

    await tester.pumpWidget(_app(bridge));
    await tester.pumpAndSettle();

    // A single-file change opens itself — there is nothing to choose between.
    expect(find.textContaining('kept'), findsOneWidget);

    await tester.tap(find.text('a.go'));
    await tester.pumpAndSettle();
    expect(find.textContaining('kept'), findsNothing);
  });

  testWidgets('a collapsed region expands from the bridge', (tester) async {
    // One hunk at lines 20..21 of a 30-line file: 19 hidden lines above it and
    // 9 below.
    final bridge = _FakeBridge(
      diff: {
        'branch': 'feat/x',
        'files': [
          {
            'path': 'a.go',
            'status': 'modified',
            'additions': 1,
            'deletions': 1,
            'diff': '@@ -20,2 +20,2 @@ func main()\n-was\n+is\n tail',
          },
        ],
      },
      fileLines: [for (var i = 1; i <= 30; i++) 'line $i'],
    );

    await tester.pumpWidget(_app(bridge));
    await tester.pumpAndSettle();

    // Below 60 lines the whole region is offered in one tap, and the hunk's
    // section header rides along on the row.
    expect(find.text('Show 19 unchanged lines'), findsOneWidget);
    expect(find.text('func main()'), findsOneWidget);

    await tester.tap(find.text('Show 19 unchanged lines'));
    await tester.pumpAndSettle();

    expect(find.textContaining('line 1'), findsWidgets);
    expect(find.textContaining('line 19'), findsOneWidget);
    expect(find.text('Show 19 unchanged lines'), findsNothing);

    final expand = bridge.seen.where((r) => r.path == '/diff/expand').single;
    expect(expand.queryParameters['start'], 1);
    expect(expand.queryParameters['count'], 19);
    expect(expand.queryParameters['path'], 'a.go');
  });

  testWidgets('an untracked file offers no expansion affordance', (
    tester,
  ) async {
    // Its synthetic diff already IS the whole file, so there is nothing hidden
    // to reveal — offering the row would be a tap that does nothing.
    final bridge = _FakeBridge(
      diff: {
        'branch': 'feat/x',
        'files': [
          {
            'path': 'new.go',
            'status': 'untracked',
            'additions': 2,
            'deletions': 0,
            'diff': '--- /dev/null\n+++ b/new.go\n+package main\n+// hi',
          },
        ],
      },
    );

    await tester.pumpWidget(_app(bridge));
    await tester.pumpAndSettle();

    expect(find.textContaining('package main'), findsOneWidget);
    expect(find.textContaining('unchanged line'), findsNothing);
    expect(find.text('Show more lines'), findsNothing);
  });

  // The load path must not touch a diff it was not asked to show. This is the
  // whole reason the screen parses per file on open rather than up front — a
  // real agent session produces exactly this shape.
  testWidgets('a large diff renders no line it was not asked for', (
    tester,
  ) async {
    final bridge = _FakeBridge(
      diff: {
        'branch': 'feat/x',
        'files': [
          for (var f = 0; f < 120; f++)
            {
              'path': 'pkg/mod$f/file$f.dart',
              'status': 'modified',
              'additions': 300,
              'deletions': 0,
              'diff':
                  '@@ -1,300 +1,300 @@\n'
                  '${[for (var i = 0; i < 300; i++) '+body $f line $i'].join('\n')}',
            },
        ],
      },
    );

    // runAsync because a payload this size crosses the threshold where dio
    // decodes JSON on a background isolate, which fake-async never lets finish.
    await tester.runAsync(() async {
      await tester.pumpWidget(_app(bridge));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    expect(find.text('120 files'), findsOneWidget);
    expect(find.textContaining('body 0 line 0'), findsNothing);
    expect(find.textContaining('body 119 line 299'), findsNothing);
  });

  testWidgets('an empty working tree says so', (tester) async {
    final bridge = _FakeBridge(diff: {'branch': 'main', 'files': []});

    await tester.pumpWidget(_app(bridge));
    await tester.pumpAndSettle();

    expect(find.text('No changes'), findsOneWidget);
  });
}
