import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/theme.dart';
import 'package:gothalo/core/widgets/count_pair.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/agents/widgets/agent_row.dart';

Agent _agent(Map<String, dynamic> extra) => Agent.fromJson({
  'agent': 'claude',
  'pane_id': 'wZ:p1',
  'cwd': '/home/x/acme-app',
  'terminal_title_stripped': 'Resume pipeline runs',
  'agent_status': 'working',
  ...extra,
});

void main() {
  group('snapshot model', () {
    test('parses the subagent counts the bridge stamps', () {
      final a = _agent({
        'subagents': {'total': 17, 'running': 4},
      });

      expect(a.subagents?.total, 17);
      expect(a.subagents?.running, 4);
    });

    /// Absent, not zero: a session that delegated nothing and one whose kind
    /// cannot be counted both send no field, and neither should draw a badge.
    test('an absent field is null rather than a zero count', () {
      expect(_agent(const {}).subagents, isNull);
    });
  });

  group('agent row', () {
    Widget host(Agent a) => MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: AgentRow(agent: a, onTap: () {})),
    );

    /// A glyph and a number, the idiom the project rows already use — the
    /// words cost width on a line that ellipsises, and this row is scanned
    /// rather than read.
    testWidgets('shows the count as an icon and a number', (tester) async {
      await tester.pumpWidget(
        host(
          _agent({
            'subagents': {'total': 17, 'running': 4},
          }),
        ),
      );

      final pair = tester.widget<CountPair>(find.byType(CountPair));
      expect(pair.count, 4);
      expect(pair.icon, Icons.account_tree_outlined);
      expect(find.textContaining('running'), findsNothing);
    });

    /// The glyph is only legible if the words survive for a screen reader.
    testWidgets('still says "running" out loud', (tester) async {
      await tester.pumpWidget(
        host(
          _agent({
            'subagents': {'total': 17, 'running': 4},
          }),
        ),
      );

      expect(
        tester.widget<CountPair>(find.byType(CountPair)).semantics,
        '4 agents running',
      );
    });

    testWidgets('speaks a single agent in the singular', (tester) async {
      await tester.pumpWidget(
        host(
          _agent({
            'subagents': {'total': 3, 'running': 1},
          }),
        ),
      );

      expect(
        tester.widget<CountPair>(find.byType(CountPair)).semantics,
        '1 agent running',
      );
    });

    /// The badge is about what is working now. A session whose delegated work
    /// has all finished is as quiet as one that never delegated.
    testWidgets('stays quiet when every delegated agent has finished', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          _agent({
            'subagents': {'total': 17, 'running': 0},
          }),
        ),
      );

      expect(find.byType(CountPair), findsNothing);
    });

    /// The project line ellipsises, and a long branch fills it on its own. The
    /// count is the part you are reading the row for, so truncation has to eat
    /// the branch instead.
    testWidgets('survives a branch long enough to fill the line', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: AgentRow(
                agent: _agent({
                  'branch': 'feature/a-branch-name-long-enough-to-fill-the-line',
                  'cwd': '/home/x/acme-app',
                  'subagents': {'total': 21, 'running': 4},
                }),
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      // Its own widget, not a span inside the ellipsised line — a span there
      // is clipped by a long branch and no assertion on the rich text can see
      // it.
      final finder = find.byType(CountPair);
      expect(finder, findsOneWidget);
      expect(tester.getSize(finder).width, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    /// With more than one server the server name is what tells otherwise
    /// identical rows apart, so it outranks the branch for the space — the
    /// branch is the longer, more compressible half. A long branch plus a
    /// count previously left no room for the server at all, and the row could
    /// not say which machine it was on.
    testWidgets('keeps the server name when the branch is long', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: AgentRow(
                agent: _agent({
                  'branch': 'feature/rework-the-scheduler',
                  'subagents': {'total': 21, 'running': 4},
                }),
                serverName: 'Build server',
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      final line = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && (w.textSpan?.toPlainText() ?? '').contains('acme-app'),
        ),
      );
      final plain = line.textSpan!.toPlainText();
      expect(
        plain.indexOf('Build server'),
        lessThan(plain.indexOf('feature/')),
        reason: 'the server must come before the branch so the branch absorbs '
            'the truncation: $plain',
      );
    });

    testWidgets('stays quiet when the session delegated nothing', (
      tester,
    ) async {
      await tester.pumpWidget(host(_agent(const {})));

      expect(find.byType(CountPair), findsNothing);
    });
  });
}
