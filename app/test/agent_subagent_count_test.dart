import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/theme.dart';
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

    testWidgets('says how many delegated agents are running', (tester) async {
      await tester.pumpWidget(
        host(
          _agent({
            'subagents': {'total': 17, 'running': 4},
          }),
        ),
      );

      expect(find.textContaining('4 running'), findsOneWidget);
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

      expect(find.textContaining('running'), findsNothing);
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

      // Its own Text, not a span inside the ellipsised line — a span there is
      // clipped by a long branch and no assertion on the rich text can see it.
      final finder = find.text('4 running');
      expect(finder, findsOneWidget);
      expect(tester.getSize(finder).width, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('stays quiet when the session delegated nothing', (
      tester,
    ) async {
      await tester.pumpWidget(host(_agent(const {})));

      expect(find.textContaining('running'), findsNothing);
    });
  });
}
