import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_providers.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/agents/widgets/agent_row.dart';
import 'package:gothalo/features/inbox/inbox_providers.dart' as inbox;
import 'package:gothalo/features/jump/jump_sheet.dart';

/// Jump was the last screen with its own agent row and its own controls.
///
/// It is also the one where the keyboard mattered most: autofocusing the search
/// field raised it on open, which covered half the sheet and left three and a
/// half results visible on a screen whose whole job is scanning.

class _FixedSnapshot extends inbox.SnapshotController {
  _FixedSnapshot(this.snap);
  final Snapshot snap;
  @override
  Future<Snapshot> build() async => snap;
}

Agent _agent(String id, String title, AgentStatus status) => Agent(
  agent: 'gemini',
  paneId: id,
  workspaceId: 'w1',
  agentStatus: status,
  title: title,
  cwd: '/d/projects/gothalo',
  branch: 'main',
);

final _snapshot = Snapshot(
  workspaces: const [WorkspaceInfo(workspaceId: 'w1')],
  agents: [
    _agent('w1:p1', 'Blocked on a question', AgentStatus.blocked),
    _agent('w1:p2', 'Grinding away', AgentStatus.working),
    _agent('w1:p3', 'Parked', AgentStatus.idle),
  ],
);

Future<void> _open(WidgetTester tester, {String? current}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bridgeClientProvider.overrideWithValue(null),
        inbox.snapshotControllerProvider.overrideWith(
          () => _FixedSnapshot(_snapshot),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    showJumpSheet(context, currentPane: current),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The results list — the chip row above it is also a ListView.
final _results = find.byWidgetPredicate(
  (w) => w is ListView && w.scrollDirection == Axis.vertical,
);

void main() {
  testWidgets('it opens without raising the keyboard', (tester) async {
    await _open(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofocus, isFalse);
    expect(field.focusNode?.hasFocus ?? false, isFalse);
  });

  testWidgets('results are the shared agent row', (tester) async {
    await _open(tester);

    // Not a fifth bespoke row: no overlaid status dot, no trailing chevron.
    // `findsWidgets`, not a count — the sheet rests at half height and the
    // list is lazy, so how many are built depends on the viewport.
    expect(find.byType(AgentRow), findsWidgets);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('the agent you are already in is marked, not chevroned', (
    tester,
  ) async {
    await _open(tester, current: 'w1:p2');

    expect(find.text('HERE'), findsOneWidget);
  });

  testWidgets('a blocked result keeps its quick approve', (tester) async {
    await _open(tester);

    expect(find.widgetWithText(FilledButton, 'Approve'), findsOneWidget);
  });

  testWidgets('the filters and follow-on-host are the shared chips', (
    tester,
  ) async {
    await _open(tester);

    // Was a Material SegmentedButton plus an outlined FilterChip.
    expect(find.byType(SegmentedButton<Object?>), findsNothing);
    expect(find.byType(FilterChip), findsNothing);
    for (final label in ['All', 'Needs me', 'Working', 'Follow on host']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('a filter still filters', (tester) async {
    await _open(tester);

    await tester.tap(find.text('Needs me'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentRow), findsOneWidget);
    expect(find.text('Blocked on a question'), findsOneWidget);
  });

  testWidgets('typing still fuzzy-matches', (tester) async {
    await _open(tester);

    await tester.enterText(find.byType(TextField), 'grind');
    await tester.pumpAndSettle();

    expect(find.byType(AgentRow), findsOneWidget);
    expect(find.text('Grinding away'), findsOneWidget);
  });

  testWidgets('it rests at half the screen and can be pulled taller', (
    tester,
  ) async {
    await _open(tester);

    final screen = tester.getRect(find.byType(MaterialApp));
    final resting = tester.getRect(_results).height / screen.height;
    // Roughly half, not the 92% it used to open at.
    expect(resting, lessThan(0.7));

    // Dragging the results list up grows the sheet rather than doing nothing:
    // the list scrolls on the sheet's own controller, which is the wire.
    await tester.drag(find.byType(AgentRow).first, const Offset(0, -260));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(_results).height / screen.height,
      greaterThan(resting),
    );
  });

  testWidgets('focusing the field grows the sheet out from under the keyboard', (
    tester,
  ) async {
    await _open(tester);

    final before = tester.getRect(_results).height;
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    // Half a sheet minus a keyboard is a sliver of results; typing is the one
    // time the sheet should take the whole screen.
    expect(tester.getRect(_results).height, greaterThan(before));
  });
}
