import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/widgets/panel_row.dart';
import 'package:gothalo/data/bridge/bridge_providers.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/agents/widgets/agent_row.dart';
import 'package:gothalo/features/inbox/inbox_providers.dart' as inbox;
import 'package:gothalo/features/inbox/inbox_screen.dart';

/// Flock and home are the same list at two scopes.
///
/// They used to be two implementations, so the same agent looked like a
/// different thing depending on which screen you had reached it from — which is
/// exactly what #106 exists to stop. This pins that the per-server screen goes
/// through the shared sections: same headings, same rows, same idle compaction,
/// same caps. If someone forks the list again, this fails.

class _FixedSnapshot extends inbox.SnapshotController {
  _FixedSnapshot(this.snap);
  final Snapshot snap;
  @override
  Future<Snapshot> build() async => snap;
}

Agent _agent(String id, {required String title, required AgentStatus status}) =>
    Agent(
      // No bundled logo, so the row draws an initial rather than decoding a PNG.
      agent: 'gemini',
      paneId: id,
      agentStatus: status,
      title: title,
      cwd: '/Users/d/projects/gothalo',
      branch: 'main',
    );

final _snapshot = Snapshot(
  workspaces: const [WorkspaceInfo(workspaceId: 'w1', label: 'gothalo')],
  panes: const [Pane(paneId: 'w1:p1', workspaceId: 'w1')],
  agents: [
    _agent('w1:b1', title: 'Waiting on you', status: AgentStatus.blocked),
    _agent('w1:w1', title: 'Chewing through it', status: AgentStatus.working),
    for (var i = 0; i < 9; i++)
      _agent('w1:i$i', title: 'Parked $i', status: AgentStatus.idle),
  ],
);

Future<void> _pumpFlock(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bridgeClientProvider.overrideWithValue(null),
        inbox.snapshotControllerProvider.overrideWith(
          () => _FixedSnapshot(_snapshot),
        ),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ),
  );
  await tester.pump();
}

List<String> _sections(WidgetTester tester) => tester
    .widgetList<SectionLabel>(find.byType(SectionLabel))
    .map((s) => s.text)
    .toList();

void main() {
  testWidgets('the flock is sectioned exactly like home', (tester) async {
    await _pumpFlock(tester);

    expect(_sections(tester), ['Needs you', 'Working', 'Idle']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('it renders the shared row, not a flock-only one', (
    tester,
  ) async {
    await _pumpFlock(tester);

    expect(find.byType(AgentRow), findsWidgets);
    // The server is implied by the screen, so it is not repeated on every row.
    for (final row in tester.widgetList<AgentRow>(find.byType(AgentRow))) {
      expect(row.serverName, isNull);
    }
  });

  testWidgets('it does not show everything at once', (tester) async {
    await _pumpFlock(tester);

    // Nine idle agents, capped like home's — collapsed on open.
    final compact = tester
        .widgetList<AgentRow>(find.byType(AgentRow))
        .where((r) => r.compact)
        .length;
    expect(compact, 6);
    expect(find.text('Show 3 more'), findsOneWidget);

    // The expander sits at the foot of a long list on a short test viewport;
    // tapping it blind would hit whatever is actually at those coordinates.
    await tester.ensureVisible(find.text('Show 3 more'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show 3 more'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widgetList<AgentRow>(find.byType(AgentRow))
          .where((r) => r.compact)
          .length,
      9,
    );
  });

  testWidgets('a blocked agent keeps its one-tap approve here', (tester) async {
    await _pumpFlock(tester);

    // The per-agent action the flock has always had, carried by the shared row
    // as a flag rather than by a second row implementation.
    expect(find.widgetWithText(FilledButton, 'Approve'), findsOneWidget);
  });

  testWidgets('the quick actions are one scrollable line of chips', (
    tester,
  ) async {
    await _pumpFlock(tester);

    expect(find.text('Open a project'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    // A single workspace is unambiguous, so the project-scoped actions can act
    // and therefore appear.
    expect(find.text('New terminal'), findsOneWidget);
  });

  testWidgets('projects group a repo with its worktrees, in one panel', (
    tester,
  ) async {
    // One repo checked out plainly, plus two worktrees of it.
    const snap = Snapshot(
      workspaces: [
        WorkspaceInfo(workspaceId: 'w1', number: 1),
        WorkspaceInfo(workspaceId: 'w2', number: 2),
        WorkspaceInfo(workspaceId: 'w3', number: 3),
      ],
      panes: [
        Pane(paneId: 'w1:p1', workspaceId: 'w1', cwd: '/d/projects/gothalo'),
        Pane(
          paneId: 'w2:p1',
          workspaceId: 'w2',
          cwd: '/d/.herdr/worktrees/gothalo/feat-x',
        ),
        Pane(
          paneId: 'w3:p1',
          workspaceId: 'w3',
          cwd: '/d/.herdr/worktrees/gothalo/permission-check',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bridgeClientProvider.overrideWithValue(null),
          inbox.snapshotControllerProvider.overrideWith(
            () => _FixedSnapshot(snap),
          ),
        ],
        child: const MaterialApp(home: InboxScreen()),
      ),
    );
    await tester.pump();
    await tester.tap(find.textContaining('Projects'));
    await tester.pumpAndSettle();

    // One panel for the repo and both its branches — not three boxes. A dozen
    // projects each carrying their own outline read as a grid, which is the
    // complaint this fixes; the edge is unchanged, there is one of it.
    expect(find.byType(PanelList), findsOneWidget);
    expect(find.text('gothalo'), findsOneWidget);
    expect(find.text('feat-x'), findsOneWidget);
    expect(find.text('permission-check'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
