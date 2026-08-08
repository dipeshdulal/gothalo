import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection_providers.dart';
import 'package:gothalo/core/widgets/flat_app_bar.dart';
import 'package:gothalo/core/widgets/panel_row.dart';
import 'package:gothalo/data/bridge/bridge_providers.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/inbox/inbox_providers.dart' as inbox;
import 'package:gothalo/features/overview/overview_screen.dart';
import 'package:gothalo/features/priority/priority_providers.dart';
import 'package:gothalo/features/recents/recent_providers.dart';
import 'package:gothalo/features/servers/servers_screen.dart';

/// Content behind the frosted bar must still start below it.
///
/// The bar deliberately has the list running underneath — that is what makes
/// the blur worth having — so the scroll view's leading padding is the only
/// thing keeping the first row visible at rest. Get it wrong and the screen
/// looks fine the moment you scroll and wrong every time you open it, which is
/// how it shipped twice: once with the bar counted twice (a fifth of an empty
/// page), then once with it not counted at all (the PRIORITY header
/// permanently behind the bar).
///
/// The number is not the point — `FlatAppBar.padding` reads a MediaQuery that
/// `Scaffold` rewrites, so it depends on *where* the caller sits. This asserts
/// the outcome instead: on every screen that uses this bar, the first row is
/// below it at offset zero.

class _FixedSnapshot extends inbox.SnapshotController {
  _FixedSnapshot(this.snap);
  final Snapshot snap;
  @override
  Future<Snapshot> build() async => snap;
}

const _agent = Agent(
  agent: 'gemini',
  paneId: 'w1:p1',
  workspaceId: 'w1',
  agentStatus: AgentStatus.working,
  title: 'The first row on the page',
  cwd: '/d/projects/gothalo',
  branch: 'main',
);

final _snapshot = Snapshot(
  workspaces: const [WorkspaceInfo(workspaceId: 'w1', number: 1)],
  tabs: const [TabInfo(tabId: 'w1:t1', workspaceId: 'w1')],
  panes: const [
    Pane(
      paneId: 'w1:p1',
      tabId: 'w1:t1',
      workspaceId: 'w1',
      cwd: '/d/projects/gothalo',
    ),
  ],
  agents: const [_agent],
);

final _server = ServerSummary(
  id: 's1',
  name: 's1',
  baseUrl: 'http://s1',
  isActive: true,
);

/// A phone-shaped viewport with a status-bar inset — the case that broke.
/// Without an inset the two wrong formulas and the right one can agree.
Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 141, bottom: 72);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bridgeClientProvider.overrideWithValue(null),
        inbox.snapshotControllerProvider.overrideWith(
          () => _FixedSnapshot(_snapshot),
        ),
        serversProvider.overrideWith((ref) => Stream.value([_server])),
        serverAgentsProvider.overrideWith(
          (ref, id) async =>
              ServerAgents(server: _server, agents: const [_agent]),
        ),
        priorityHitsProvider.overrideWithValue(const []),
        recentHitsProvider.overrideWithValue(const []),
      ],
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pump();
  // Past the entrance cascade, so this measures the resting layout rather than
  // a row still 6px into its lift. Bounded rather than `pumpAndSettle`: the
  // per-server providers self-invalidate on a timer in the real app.
  await tester.pump(const Duration(milliseconds: 600));
}

/// The top edge of the first thing the list draws.
double _firstRowTop(WidgetTester tester) {
  final candidates = <double>[
    for (final e in find.byType(SectionLabel).evaluate())
      tester.getRect(find.byWidget(e.widget)).top,
    for (final e in find.byType(PanelRow).evaluate())
      tester.getRect(find.byWidget(e.widget)).top,
  ];
  expect(candidates, isNotEmpty, reason: 'nothing rendered to measure');
  return candidates.reduce((a, b) => a < b ? a : b);
}

void main() {
  // Home has no app bar — the greeting header owns the top, so the list only
  // needs to clear the device's own top inset (the status bar). The bar-backed
  // screens below assert against the bar instead.
  testWidgets('home starts its list below the top inset, at rest', (tester) async {
    await _pump(tester, const ServersScreen());

    final insetBottom = MediaQuery.of(
      tester.element(find.byType(Scaffold)),
    ).padding.top;
    expect(
      _firstRowTop(tester),
      greaterThanOrEqualTo(insetBottom),
      reason: 'home draws its first row under the status bar',
    );
    expect(tester.takeException(), isNull);
  });

  for (final (name, screen) in <(String, Widget)>[
    ('a project', const OverviewScreen(workspaceId: 'w1')),
    ('all projects', const OverviewScreen()),
  ]) {
    testWidgets('$name starts its list below the bar, at rest', (tester) async {
      await _pump(tester, screen);

      final barBottom = tester.getRect(find.byType(FlatAppBar)).bottom;
      expect(
        _firstRowTop(tester),
        greaterThanOrEqualTo(barBottom),
        reason: '$name draws its first row under the app bar',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
