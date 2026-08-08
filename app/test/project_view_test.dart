import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_providers.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
// Prefixed: Flutter's own `SnapshotController` (snapshot_widget.dart) is
// unrelated and would shadow the app's.
import 'package:gothalo/features/inbox/inbox_providers.dart' as inbox;
import 'package:gothalo/features/overview/overview_screen.dart';

/// The overview reads as **projects**, not as the multiplexer.
///
/// It used to draw Herdr's own shape — workspace → tab → pane, with a tab strip
/// across a single space. What it has to render now is: a project, the agents
/// in it, and the terminals in it. The failure this guards against is the tree
/// creeping back, and the sharper one is a pane id or a `w8` turning up as a
/// label: both are invisible in code review and obvious on a phone.

class _FixedSnapshot extends inbox.SnapshotController {
  _FixedSnapshot(this.snap);

  final Snapshot snap;

  @override
  Future<Snapshot> build() async => snap;
}

const _agentPane = 'w1:p1';
const _shellPane = 'w1:p2';
const _devServerPane = 'w1:p3';
const _worktreeAgentPane = 'w2:p1';

/// One project checked out at `main`, plus a worktree of the same repo on a
/// branch — the ordinary shape of a machine with work in flight.
final _snapshot = Snapshot(
  workspaces: const [
    WorkspaceInfo(
      workspaceId: 'w1',
      label: 'w1',
      number: 1,
      worktree: WorktreeInfo(
        checkoutPath: '/Users/d/projects/gothalo',
        repoName: 'gothalo',
      ),
    ),
    WorkspaceInfo(
      workspaceId: 'w2',
      label: 'w2',
      number: 2,
      worktree: WorktreeInfo(
        checkoutPath: '/Users/d/.herdr/worktrees/gothalo/feat-x',
        repoName: 'gothalo',
        isLinkedWorktree: true,
      ),
    ),
  ],
  tabs: const [
    TabInfo(tabId: 'w1:t1', workspaceId: 'w1', label: '', paneCount: 1),
    TabInfo(tabId: 'w1:t2', workspaceId: 'w1', label: '', paneCount: 2),
    TabInfo(tabId: 'w2:t1', workspaceId: 'w2', label: '', paneCount: 1),
  ],
  panes: const [
    Pane(
      paneId: _agentPane,
      tabId: 'w1:t1',
      workspaceId: 'w1',
      title: 'Ship the project view',
      agentStatus: AgentStatus.idle,
      cwd: '/Users/d/projects/gothalo',
    ),
    // Two panes share w1:t2 — a split. Renaming is not offered on either.
    Pane(
      paneId: _shellPane,
      tabId: 'w1:t2',
      workspaceId: 'w1',
      title: 'd@mac:~/projects/gothalo',
      cwd: '/Users/d/projects/gothalo',
    ),
    Pane(
      paneId: _devServerPane,
      tabId: 'w1:t2',
      workspaceId: 'w1',
      title: 'npm run dev',
      cwd: '/Users/d/projects/gothalo/app',
    ),
    Pane(
      paneId: _worktreeAgentPane,
      tabId: 'w2:t1',
      workspaceId: 'w2',
      title: 'Rework the vocabulary',
      agentStatus: AgentStatus.blocked,
      cwd: '/Users/d/.herdr/worktrees/gothalo/feat-x',
    ),
  ],
  // `gemini` rather than `claude`: it has no bundled logo, so the row draws a
  // branded initial instead of decoding a PNG mid-test.
  agents: const [
    Agent(
      agent: 'gemini',
      paneId: _agentPane,
      tabId: 'w1:t1',
      workspaceId: 'w1',
      agentStatus: AgentStatus.idle,
      title: 'Ship the project view',
      cwd: '/Users/d/projects/gothalo',
    ),
    Agent(
      agent: 'gemini',
      paneId: _worktreeAgentPane,
      tabId: 'w2:t1',
      workspaceId: 'w2',
      agentStatus: AgentStatus.blocked,
      title: 'Rework the vocabulary',
      cwd: '/Users/d/.herdr/worktrees/gothalo/feat-x',
    ),
  ],
);

Future<void> _pump(WidgetTester tester, {String? workspaceId}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // No bridge: the live activity line mounts and its poll gives up
        // immediately, which is the "nothing to show yet" path every row has to
        // survive anyway.
        bridgeClientProvider.overrideWithValue(null),
        inbox.snapshotControllerProvider.overrideWith(
          () => _FixedSnapshot(_snapshot),
        ),
      ],
      child: MaterialApp(home: OverviewScreen(workspaceId: workspaceId)),
    ),
  );
  await tester.pump(); // resolve the snapshot future
}

/// Every string rendered anywhere on screen.
List<String> _texts(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];

void main() {
  group('one project', () {
    testWidgets('reads as agents and terminals, not as tabs', (tester) async {
      await _pump(tester, workspaceId: 'w1');

      // SectionLabel uppercases, which is the language's heading style.
      expect(find.text('AGENTS'), findsOneWidget);
      expect(find.text('TERMINALS'), findsOneWidget);
      // The tab strip is gone: it grouped a project's panes by a layout detail
      // of a screen nobody is looking at, hiding all but one group at a time.
      expect(find.byType(TabBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('names terminals for what runs in them and where', (
      tester,
    ) async {
      await _pump(tester, workspaceId: 'w1');

      expect(find.text('shell · gothalo'), findsOneWidget);
      expect(find.text('npm run dev · app'), findsOneWidget);
    });

    testWidgets('shows no pane, tab or workspace id anywhere', (tester) async {
      await _pump(tester, workspaceId: 'w1');

      for (final text in _texts(tester)) {
        for (final id in [_agentPane, _shellPane, _devServerPane, 'w1:t1', 'w1:t2']) {
          expect(text, isNot(contains(id)), reason: 'leaked "$id" in "$text"');
        }
      }
      // A bare workspace id is the other tell. `w1` on its own must not be a
      // label; `gothalo` is.
      expect(_texts(tester), isNot(contains('w1')));
    });

    testWidgets('keeps every agent and terminal on one scroll', (tester) async {
      await _pump(tester, workspaceId: 'w1');

      expect(find.text('Ship the project view'), findsOneWidget);
      expect(find.text('shell · gothalo'), findsOneWidget);
      expect(find.text('npm run dev · app'), findsOneWidget);
    });
  });

  group('all projects', () {
    testWidgets('heads each project with its repo and branch', (tester) async {
      await _pump(tester);

      // Two workspaces of one repo: the checkout and the worktree, each named
      // for the repo, the worktree additionally by its branch.
      expect(find.text('gothalo'), findsNWidgets(2));
      expect(find.text('feat-x'), findsOneWidget);
      // Never the workspace id.
      expect(_texts(tester), isNot(contains('w2')));
    });

    testWidgets('counts what a project holds, not its panes and tabs', (
      tester,
    ) async {
      await _pump(tester);

      expect(find.text('1 agent · 2 terminals'), findsOneWidget);
      expect(find.text('1 agent'), findsOneWidget);
    });

    testWidgets('floats what needs you above the projects', (tester) async {
      await _pump(tester);

      expect(find.text('NEEDS YOU'), findsOneWidget);
      // The blocked agent appears twice: once in Needs you, once under its own
      // project — the section is a shortcut into the list below it, not a
      // replacement for it.
      expect(find.text('Rework the vocabulary'), findsNWidgets(2));
    });

    testWidgets('a project that needs you sorts first', (tester) async {
      await _pump(tester);

      final headings = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      // The worktree holds the blocked agent, so its branch label appears
      // before the other project's terminals.
      expect(
        headings.indexOf('feat-x'),
        lessThan(headings.indexOf('shell · gothalo')),
      );
    });
  });
}
