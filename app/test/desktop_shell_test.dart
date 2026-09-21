import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gothalo/core/adaptive.dart';
import 'package:gothalo/core/connection/connection.dart';
import 'package:gothalo/core/connection/connection_providers.dart';
import 'package:gothalo/core/shell/desktop_shell.dart';
import 'package:gothalo/core/theme.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/agents/widgets/agent_row.dart';
import 'package:gothalo/features/inbox/inbox_providers.dart' as inbox;

class _FixedSnapshot extends inbox.SnapshotController {
  _FixedSnapshot(this.snap);
  final Snapshot snap;
  @override
  Future<Snapshot> build() async => snap;
}

const _server = Connection(
  id: 's1',
  name: 'Studio',
  baseUrl: 'http://studio',
  bearer: 'test',
);

Agent _agent(String pane, String title, AgentStatus status) => Agent(
  agent: 'claude',
  paneId: pane,
  workspaceId: 'w1',
  agentStatus: status,
  title: title,
  cwd: '/Users/dev/projects/acme-app',
  branch: 'main',
);

Future<void> _pumpShell(
  WidgetTester tester, {
  required Size size,
  required String location,
  List<Agent>? agents,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final snap = Snapshot(
    agents:
        agents ??
        [
          _agent('w1:p1', 'Delete the stale branches?', AgentStatus.blocked),
          _agent('w1:p2', 'Porting the settings screen', AgentStatus.working),
        ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeConnectionProvider.overrideWith((ref) async => _server),
        inbox.snapshotControllerProvider.overrideWith(
          () => _FixedSnapshot(snap),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: DesktopShell(
          location: location,
          child: const Scaffold(body: Center(child: Text('the screen'))),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a phone window gets the routed screen and no shell', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      size: const Size(390, 844),
      location: '/transcript/w1:p1',
    );

    expect(find.text('the screen'), findsOneWidget);
    expect(find.text('FLOCK'), findsNothing);
    expect(find.text('HOME'), findsNothing);
  });

  testWidgets('a desktop window shows the nav rail', (tester) async {
    await _pumpShell(
      tester,
      size: const Size(1280, 800),
      location: '/inbox',
    );

    expect(find.text('the screen'), findsOneWidget);
    for (final label in const ['HOME', 'FLOCK', 'PRIORITY', 'PROJECTS', 'ACTIVITY']) {
      expect(find.text(label), findsOneWidget, reason: '$label in the rail');
    }
  });

  testWidgets('a detail route pairs the agent list with the screen', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      size: const Size(1280, 800),
      location: '/transcript/w1:p1',
    );

    // The screen is still there...
    expect(find.text('the screen'), findsOneWidget);
    // ...and the flock sits beside it, with the open pane's row lifted.
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Delete the stale branches?'), findsOneWidget);
    expect(find.text('Porting the settings screen'), findsOneWidget);
  });

  testWidgets('the desktop flock shows every agent, with no expander', (
    tester,
  ) async {
    // Nine idle agents is the ordinary case; on a phone the section would cap
    // at three behind a "Show 6 more". The desktop panel is tall enough to show
    // them, so it does — and a control that hides nothing would just be a label.
    final idlers = [
      for (var i = 1; i <= 9; i++)
        _agent('w1:i$i', 'Idle task $i', AgentStatus.idle),
    ];
    await _pumpShell(
      tester,
      size: const Size(1280, 900),
      location: '/transcript/w1:i1',
      agents: idlers,
    );

    for (var i = 1; i <= 9; i++) {
      expect(find.text('Idle task $i'), findsOneWidget);
    }
    expect(find.byType(SectionExpander), findsNothing);
  });

  testWidgets('a list route does not draw the agent list twice', (
    tester,
  ) async {
    await _pumpShell(tester, size: const Size(1280, 800), location: '/inbox');

    // The rail is there, but the flock panel is not: /inbox is the list.
    expect(find.text('FLOCK'), findsOneWidget);
    expect(find.text('Delete the stale branches?'), findsNothing);
  });

  testWidgets('DesktopWidth caps desktop content and passes phones through', (
    tester,
  ) async {
    Future<double> widthAt(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopWidth(
              child: Row(
                children: const [Expanded(child: Text('content'))],
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.text('content')).width;
    }

    expect(await widthAt(const Size(390, 844)), 390);
    expect(await widthAt(const Size(1280, 800)), 880);
  });

  testWidgets('the shell builder sees the full child location', (tester) async {
    // The desktop shell decides whether to show the agent list from the location
    // it is handed, so this pins the go_router behaviour it depends on: a shell
    // sees the child route's URI, not just the shell's own prefix.
    final seen = <String>[];
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        ShellRoute(
          builder: (context, state, child) {
            seen.add(state.uri.toString());
            return child;
          },
          routes: [
            GoRoute(path: '/', builder: (context, state) => const Text('home')),
            GoRoute(
              path: '/transcript/:pane',
              builder: (context, state) =>
                  Text('pane ${state.pathParameters['pane']}'),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(seen.last, '/');

    router.push('/transcript/w1%3Ap1');
    await tester.pumpAndSettle();
    // The shell receives the child location, and the pane id survives the trip
    // in a form `Uri.pathSegments` can decode back to `w1:p1` — which is the
    // exact thing DesktopShell does with it.
    expect(seen.last, startsWith('/transcript/'));
    expect(Uri.parse(seen.last).pathSegments, ['transcript', 'w1:p1']);
    expect(find.text('pane w1:p1'), findsOneWidget);
  });
}
