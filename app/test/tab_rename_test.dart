import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/data/bridge/bridge_providers.dart';
import 'package:gothalo/features/herdr_actions.dart';

/// Renaming a tab is one `POST /herdr {method:"tab.rename"}`, and the only part
/// the app owns is *which* calls it makes. Herdr validates nothing — it accepts
/// `""` and blanks the tab — so "we never sent that" is the actual guarantee
/// these tests pin, alongside the payload shape the proxy contract advertises.

/// Records the proxy call the dialog builds, and answers with a canned status.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.status = 200, this.body = const {'result': {}}});

  final int status;
  final Object body;
  final List<Map<String, dynamic>> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(Map<String, dynamic>.from(options.data as Map));
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

/// Mounts a button that opens the rename dialog for `wN:t2`, then taps it.
Future<void> _openDialog(
  WidgetTester tester,
  _RecordingAdapter adapter, {
  String currentLabel = 'before',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bridgeClientProvider.overrideWithValue(_clientWith(adapter))],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => renameTabDialog(
                context,
                ref,
                'wN:t2',
                currentLabel: currentLabel,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder get _renameButton =>
    find.widgetWithText(FilledButton, 'Rename');

void main() {
  testWidgets('it prefills the current label, selected', (tester) async {
    await _openDialog(tester, _RecordingAdapter());

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'before');
    // Selected, not just present: replacing the name is the common case and
    // must not require clearing it first on a phone keyboard.
    expect(
      field.controller?.selection,
      const TextSelection(baseOffset: 0, extentOffset: 6),
    );
  });

  testWidgets('a new name sends exactly one tab.rename', (tester) async {
    final adapter = _RecordingAdapter();
    await _openDialog(tester, adapter);

    await tester.enterText(find.byType(TextField), 'api server');
    await tester.pump();
    await tester.tap(_renameButton);
    await tester.pumpAndSettle();

    expect(adapter.calls, [
      {
        'method': 'tab.rename',
        'params': {'tab_id': 'wN:t2', 'label': 'api server'},
      },
    ]);
  });

  testWidgets('it trims before sending', (tester) async {
    final adapter = _RecordingAdapter();
    await _openDialog(tester, adapter);

    await tester.enterText(find.byType(TextField), '  api server  ');
    await tester.pump();
    await tester.tap(_renameButton);
    await tester.pumpAndSettle();

    expect(adapter.calls.single['params'], {
      'tab_id': 'wN:t2',
      'label': 'api server',
    });
  });

  testWidgets('an empty name cannot be submitted', (tester) async {
    final adapter = _RecordingAdapter();
    await _openDialog(tester, adapter);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();

    expect(tester.widget<FilledButton>(_renameButton).onPressed, isNull);
    await tester.tap(_renameButton);
    await tester.pumpAndSettle();
    // The dialog is still open and Herdr was never asked to blank the tab.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(adapter.calls, isEmpty);
  });

  testWidgets('an unchanged name is a no-op, not a rename', (tester) async {
    final adapter = _RecordingAdapter();
    await _openDialog(tester, adapter);

    await tester.tap(_renameButton);
    await tester.pumpAndSettle();

    expect(adapter.calls, isEmpty);
    expect(find.text('Tab renamed to "before"'), findsNothing);
  });

  testWidgets('cancelling sends nothing', (tester) async {
    final adapter = _RecordingAdapter();
    await _openDialog(tester, adapter);

    await tester.enterText(find.byType(TextField), 'api server');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(adapter.calls, isEmpty);
  });

  testWidgets("a rejection from Herdr is shown, not swallowed", (tester) async {
    // What the proxy returns when Herdr cannot find the tab (404, per
    // docs/CONTRACT-herdr-proxy.md).
    final adapter = _RecordingAdapter(
      status: 404,
      body: const {'error': 'herdr: tab_not_found: tab wN:t2 not found'},
    );
    await _openDialog(tester, adapter);

    await tester.enterText(find.byType(TextField), 'api server');
    await tester.pump();
    await tester.tap(_renameButton);
    await tester.pumpAndSettle();

    expect(
      find.text('herdr: tab_not_found: tab wN:t2 not found'),
      findsOneWidget,
    );
  });
}
