import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection_providers.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/priority/priority_providers.dart';
import 'package:gothalo/features/priority/widgets/priority_overflow_bar.dart';

/// The cap exists so the Priority section can't push the rest of the home
/// screen off the bottom. Two properties matter more than the number: it must
/// never hide an agent that is waiting on you, and it must never reorder — the
/// bridge's `attention_rank` is the ordering, and this only ever cuts a prefix.

const _server = ServerSummary(
  id: 's1',
  name: 'studio',
  baseUrl: 'http://127.0.0.1:8787',
  isActive: true,
);

/// One hit, ranked exactly as the bridge ranks that status (blocked 0 … idle 3).
PriorityHit _hit(String pane, AgentStatus status) => PriorityHit(
  server: _server,
  agent: Agent(
    paneId: pane,
    agent: 'claude',
    agentStatus: status,
    attentionRank: status.rank,
  ),
  starred: false,
  reachable: true,
);

/// A bridge-ordered list: [blocked] blocked, then [done] done, then [working]
/// working, then [idle] idle — i.e. what `priorityHitsProvider` hands over.
List<PriorityHit> _list({
  int blocked = 0,
  int done = 0,
  int working = 0,
  int idle = 0,
}) => [
  for (var i = 0; i < blocked; i++) _hit('b$i', AgentStatus.blocked),
  for (var i = 0; i < done; i++) _hit('d$i', AgentStatus.done),
  for (var i = 0; i < working; i++) _hit('w$i', AgentStatus.working),
  for (var i = 0; i < idle; i++) _hit('i$i', AgentStatus.idle),
];

void main() {
  group('PriorityOverflow', () {
    test('a short list is untouched — no expander, no behaviour change', () {
      final hits = _list(blocked: 1, done: 1);
      final o = PriorityOverflow.of(hits, expanded: false);
      expect(o.visible, hits);
      expect(o.hiddenCount, 0);
      expect(o.hasOverflow, isFalse);
      expect(o.capGaveWay, isFalse);
    });

    test('exactly the cap still shows everything', () {
      final hits = _list(done: kPriorityVisibleRows);
      expect(PriorityOverflow.of(hits, expanded: false).hasOverflow, isFalse);
    });

    test('the realistic worst case: 14 agents, 3 of them blocked', () {
      // A dozen-plus live agents is the case that broke the screen: every
      // blocked and done agent lands in Priority, so the section grew past the
      // viewport and the servers list fell off the bottom.
      final hits = _list(blocked: 3, done: 6, working: 3, idle: 2);
      final o = PriorityOverflow.of(hits, expanded: false);

      expect(o.visible.length, kPriorityVisibleRows);
      expect(o.hiddenCount, 14 - kPriorityVisibleRows);
      expect(o.capGaveWay, isFalse);
      // Prefix of the bridge's order, unchanged.
      expect(
        o.visible.map((h) => h.agent.paneId),
        hits.take(kPriorityVisibleRows).map((h) => h.agent.paneId),
      );
    });

    test('the cap gives way rather than hide an agent that needs you', () {
      // Nine blocked agents is a long list, and a long list is the correct
      // answer here — these are exactly the rows the app exists to show.
      final hits = _list(blocked: 9, done: 4, idle: 3);
      final o = PriorityOverflow.of(hits, expanded: false);

      expect(o.visible.length, 9);
      expect(o.visible.every((h) => h.needsYou), isTrue);
      expect(o.hiddenCount, 7);
      expect(o.capGaveWay, isTrue);
    });

    test('nothing is hidden when every row needs you', () {
      final o = PriorityOverflow.of(_list(blocked: 12), expanded: false);
      expect(o.hiddenCount, 0);
      expect(o.hasOverflow, isFalse);
    });

    test('a blocked agent an old bridge ranked oddly is still shown', () {
      // The exemption is defined on the row, not on its position: it stretches
      // the cut to the LAST needs-you row rather than trusting blocked to sit
      // at the front. An unranked agent from an older bridge sorts on the local
      // fallback, so this is reachable in practice.
      final hits = [
        ..._list(done: 6),
        _hit('late', AgentStatus.blocked),
        ..._list(idle: 3),
      ];
      final o = PriorityOverflow.of(hits, expanded: false);

      expect(o.visible.map((h) => h.agent.paneId), contains('late'));
      expect(o.visible.length, 7);
      expect(o.hiddenCount, 3);
    });

    test('expanded shows everything, and keeps a way back', () {
      final hits = _list(blocked: 9, done: 4, idle: 3);
      final o = PriorityOverflow.of(hits, expanded: true);
      expect(o.visible, hits);
      expect(o.hiddenCount, 0);
      expect(o.capGaveWay, isFalse);
      // Still "overflowing" — the section keeps its control, or the tap that
      // opened it would delete the only way to shut it again.
      expect(o.hasOverflow, isTrue);
    });

    test('the tally counts the whole list, in the bridge\'s order', () {
      // The collapsed summary describes what the section is sitting on, not
      // just the part it is showing — otherwise "3 need you" would silently
      // mean "3 need you, of the ones you can\'t see".
      final o = PriorityOverflow.of(
        _list(blocked: 3, done: 5, idle: 2),
        expanded: false,
      );
      expect(o.tally, [
        (status: AgentStatus.blocked, count: 3),
        (status: AgentStatus.done, count: 5),
        (status: AgentStatus.idle, count: 2),
      ]);
    });

    test('an empty list has an empty tally and no expander', () {
      final o = PriorityOverflow.of(const [], expanded: false);
      expect(o.tally, isEmpty);
      expect(o.hasOverflow, isFalse);
    });
  });

  group('PriorityOverflowBar', () {
    Future<int> pumpBar(
      WidgetTester tester, {
      required bool expanded,
      Brightness brightness = Brightness.light,
      List<PriorityHit>? hits,
    }) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: PriorityOverflowBar(
              overflow: PriorityOverflow.of(
                hits ?? _list(blocked: 3, done: 5, idle: 2),
                expanded: expanded,
              ),
              onToggle: () => taps++,
            ),
          ),
        ),
      );
      return taps;
    }

    testWidgets('collapsed, it says what it is holding back', (tester) async {
      await pumpBar(tester, expanded: false);

      expect(find.text('3 need you'), findsOneWidget);
      expect(find.text('5 done'), findsOneWidget);
      expect(find.text('2 idle'), findsOneWidget);
      expect(find.text('Show 5 more'), findsOneWidget);
    });

    testWidgets('expanded, the counts give way to the rows themselves', (
      tester,
    ) async {
      await pumpBar(tester, expanded: true);

      expect(find.text('Show less'), findsOneWidget);
      expect(find.text('3 need you'), findsNothing);
    });

    testWidgets('nothing to hide, nothing to draw', (tester) async {
      await pumpBar(tester, expanded: false, hits: _list(blocked: 1, done: 1));

      expect(find.byType(InkWell), findsNothing);
      expect(find.textContaining('Show'), findsNothing);
    });

    testWidgets('the whole bar is the target, not just the label', (
      tester,
    ) async {
      // A 13pt label is a poor thumb target on a phone; the row it sits in is
      // a good one.
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PriorityOverflowBar(
              overflow: PriorityOverflow.of(
                _list(blocked: 3, done: 5, idle: 2),
                expanded: false,
              ),
              onToggle: () => taps++,
            ),
          ),
        ),
      );

      await tester.tap(find.text('3 need you'));
      await tester.tap(find.text('Show 5 more'));
      await tester.pump();

      expect(taps, 2);
    });

    testWidgets('the summary reads in both themes', (tester) async {
      for (final brightness in Brightness.values) {
        await pumpBar(tester, expanded: false, brightness: brightness);
        expect(find.text('3 need you'), findsOneWidget);

        // Same source of colour as the row badges (AgentStatusUi.colors), so
        // the pill can't end up as text on its own background in one theme.
        final chip = tester.widget<Container>(
          find
              .ancestor(
                of: find.text('3 need you'),
                matching: find.byType(Container),
              )
              .first,
        );
        final bg = (chip.decoration as BoxDecoration).color;
        final fg = tester.widget<Text>(find.text('3 need you')).style?.color;
        expect(bg, isNotNull);
        expect(fg, isNot(bg));
      }
    });
  });
}
