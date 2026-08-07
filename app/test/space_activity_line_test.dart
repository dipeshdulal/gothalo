import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/widgets/live_activity_line.dart';
import 'package:gothalo/data/bridge/bridge_providers.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
// Prefixed: Flutter's own `SnapshotController` (snapshot_widget.dart) is
// unrelated and would shadow the app's.
import 'package:gothalo/features/inbox/inbox_providers.dart' as inbox;
import 'package:gothalo/features/overview/overview_screen.dart';

/// The space page and the Flock list describe the same agents, so an agent that
/// reads as alive in one must read as alive in the other. Both mount the very
/// same [LiveActivityLine]; this pins the space side of that, because the way
/// the two screens drift is one of them quietly losing the line.

/// The snapshot the space page renders, with no live bridge behind it.
class _FixedSnapshot extends inbox.SnapshotController {
  _FixedSnapshot(this.snap);

  final Snapshot snap;

  @override
  Future<Snapshot> build() async => snap;
}

const _agentPane = 'w1:p1';
const _shellPane = 'w1:p2';

final _snapshot = Snapshot(
  workspaces: const [WorkspaceInfo(workspaceId: 'w1', label: 'gothalo')],
  tabs: const [TabInfo(tabId: 'w1:t1', workspaceId: 'w1', label: 't1')],
  panes: const [
    Pane(
      paneId: _agentPane,
      tabId: 'w1:t1',
      workspaceId: 'w1',
      title: 'Ship the space activity line',
      agentStatus: AgentStatus.idle,
      cwd: '/Users/d/projects/gothalo',
    ),
    Pane(
      paneId: _shellPane,
      tabId: 'w1:t1',
      workspaceId: 'w1',
      title: 'd@mac:~/projects/gothalo',
      cwd: '/Users/d/projects/gothalo',
    ),
  ],
  // `gemini` rather than `claude`: it has no bundled logo, so the tile draws a
  // branded initial instead of decoding a PNG mid-test.
  agents: const [
    Agent(
      agent: 'gemini',
      paneId: _agentPane,
      tabId: 'w1:t1',
      workspaceId: 'w1',
      agentStatus: AgentStatus.idle,
      title: 'Ship the space activity line',
    ),
  ],
);

Future<void> _pumpSpace(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // No bridge: the line mounts and its poll gives up immediately, which
        // is exactly the "nothing to show yet" path the tile has to survive.
        bridgeClientProvider.overrideWithValue(null),
        inbox.snapshotControllerProvider
            .overrideWith(() => _FixedSnapshot(_snapshot)),
      ],
      child: const MaterialApp(home: OverviewScreen(workspaceId: 'w1')),
    ),
  );
  await tester.pump(); // resolve the snapshot future
}

void main() {
  testWidgets('a space shows the agent activity line, on the agent pane only', (
    tester,
  ) async {
    await _pumpSpace(tester);

    final lines = tester.widgetList<LiveActivityLine>(
      find.byType(LiveActivityLine),
    );
    expect(lines.length, 1);
    // Same widget, same pane, same status the Flock list feeds it — the line
    // itself is what derives the text, so neither screen can re-derive it.
    expect(lines.single.paneId, _agentPane);
    expect(lines.single.status, AgentStatus.idle);
  });

  testWidgets('an agent with no message yet keeps its card intact', (
    tester,
  ) async {
    await _pumpSpace(tester);

    // The task title still reads in full: an empty line reserves its height
    // rather than collapsing, so the card does not resettle when a message
    // lands (or fails to).
    expect(find.text('Ship the space activity line'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
