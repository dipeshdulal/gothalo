import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection_providers.dart';
import 'package:gothalo/core/widgets/entrance.dart';
import 'package:gothalo/core/widgets/panel_row.dart';
import 'package:gothalo/core/widgets/status_mark.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/agents/agent_groups.dart';
import 'package:gothalo/features/agents/widgets/agent_row.dart';
import 'package:gothalo/features/priority/priority_providers.dart';
import 'package:gothalo/features/recents/recent_providers.dart';
import 'package:gothalo/features/servers/servers_screen.dart';

/// Home, agent-first.
///
/// The screen lists the same agents up to three times over — Priority, Recent,
/// and grouped by state — and the whole arrangement rests on one invariant:
/// **one agent, one row.** A dedupe that slips shows the same agent twice a few
/// rows apart, which reads as a bug in the data rather than in the layout. That,
/// the ordering of the groups, and the rule that an empty Recent section is
/// absent rather than empty, are what these pin.

ServerSummary _server(String id, {bool active = false}) =>
    ServerSummary(id: id, name: id, baseUrl: 'http://$id', isActive: active);

Agent _agent(
  String paneId, {
  required String title,
  AgentStatus status = AgentStatus.idle,
  String cwd = '/Users/d/projects/gothalo',
  String branch = '',
}) => Agent(
  // `gemini` has no bundled logo, so the row draws a branded initial rather
  // than decoding a PNG mid-test.
  agent: 'gemini',
  paneId: paneId,
  agentStatus: status,
  title: title,
  cwd: cwd,
  branch: branch,
);

final _blocked = _agent(
  'w1:p1',
  title: 'Needs a decision',
  status: AgentStatus.blocked,
  branch: 'feat/x',
);
final _working = _agent(
  'w1:p2',
  title: 'Refactoring the client',
  status: AgentStatus.working,
  branch: 'main',
);
final _idle = _agent('w1:p3', title: 'Waiting around', branch: 'main');

/// Mounts home with a fixed world: one server, three agents, and whatever
/// Priority and Recent are told to claim.
Future<void> _pumpHome(
  WidgetTester tester, {
  List<Agent> agents = const [],
  List<Agent> priority = const [],
  List<({Agent agent, OpenedView view})> recent = const [],
}) async {
  final server = _server('s1', active: true);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serversProvider.overrideWith((ref) => Stream.value([server])),
        serverAgentsProvider.overrideWith(
          (ref, id) async => ServerAgents(server: server, agents: agents),
        ),
        priorityHitsProvider.overrideWithValue([
          for (final a in priority)
            PriorityHit(
              server: server,
              agent: a,
              starred: false,
              reachable: true,
            ),
        ]),
        recentHitsProvider.overrideWithValue([
          for (final r in recent)
            RecentHit(server: server, agent: r.agent, view: r.view),
        ]),
      ],
      child: const MaterialApp(home: ServersScreen()),
    ),
  );
  // Resolve the servers stream and the per-server future.
  await tester.pump();
  await tester.pump();
}

/// The screen's section headings, in the order they are laid out.
///
/// Read off [SectionLabel] rather than by text: the rendered heading is
/// uppercased, and so is the status label on every row, so `find.text('WORKING')`
/// matches a working agent's status mark as readily as the heading above it.
List<String> _sections(WidgetTester tester) => tester
    .widgetList<SectionLabel>(find.byType(SectionLabel))
    .map((s) => s.text)
    .toList();

void main() {
  testWidgets('agents are reachable from home without opening a server', (
    tester,
  ) async {
    await _pumpHome(tester, agents: [_working, _idle]);

    expect(find.text('Refactoring the client'), findsOneWidget);
    expect(find.text('Waiting around'), findsOneWidget);
    expect(_sections(tester), contains('Servers'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('groups run needs you, working, idle', (tester) async {
    await _pumpHome(tester, agents: [_idle, _working, _blocked]);

    expect(_sections(tester), [
      'Priority',
      'Needs you',
      'Working',
      'Idle',
      'Servers',
    ]);
  });

  testWidgets('an agent Priority is showing is not repeated below', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      agents: [_blocked, _working],
      priority: [_blocked],
    );

    // One agent, one row — even though the blocked agent qualifies for both
    // Priority and the "needs you" group.
    expect(find.text('Needs a decision'), findsOneWidget);
    expect(_sections(tester), ['Priority', 'Working', 'Servers']);
  });

  testWidgets('a recent agent is not repeated below either', (tester) async {
    await _pumpHome(
      tester,
      agents: [_working, _idle],
      recent: [(agent: _working, view: OpenedView.terminal)],
    );

    expect(find.text('Refactoring the client'), findsOneWidget);
    expect(_sections(tester), ['Priority', 'Recent', 'Idle', 'Servers']);
  });

  testWidgets('a recent row says which view it will reopen', (tester) async {
    await _pumpHome(
      tester,
      agents: [_working, _idle],
      recent: [
        (agent: _working, view: OpenedView.terminal),
        (agent: _idle, view: OpenedView.transcript),
      ],
    );

    expect(find.text('TERM'), findsOneWidget);
    expect(find.text('CHAT'), findsOneWidget);
  });

  testWidgets('an empty Recent section is absent, not an empty box', (
    tester,
  ) async {
    await _pumpHome(tester, agents: [_working]);

    expect(_sections(tester), isNot(contains('Recent')));
  });

  testWidgets('Recent deduped down to nothing disappears entirely', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      agents: [_blocked],
      priority: [_blocked],
      recent: [(agent: _blocked, view: OpenedView.transcript)],
    );

    // Priority claimed the only recent agent, so the section has no rows left —
    // and a header over nothing is worse than no header.
    expect(_sections(tester), isNot(contains('Recent')));
    expect(find.text('Needs a decision'), findsOneWidget);
  });

  testWidgets('a row names its project and branch, never its pane id', (
    tester,
  ) async {
    await _pumpHome(tester, agents: [_working]);

    final row = find.byType(AgentRow);
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.textContaining('gothalo')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('main')),
      findsOneWidget,
    );
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final text = t.data ?? t.textSpan?.toPlainText() ?? '';
      expect(text, isNot(contains('w1:p2')));
    }
  });

  testWidgets('the Priority cap and its expander still work', (tester) async {
    // Six starred agents against a five-row cap. None of them need you, so the
    // cap is not allowed to give way.
    final many = [
      for (var i = 0; i < 6; i++)
        _agent('w1:s$i', title: 'Starred $i', branch: 'main'),
    ];
    await _pumpHome(tester, agents: many, priority: many);

    expect(find.byType(AgentRow), findsNWidgets(kPriorityVisibleRows));
    expect(find.text('Show 1 more'), findsOneWidget);

    await tester.tap(find.text('Show 1 more'));
    await tester.pump();

    expect(find.byType(AgentRow), findsNWidgets(6));
    expect(find.text('Show less'), findsOneWidget);
  });

  testWidgets('a blocked agent is never hidden by the cap', (tester) async {
    final rows = [
      for (var i = 0; i < 5; i++)
        _agent('w1:s$i', title: 'Starred $i', branch: 'main'),
      _agent(
        'w1:blocked',
        title: 'Buried but blocked',
        status: AgentStatus.blocked,
        branch: 'main',
      ),
    ];
    await _pumpHome(tester, agents: rows, priority: rows);

    // The cap stretched to cover it rather than burying the row the app exists
    // for.
    expect(find.text('Buried but blocked'), findsOneWidget);
    expect(find.byType(AgentRow), findsNWidgets(6));
  });

  testWidgets('idle rows are dense lines in one shared panel', (tester) async {
    final idle = [
      for (var i = 0; i < 3; i++)
        _agent('w1:i$i', title: 'Idle $i', branch: 'main'),
    ];
    await _pumpHome(tester, agents: [_working, ...idle]);

    final rows = tester.widgetList<AgentRow>(find.byType(AgentRow)).toList();
    // The working agent keeps its card; the three idle ones are compact.
    expect(rows.where((r) => !r.compact).length, 1);
    expect(rows.where((r) => r.compact).length, 3);
    // One panel for all three, not three panels.
    expect(find.byType(CompactAgentPanel), findsOneWidget);
  });

  testWidgets('a dozen idle agents are collapsed on open', (tester) async {
    final idle = [
      for (var i = 0; i < 12; i++)
        _agent('w1:i$i', title: 'Idle $i', branch: 'main'),
    ];
    await _pumpHome(tester, agents: idle);

    // Six shown, six behind the expander — nobody wants a wall of them.
    expect(find.byType(AgentRow), findsNWidgets(kIdleVisibleRows));
    expect(find.text('Show 6 more'), findsOneWidget);

    await tester.tap(find.text('Show 6 more'));
    await tester.pump();

    expect(find.byType(AgentRow), findsNWidgets(12));
    expect(find.text('Show less'), findsOneWidget);
  });

  testWidgets('the working section is capped too', (tester) async {
    final working = [
      for (var i = 0; i < 8; i++)
        _agent('w1:w$i', title: 'Working $i',
            status: AgentStatus.working, branch: 'main'),
    ];
    await _pumpHome(tester, agents: working);

    expect(find.byType(AgentRow), findsNWidgets(kSectionVisibleRows));
    expect(find.text('Show 3 more'), findsOneWidget);
  });

  testWidgets('a blocked agent past a section cap is still shown', (
    tester,
  ) async {
    final rows = [
      for (var i = 0; i < 6; i++)
        _agent('w1:d$i', title: 'Finished $i',
            status: AgentStatus.done, branch: 'main'),
      _agent('w1:blocked', title: 'Buried but blocked',
          status: AgentStatus.blocked, branch: 'main'),
    ];
    await _pumpHome(tester, agents: rows);

    // Blocked sorts first, so it is inside the cap here — but the rule is
    // pinned directly in vocabulary_test; this is the screen-level check that
    // nothing needing a human is ever behind an expander.
    expect(find.text('Buried but blocked'), findsOneWidget);
  });

  testWidgets('the list scrolls clear of the floating add button', (
    tester,
  ) async {
    await _pumpHome(tester, agents: [_working]);

    final padding = tester
        .widgetList<ListView>(find.byType(ListView))
        .first
        .padding as EdgeInsets;
    // Enough for the FAB (56) plus its margin, or it lands on the last row.
    expect(padding.bottom, greaterThanOrEqualTo(88));
  });

  testWidgets('an idle row keeps two lines, so the branch is not truncated', (
    tester,
  ) async {
    final idle = _agent(
      'w1:i0',
      title: 'Set up mlx serve for Deepseek and wire the client',
      branch: 'feat/transcript-search',
    );
    await _pumpHome(tester, agents: [_working, idle]);

    final row = tester
        .widgetList<AgentRow>(find.byType(AgentRow))
        .firstWhere((r) => r.compact);
    // Two lines' worth. The one-line version put the title, the project, the
    // branch and the age on one row, so the two things that identify an agent
    // both truncated at once — and the branch is exactly what tells two rows in
    // the same repo apart.
    expect(
      tester.getSize(find.byWidget(row)).height,
      greaterThanOrEqualTo(kCompactRowHeight),
    );
    expect(find.text(idle.displayTitle), findsOneWidget);
  });

  testWidgets('idle is quieter than working by weight, not by line count', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      agents: [_working, _agent('w1:i0', title: 'Parked', branch: 'main')],
    );

    // Both rows are two lines now, so the separation has to come from weight.
    // The status is a bare dot on idle and a dot-plus-label on working: the
    // section heading already says IDLE, so the word would be the same word on
    // every row.
    final marks = tester.widgetList<StatusMark>(find.byType(StatusMark));
    expect(marks.where((m) => m.withLabel).length, 1);
    expect(marks.where((m) => !m.withLabel).length, 1);

    // And a dimmer title.
    final idleTitle = tester.widget<Text>(find.text('Parked'));
    final workingTitle = tester.widget<Text>(
      find.text('Refactoring the client'),
    );
    expect(idleTitle.style!.color!.a, lessThan(1.0));
    expect(idleTitle.style!.fontWeight!.value,
        lessThan(workingTitle.style!.fontWeight!.value));
  });

  testWidgets('rows enter once, and not again on a snapshot tick', (
    tester,
  ) async {
    await _pumpHome(tester, agents: [_working, _idle]);

    // Mid-cascade: rows are on their way in.
    expect(find.byType(Entrance), findsWidgets);
    await tester.pump(const Duration(milliseconds: 600));

    double opacityOf(String text) => tester
        .widgetList<Opacity>(
          find.ancestor(of: find.text(text), matching: find.byType(Opacity)),
        )
        .map((o) => o.opacity)
        .reduce((a, b) => a < b ? a : b);

    expect(opacityOf('Refactoring the client'), 1.0);

    // A rebuild — what a snapshot tick causes, every six seconds. The rows must
    // not fade in again: `Entrance` animates from `initState`, and the keys
    // keep each row's State across the rebuild.
    await tester.pump();
    expect(opacityOf('Refactoring the client'), 1.0);
    expect(opacityOf('Waiting around'), 1.0);
  });

  testWidgets('the whole cascade is over quickly', (tester) async {
    // Home is the screen opened most often; an animation that delights on the
    // first open irritates on the fiftieth. However long the list, the stagger
    // is capped, so the last row starts no later than 220ms in.
    final many = [
      for (var i = 0; i < 30; i++)
        _agent('w1:m$i', title: 'Agent $i', branch: 'main'),
    ];
    await _pumpHome(tester, agents: many);
    await tester.pump(const Duration(milliseconds: 450));

    // Only the entrance opacities — the backdrop artwork has its own, at 14%.
    final entering = tester.widgetList<Opacity>(
      find.descendant(
        of: find.byType(Entrance),
        matching: find.byType(Opacity),
      ),
    );
    expect(entering, isNotEmpty);
    for (final o in entering) {
      expect(o.opacity, 1.0);
    }
  });
}
