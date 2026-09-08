import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/widgets/action_chip.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/agents/agent_lifecycle_providers.dart';
import 'package:gothalo/features/agents/start_agent_sheet.dart';
import 'package:gothalo/features/inbox/inbox_providers.dart' as inbox;
import 'package:gothalo/features/recents/recent_providers.dart';
import 'package:gothalo/core/connection/connection_providers.dart';

/// The launch sheet: what it opens on, and what it offers instead of typing.
///
/// It opens on the agent you last started, and never on nothing.
///
/// A person runs the same agent most of the time, so asking every launch is a
/// tap spent on a foregone conclusion — and an empty picker is worse, since the
/// first tap then carries no information at all. The memory is only ever a hint
/// though: the bridge's installed list is the sole authority on what may be
/// offered, so the interesting cases are not "it remembers" but what happens
/// when it remembers a kind this particular server does not have, and what it
/// falls back to when it remembers nothing.

class _FixedLastKind extends LastAgentKind {
  _FixedLastKind(this.kind);
  final String? kind;
  @override
  Future<String?> build() async => kind;
}

class _FixedSnapshot extends inbox.SnapshotController {
  _FixedSnapshot(this.snap);
  final Snapshot snap;
  @override
  Future<Snapshot> build() async => snap;
}

ServerSummary _server({bool active = true}) => ServerSummary(
      id: 's1',
      name: 's1',
      baseUrl: 'http://s1',
      isActive: active,
    );

/// A recent project whose panes put it at [cwd].
RecentSpaceHit _space(String workspaceId, String cwd, {bool active = true}) =>
    RecentSpaceHit(
      server: _server(active: active),
      workspaceId: workspaceId,
      workspace: WorkspaceInfo(workspaceId: workspaceId),
      project: cwd.split('/').last,
      branch: null,
      agentCount: 1,
      terminalCount: 0,
      needsAttention: false,
    );

Snapshot _snapshotWith(Map<String, String> workspaceCwds) => Snapshot(
      workspaces: [
        for (final id in workspaceCwds.keys) WorkspaceInfo(workspaceId: id),
      ],
      panes: [
        for (final e in workspaceCwds.entries)
          Pane(paneId: '${e.key}:p1', workspaceId: e.key, cwd: e.value),
      ],
    );

AvailableAgent _installed(String kind) =>
    AvailableAgent(kind: kind, path: '/usr/bin/$kind', stateReporting: true);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<String> installed,
  String? remembered,
  List<RecentSpaceHit> recentSpaces = const [],
  Map<String, String> workspaceCwds = const {},
  String defaultCwd = '/d/projects/gothalo',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        availableAgentsProvider.overrideWith(
          (ref) async => [for (final k in installed) _installed(k)],
        ),
        lastAgentKindProvider.overrideWith(() => _FixedLastKind(remembered)),
        recentSpaceHitsProvider.overrideWithValue(recentSpaces),
        inbox.snapshotControllerProvider.overrideWith(
          () => _FixedSnapshot(_snapshotWith(workspaceCwds)),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showStartAgentSheet(
                context,
                ref,
                target: StartAgentTarget(
                  placement: StartAgentPlacement.newTab,
                  id: 'w1',
                  where: 'A new tab in gothalo',
                  defaultCwd: defaultCwd,
                ),
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

/// The kind whose chip is selected, or null when none is.
String? _selected(WidgetTester tester) => tester
    .widgetList<ChoiceChip>(find.byType(ChoiceChip))
    .where((c) => c.selected)
    .map((c) => (c.label as Text).data)
    .firstOrNull;

bool _canStart(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null;

final _cwdField = find.ancestor(
  of: find.text('Working directory'),
  matching: find.byType(TextField),
);

void main() {
  testWidgets('the sheet opens on the agent you last started', (tester) async {
    await _pumpSheet(
      tester,
      installed: ['pi', 'claude', 'opencode'],
      remembered: 'claude',
    );

    expect(_selected(tester), 'claude');
    // The point of remembering: one tap on Start, none on the picker.
    expect(_canStart(tester), isTrue);
  });

  testWidgets('a remembered agent this server lacks does not win', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      installed: ['pi', 'claude'],
      remembered: 'codex',
    );

    // The installed list stays the only thing the picker may offer, so the
    // memory loses — selecting it would arm Start with a launch the host cannot
    // perform — and the fallback takes over rather than leaving nothing.
    expect(_selected(tester), 'pi');
  });

  testWidgets('with nothing remembered it opens on the first agent', (
    tester,
  ) async {
    await _pumpSheet(tester, installed: ['pi', 'claude']);

    // Herdr's own catalog order, which the picker preserves. A guess you can
    // see and change beats a picker that asks before it says anything.
    expect(_selected(tester), 'pi');
    expect(_canStart(tester), isTrue);
  });

  testWidgets('a server with no agents selects nothing and cannot start', (
    tester,
  ) async {
    await _pumpSheet(tester, installed: []);

    expect(_selected(tester), isNull);
    expect(_canStart(tester), isFalse);
  });

  testWidgets('recent projects are offered instead of typing a path', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      installed: ['pi'],
      recentSpaces: [_space('w1', '/d/projects/gothalo'), _space('w2', '/d/work/storefront')],
      workspaceCwds: {'w1': '/d/projects/gothalo', 'w2': '/d/work/storefront'},
    );

    // Labelled by the last segment, which is what tells them apart; the whole
    // path stays in the field and the tooltip.
    expect(find.widgetWithText(AppActionChip, 'gothalo'), findsOneWidget);
    expect(find.widgetWithText(AppActionChip, 'storefront'), findsOneWidget);
  });

  testWidgets('tapping a recent project fills the working directory', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      installed: ['pi'],
      recentSpaces: [_space('w2', '/d/work/storefront')],
      workspaceCwds: {'w2': '/d/work/storefront'},
    );
    await tester.tap(find.widgetWithText(AppActionChip, 'storefront'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(_cwdField).controller?.text,
      '/d/work/storefront',
    );
  });

  testWidgets('the directory already in the field reads as selected', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      installed: ['pi'],
      defaultCwd: '/d/work/storefront',
      recentSpaces: [_space('w2', '/d/work/storefront'), _space('w1', '/d/projects/gothalo')],
      workspaceCwds: {'w2': '/d/work/storefront', 'w1': '/d/projects/gothalo'},
    );

    // However it was set — tapped here or arrived with — one chip is current.
    final chips = tester.widgetList<AppActionChip>(
      find.byType(AppActionChip),
    );
    expect(chips.where((c) => c.active).map((c) => c.label), ['storefront']);
  });

  testWidgets('a recent project on another server is not offered', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      installed: ['pi'],
      recentSpaces: [_space('w2', '/d/work/storefront', active: false)],
      workspaceCwds: {'w2': '/d/work/storefront'},
    );

    // A path only means anything on the host that has it.
    expect(find.byType(AppActionChip), findsNothing);
  });

  testWidgets('picking an agent overrides what was remembered', (tester) async {
    await _pumpSheet(
      tester,
      installed: ['pi', 'claude'],
      remembered: 'claude',
    );
    await tester.tap(find.widgetWithText(ChoiceChip, 'pi'));
    await tester.pumpAndSettle();

    expect(_selected(tester), 'pi');
  });
}
