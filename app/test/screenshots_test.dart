@Tags(['screenshots'])
library;

// Renders README screenshots from fabricated data.
//
// Screenshots are generated, never captured from a real device: a real one
// would carry live workspace names, server names and tailnet hosts into a
// public repo. Everything below is invented, so the images are safe to publish
// and anyone can regenerate them:
//
//   flutter test test/screenshots_test.dart --update-goldens
//
// Tagged `screenshots` and excluded from CI: golden comparison is
// pixel-exact, and Linux runners rasterise fonts differently from macOS, so
// these would fail everywhere but the machine that generated them.
//
// Output lands in docs/screenshots/ and is referenced by the README.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection_providers.dart';
import 'package:gothalo/core/theme.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/priority/priority_providers.dart';
import 'package:gothalo/features/recents/recent_providers.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/data/bridge/bridge_providers.dart';
import 'package:gothalo/features/inbox/inbox_providers.dart' as inbox;
import 'package:gothalo/features/servers/servers_screen.dart';
import 'package:gothalo/features/timeline/timeline_providers.dart';
import 'package:gothalo/features/timeline/timeline_screen.dart';

const _phone = Size(1080, 2100);

class _FixedSnapshot extends inbox.SnapshotController {
  _FixedSnapshot(this.snap);
  final Snapshot snap;
  @override
  Future<Snapshot> build() async => snap;
}

TimelineEntry _entry(
  String pane,
  String to, {
  String? from,
  String? title,
  required String agent,
  int minutesAgo = 0,
}) => TimelineEntry.fromJson({
  'ts': DateTime.now().subtract(Duration(minutes: minutesAgo)).millisecondsSinceEpoch,
  'pane': pane,
  'agent': agent,
  'title': title,
  'from': from,
  'to': to,
  'prev_ms': 35000 + minutesAgo * 1000,
});

ServerSummary _server() => const ServerSummary(
  id: 's1',
  name: 'Studio',
  baseUrl: 'http://studio',
  isActive: true,
);

Agent _agent(
  String paneId, {
  required String title,
  required String agent,
  AgentStatus status = AgentStatus.idle,
  String branch = 'main',
  String cwd = '/Users/dev/projects/acme-app',
}) => Agent(
  agent: agent,
  paneId: paneId,
  agentStatus: status,
  title: title,
  cwd: cwd,
  branch: branch,
);

/// Flutter ships MaterialIcons outside the app bundle, and widget tests do not
/// load it — every `Icon` renders as an empty box without this.
Future<void> _loadMaterialIcons() async {
  final root = Platform.environment['FLUTTER_ROOT'] ??
      (() {
        var d = File(Platform.resolvedExecutable).parent;
        while (d.path != d.parent.path) {
          if (Directory('${d.path}/bin/cache/artifacts/material_fonts').existsSync()) {
            return d.path;
          }
          d = d.parent;
        }
        return '';
      })();
  final f = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (!f.existsSync()) return;
  final loader = FontLoader('MaterialIcons')
    ..addFont(f.readAsBytes().then((b) => ByteData.view(b.buffer)));
  await loader.load();
}

Future<void> _loadFonts() async {
  await _loadMaterialIcons();
  for (final family in const {
    'Inter': [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ],
    // Family names must match pubspec exactly — "JetBrains Mono" has a space,
    // and a mismatch renders every monospace run as filled blocks.
    'JetBrains Mono': [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-Bold.ttf',
    ],
  }.entries) {
    final loader = FontLoader(family.key);
    for (final path in family.value) {
      loader.addFont(
        File(path).readAsBytes().then((b) => ByteData.view(b.buffer)),
      );
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('home', (tester) async {
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final blocked = _agent(
      'w1:p1',
      agent: 'claude',
      title: 'Delete the stale release branches?',
      status: AgentStatus.blocked,
      branch: 'feat/cleanup',
    );
    final working = _agent(
      'w1:p2',
      agent: 'codex',
      title: 'Porting the settings screen',
      status: AgentStatus.working,
      branch: 'feat/settings',
    );
    final done = _agent(
      'w2:p1',
      agent: 'claude',
      title: 'Add retry to the upload queue',
      status: AgentStatus.done,
      branch: 'fix/upload-retry',
      cwd: '/Users/dev/projects/storefront',
    );
    final idle = [
      _agent(
        'w2:p4',
        agent: 'pi',
        title: 'Draft the migration notes',
        branch: 'docs/migration',
        cwd: '/Users/dev/projects/storefront',
      ),
      _agent(
        'w3:p1',
        agent: 'claude',
        title: 'Bump the Go toolchain',
        branch: 'chore/go-1-26',
      ),
      _agent(
        'w3:p2',
        agent: 'hermes',
        title: 'Trim the flaky timer tests',
        branch: 'fix/flaky-timers',
      ),
    ];

    final server = _server();
    final agents = [blocked, working, done, ...idle];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serversProvider.overrideWith((ref) => Stream.value([server])),
          serverAgentsProvider.overrideWith(
            (ref, id) async => ServerAgents(server: server, agents: agents),
          ),
          priorityHitsProvider.overrideWithValue([
            for (final a in [blocked, done])
              PriorityHit(
                server: server,
                agent: a,
                starred: false,
                reachable: true,
              ),
          ]),
          recentHitsProvider.overrideWithValue([
            RecentHit(
              server: server,
              agent: working,
              view: OpenedView.transcript,
            ),
          ]),
          recentSpaceHitsProvider.overrideWithValue(const []),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark,
          home: const ServersScreen(),
        ),
      ),
    );
    // Decode the bundled agent logos for real. Widget tests skip async image
    // work by default, which leaves every avatar an empty circle and makes the
    // screenshot look like a mock rather than the app.
    await tester.runAsync(() async {
      for (final a in const [
        'assets/agents/claude.png',
        'assets/agents/codex.png',
        'assets/agents/pi.png',
        'assets/agents/hermes.png',
      ]) {
        await precacheImage(AssetImage(a), tester.element(find.byType(ServersScreen)));
      }
    });
    // Rows enter on a staggered animation; settle it so idle actually paints.
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    await expectLater(
      find.byType(ServersScreen),
      matchesGoldenFile('../../docs/screenshots/home.png'),
    );
  });

  testWidgets('activity', (tester) async {
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    const p1 = 'w1:p1';
    const p2 = 'w1:p2';
    const p3 = 'w2:p1';
    final snap = Snapshot(
      panes: const [
        Pane(paneId: p1, workspaceId: 'w1', cwd: '/Users/dev/projects/acme-app'),
        Pane(paneId: p2, workspaceId: 'w1', cwd: '/Users/dev/projects/acme-app'),
        Pane(paneId: p3, workspaceId: 'w2', cwd: '/Users/dev/projects/storefront'),
      ],
      agents: const [
        Agent(
          agent: 'claude',
          paneId: p1,
          workspaceId: 'w1',
          agentStatus: AgentStatus.blocked,
          title: 'Delete the stale release branches?',
          cwd: '/Users/dev/projects/acme-app',
          branch: 'feat/cleanup',
        ),
        Agent(
          agent: 'codex',
          paneId: p2,
          workspaceId: 'w1',
          agentStatus: AgentStatus.working,
          title: 'Porting the settings screen',
          cwd: '/Users/dev/projects/acme-app',
          branch: 'feat/settings',
        ),
        Agent(
          agent: 'pi',
          paneId: p3,
          workspaceId: 'w2',
          agentStatus: AgentStatus.done,
          title: 'Add retry to the upload queue',
          cwd: '/Users/dev/projects/storefront',
          branch: 'fix/upload-retry',
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
          activityTimelineProvider.overrideWith(
            (ref) async => [
              _entry(p1, 'blocked',
                  from: 'working',
                  agent: 'claude',
                  title: 'Delete the stale release branches?',
                  minutesAgo: 4),
              _entry(p3, 'done',
                  from: 'working',
                  agent: 'pi',
                  title: 'Add retry to the upload queue',
                  minutesAgo: 26),
              _entry(p2, 'working',
                  from: 'idle',
                  agent: 'codex',
                  title: 'Porting the settings screen',
                  minutesAgo: 51),
              _entry(p1, 'working',
                  from: 'idle',
                  agent: 'claude',
                  title: 'Delete the stale release branches?',
                  minutesAgo: 88),
            ],
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark,
          home: const TimelineScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      for (final a in const [
        'assets/agents/claude.png',
        'assets/agents/codex.png',
        'assets/agents/pi.png',
      ]) {
        await precacheImage(
            AssetImage(a), tester.element(find.byType(TimelineScreen)));
      }
    });
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    await expectLater(
      find.byType(TimelineScreen),
      matchesGoldenFile('../../docs/screenshots/activity.png'),
    );
  });
}
