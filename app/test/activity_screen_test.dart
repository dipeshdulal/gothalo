import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/widgets/panel_row.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/data/bridge/bridge_providers.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/inbox/inbox_providers.dart' as inbox;
import 'package:gothalo/features/timeline/timeline_providers.dart';
import 'package:gothalo/features/timeline/timeline_screen.dart';

/// The Activity screen is the fourth surface that lists agents, and it was the
/// one the vocabulary rework missed: it printed `wN:p42` on every row and drew
/// status as raw blue text on bare rows. These pin that it speaks the same
/// language as the other three.

class _FixedSnapshot extends inbox.SnapshotController {
  _FixedSnapshot(this.snap);
  final Snapshot snap;
  @override
  Future<Snapshot> build() async => snap;
}

const _pane = 'w1E:p1';
const _shellPane = 'w1E:p9';

final _snapshot = Snapshot(
  panes: const [
    Pane(paneId: _pane, workspaceId: 'w1E', cwd: '/d/projects/gothalo'),
    Pane(
      paneId: _shellPane,
      workspaceId: 'w1E',
      title: 'npm run dev',
      cwd: '/d/projects/gothalo/app',
    ),
  ],
  agents: const [
    Agent(
      agent: 'gemini',
      paneId: _pane,
      workspaceId: 'w1E',
      agentStatus: AgentStatus.working,
      title: 'Rework the activity screen',
      cwd: '/d/projects/gothalo',
      branch: 'feat/ui-foundation',
    ),
  ],
);

TimelineEntry _entry(String pane, String to, {String? from, String? title}) =>
    TimelineEntry.fromJson({
      'at': DateTime(2026, 8, 8, 14, 30).toIso8601String(),
      'pane': pane,
      'agent': 'gemini',
      'title': title,
      'from': from,
      'to': to,
      'prev_ms': 35000,
    });

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bridgeClientProvider.overrideWithValue(null),
        inbox.snapshotControllerProvider.overrideWith(
          () => _FixedSnapshot(_snapshot),
        ),
        activityTimelineProvider.overrideWith(
          (ref) async => [
            _entry(_pane, 'working',
                from: 'idle', title: 'Rework the activity screen'),
            _entry(_shellPane, 'idle'),
          ],
        ),
      ],
      child: const MaterialApp(home: TimelineScreen()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

List<String> _texts(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];

void main() {
  testWidgets('it never prints a pane id', (tester) async {
    await _pump(tester);

    for (final text in _texts(tester)) {
      expect(text, isNot(contains(_pane)), reason: 'leaked in "$text"');
      expect(text, isNot(contains(_shellPane)), reason: 'leaked in "$text"');
    }
  });

  testWidgets('it names the project instead', (tester) async {
    await _pump(tester);

    // The same identifier the agent rows use, from the live snapshot — the
    // timeline payload carries no cwd of its own.
    expect(find.text('gothalo · feat/ui-foundation'), findsOneWidget);
  });

  testWidgets('a pane with no agent is named as a terminal', (tester) async {
    await _pump(tester);

    expect(find.text('npm run dev · app'), findsOneWidget);
  });

  testWidgets('rows sit in a panel, like every other list', (tester) async {
    await _pump(tester);

    expect(find.byType(PanelList), findsWidgets);
  });

  testWidgets('status reads like status does everywhere else', (tester) async {
    await _pump(tester);

    // Uppercase mono marks, not Material-blue bold prose.
    expect(find.text('WORKING'), findsOneWidget);
    expect(find.text('IDLE'), findsWidgets);
    // The `from` state too, so a transition reads IDLE → WORKING in one
    // register rather than muted prose into a coloured word.
    expect(
      tester
          .widgetList<Text>(find.text('IDLE'))
          .every((t) => t.style?.fontFamily != null),
      isTrue,
    );
  });
}
