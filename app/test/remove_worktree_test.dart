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

/// Removing a worktree from the phone can now take the branch with it. The
/// safety rules live on the bridge (internal/gitbranch), so what these tests
/// pin is the part the app owns: **which calls it makes, in which order, and
/// what it claims afterwards**.
///
/// The three that matter most:
///   - the branch delete is opt-in and off by default;
///   - an unmerged branch costs a second, different confirm;
///   - a failed worktree removal is never followed by a branch delete.

/// Routes by path so one adapter can serve the preflight, the Herdr proxy and
/// the branch delete, recording every call in order.
class _Bridge implements HttpClientAdapter {
  _Bridge({
    this.branchInfo,
    this.branchInfoStatus = 200,
    this.removeStatus = 200,
    this.deleteStatus = 200,
    this.deleteBody = const {
      'branch': 'feat/x',
      'deleted': true,
      'forced': false,
      'merged': true,
      'sha': 'abc1234',
      'upstream': '',
      'remote_deleted': false,
    },
  });

  final Map<String, dynamic>? branchInfo;
  final int branchInfoStatus;
  final int removeStatus;
  final int deleteStatus;
  final Map<String, dynamic> deleteBody;

  /// `(path, body)` for every request, in the order they were made.
  final List<(String, Object?)> calls = [];

  List<String> get paths => [for (final c in calls) c.$1];

  Map<String, dynamic>? bodyFor(String path) {
    for (final c in calls) {
      if (c.$1 == path) return Map<String, dynamic>.from(c.$2 as Map);
    }
    return null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add((options.path, options.data));
    final (status, body) = switch (options.path) {
      '/branch-info' => (branchInfoStatus, branchInfo ?? const {}),
      '/herdr' => (removeStatus, const {'result': {'type': 'worktree_removed'}}),
      '/branch-delete' => (deleteStatus, deleteBody),
      _ => (404, const {'error': 'no route'}),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A `/branch-info` payload with sensible defaults, overridable per test.
Map<String, dynamic> _info({
  String branch = 'feat/x',
  String repoRoot = '/repos/demo',
  String defaultBranch = 'main',
  bool merged = true,
  String mergedInto = 'main',
  int unmergedCommits = 0,
  String upstream = '',
  bool deletable = true,
  String blockedReason = '',
  List<String> checkedOutElsewhere = const [],
}) => {
      'workspace_id': 'w7',
      'repo_root': repoRoot,
      'checkout_path': '/wt/demo/feat-x',
      'branch': branch,
      'default_branch': defaultBranch,
      'is_default': false,
      'checked_out_elsewhere': checkedOutElsewhere,
      'merged': merged,
      'merged_into': mergedInto,
      'unmerged_commits': unmergedCommits,
      'upstream': upstream,
      'deletable': deletable,
      'blocked_reason': blockedReason,
    };

BridgeClient _clientWith(_Bridge adapter) {
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

/// Mounts a button that opens the remove-worktree confirm for `w7`, taps it,
/// and settles on the dialog.
Future<void> _openDialog(WidgetTester tester, _Bridge adapter) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bridgeClientProvider.overrideWithValue(_clientWith(adapter))],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => removeWorktree(context, ref, 'w7', 'feat/x'),
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

Finder get _removeButton => find.widgetWithText(FilledButton, 'Remove');
Finder get _removeAndDeleteButton =>
    find.widgetWithText(FilledButton, 'Remove & delete branch');
Finder get _checkbox => find.byType(CheckboxListTile);

void main() {
  testWidgets('the dialog names the branch and says it is merged', (tester) async {
    await _openDialog(tester, _Bridge(branchInfo: _info()));

    expect(find.text('Finish this work?'), findsOneWidget);
    expect(find.textContaining('Also delete the branch'), findsOneWidget);
    expect(find.textContaining('feat/x'), findsWidgets);
    expect(find.textContaining('Merged into main'), findsOneWidget);
  });

  testWidgets('the branch option is off by default', (tester) async {
    final adapter = _Bridge(branchInfo: _info());
    await _openDialog(tester, adapter);

    expect(tester.widget<CheckboxListTile>(_checkbox).value, isFalse);

    await tester.tap(_removeButton);
    await tester.pumpAndSettle();

    // The worktree goes; the branch is not touched.
    expect(adapter.paths, ['/branch-info', '/herdr']);
  });

  testWidgets('ticking a merged branch deletes it without force', (tester) async {
    final adapter = _Bridge(branchInfo: _info());
    await _openDialog(tester, adapter);

    await tester.tap(_checkbox);
    await tester.pumpAndSettle();
    await tester.tap(_removeAndDeleteButton);
    await tester.pumpAndSettle();

    expect(adapter.paths, ['/branch-info', '/herdr', '/branch-delete']);
    expect(adapter.bodyFor('/branch-delete'), {
      'repo_root': '/repos/demo',
      'branch': 'feat/x',
      'force': false,
    });
  });

  testWidgets('the worktree is removed before the branch is deleted', (tester) async {
    final adapter = _Bridge(branchInfo: _info());
    await _openDialog(tester, adapter);
    await tester.tap(_checkbox);
    await tester.pumpAndSettle();
    await tester.tap(_removeAndDeleteButton);
    await tester.pumpAndSettle();

    expect(
      adapter.paths.indexOf('/herdr') < adapter.paths.indexOf('/branch-delete'),
      isTrue,
      reason: 'git cannot delete a branch that is still checked out',
    );
  });

  testWidgets('a failed worktree removal never touches the branch', (tester) async {
    final adapter = _Bridge(branchInfo: _info(), removeStatus: 502);
    await _openDialog(tester, adapter);

    await tester.tap(_checkbox);
    await tester.pumpAndSettle();
    await tester.tap(_removeAndDeleteButton);
    await tester.pumpAndSettle();

    expect(adapter.paths, ['/branch-info', '/herdr']);
    expect(adapter.paths, isNot(contains('/branch-delete')));
  });

  testWidgets('an unmerged branch needs a second, different confirm', (tester) async {
    final adapter = _Bridge(
      branchInfo: _info(merged: false, mergedInto: '', unmergedCommits: 3),
    );
    await _openDialog(tester, adapter);

    expect(find.textContaining('Not merged into main'), findsOneWidget);
    expect(find.textContaining('3 commits would be lost'), findsOneWidget);

    await tester.tap(_checkbox);
    await tester.pumpAndSettle();

    // A distinct dialog, not the same tap.
    expect(find.text('Delete unmerged branch?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();

    // Declining leaves the box where it was.
    expect(tester.widget<CheckboxListTile>(_checkbox).value, isFalse);
    expect(_removeButton, findsOneWidget);
  });

  testWidgets('confirming the unmerged branch sends force', (tester) async {
    final adapter = _Bridge(
      branchInfo: _info(merged: false, mergedInto: '', unmergedCommits: 3),
      deleteBody: const {
        'branch': 'feat/x',
        'deleted': true,
        'forced': true,
        'merged': false,
        'sha': 'deadbee',
        'upstream': '',
        'remote_deleted': false,
      },
    );
    await _openDialog(tester, adapter);

    await tester.tap(_checkbox);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete anyway'));
    await tester.pumpAndSettle();

    expect(tester.widget<CheckboxListTile>(_checkbox).value, isTrue);
    await tester.tap(_removeAndDeleteButton);
    await tester.pumpAndSettle();

    expect(adapter.bodyFor('/branch-delete')?['force'], isTrue);
    // The outcome names the sha, the only way back to the dropped commits.
    expect(find.textContaining('was deadbee'), findsOneWidget);
  });

  testWidgets('a branch that cannot be deleted is named, not offered', (tester) async {
    final adapter = _Bridge(
      branchInfo: _info(
        deletable: false,
        blockedReason: '"feat/x" is checked out at /wt/other',
        checkedOutElsewhere: const ['/wt/other'],
      ),
    );
    await _openDialog(tester, adapter);

    expect(_checkbox, findsNothing);
    expect(find.textContaining('The branch feat/x is kept'), findsOneWidget);
    expect(find.textContaining('checked out at /wt/other'), findsOneWidget);

    await tester.tap(_removeButton);
    await tester.pumpAndSettle();
    expect(adapter.paths, isNot(contains('/branch-delete')));
  });

  testWidgets('an upstream is called out as surviving', (tester) async {
    await _openDialog(
      tester,
      _Bridge(branchInfo: _info(upstream: 'origin/feat/x')),
    );
    expect(
      find.textContaining('The remote branch origin/feat/x is never deleted'),
      findsOneWidget,
    );
  });

  testWidgets('a bridge with no branch endpoint keeps the old dialog', (tester) async {
    // A bridge older than /branch-info 404s. Removing a worktree must not get
    // harder because a side question could not be answered.
    final adapter = _Bridge(branchInfoStatus: 404);
    await _openDialog(tester, adapter);

    expect(_checkbox, findsNothing);
    expect(find.text('Finish this work?'), findsOneWidget);

    await tester.tap(_removeButton);
    await tester.pumpAndSettle();
    expect(adapter.paths, ['/branch-info', '/herdr']);
  });

  testWidgets('a refused branch delete reports the partial outcome', (tester) async {
    final adapter = _Bridge(
      branchInfo: _info(),
      deleteStatus: 409,
      deleteBody: const {'error': 'branch is not merged: feat/x has 2 commit(s) not in main'},
    );
    await _openDialog(tester, adapter);

    await tester.tap(_checkbox);
    await tester.pumpAndSettle();
    await tester.tap(_removeAndDeleteButton);
    // Deliberately not pumpAndSettle: that would run past the snackbar's own
    // duration and find nothing. Pump far enough for the two round-trips to
    // resolve and the bar to animate in, and no further.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Not a generic success, and not a bare error either: both halves.
    expect(find.textContaining('Work finished'), findsOneWidget);
    expect(find.textContaining('branch feat/x kept'), findsOneWidget);
    expect(find.textContaining('not merged'), findsOneWidget);
  });

  group('removeWorktreeSummary', () {
    test('a plain delete does not claim commits were dropped', () {
      final line = removeWorktreeSummary(
        BranchDeleteResult.fromJson(const {
          'branch': 'feat/x',
          'deleted': true,
          'forced': false,
          'merged': true,
          'sha': 'abc1234',
          'upstream': '',
          'remote_deleted': false,
        }),
      );
      expect(line, 'Work finished · branch feat/x deleted');
    });

    test('a forced delete says so and keeps the sha', () {
      final line = removeWorktreeSummary(
        BranchDeleteResult.fromJson(const {
          'branch': 'feat/x',
          'deleted': true,
          'forced': true,
          'merged': false,
          'sha': 'abc1234',
          'upstream': '',
          'remote_deleted': false,
        }),
      );
      expect(line, 'Work finished · unmerged branch feat/x deleted (was abc1234)');
    });

    test('an upstream is reported as left alone, never as deleted', () {
      final line = removeWorktreeSummary(
        BranchDeleteResult.fromJson(const {
          'branch': 'feat/x',
          'deleted': true,
          'forced': false,
          'merged': true,
          'sha': 'abc1234',
          'upstream': 'origin/feat/x',
          'remote_deleted': false,
        }),
      );
      expect(line, contains('origin/feat/x left on the remote'));
    });
  });

  test('branchKeptSummary reports both halves', () {
    expect(
      branchKeptSummary('feat/x', 'it is checked out at /wt/other'),
      'Work finished · branch feat/x kept: it is checked out at /wt/other',
    );
  });
}
