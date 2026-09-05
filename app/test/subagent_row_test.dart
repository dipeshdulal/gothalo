import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/theme.dart';
import 'package:gothalo/features/transcript/subagent_row.dart';
import 'package:gothalo/features/transcript/transcript_models.dart';

const _subagent = Subagent(
  agentId: 'aa4832e5ce82b16f0',
  toolUseId: 'toolu_01F9bssr6JjRZXjvEumqMwuR',
  agentType: 'general-purpose',
  description: 'Trace the retry path',
  spawnDepth: 1,
);

Widget _host(Widget child) =>
    MaterialApp(theme: AppTheme.dark, home: Scaffold(body: child));

Subagent _sub({required bool done, int? lastActivityTs}) => Subagent(
  agentId: 'aa4832e5ce82b16f0',
  toolUseId: 'toolu_01F9bssr6JjRZXjvEumqMwuR',
  agentType: 'general-purpose',
  description: 'Audit the caching layer',
  spawnDepth: 1,
  done: done,
  lastActivityTs: lastActivityTs,
);

void main() {
  testWidgets('names the delegated task and the agent that ran it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(SubagentRow(subagent: _subagent, onOpen: () {})),
    );

    expect(find.text('Trace the retry path'), findsOneWidget);
    expect(find.text('general-purpose'), findsOneWidget);
  });

  /// An async agent's Task call returns in seconds while the child runs on for
  /// minutes, so a finished launch call says nothing about the agent.
  testWidgets('a launched agent still reads as running', (tester) async {
    await tester.pumpWidget(
      _host(SubagentRow(subagent: _sub(done: false), onOpen: () {})),
    );

    expect(find.text('RUNNING'), findsOneWidget);
  });

  testWidgets('an agent the parent was told finished is not running', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(SubagentRow(subagent: _sub(done: true), onOpen: () {})),
    );

    expect(find.text('RUNNING'), findsNothing);
  });

  /// A running row that has not written for a long time is a stuck agent, not a
  /// busy one — the age is what makes that visible.
  testWidgets('a running agent shows how long since it wrote', (tester) async {
    final tenMinAgo = DateTime.now()
        .subtract(const Duration(minutes: 10))
        .millisecondsSinceEpoch;
    await tester.pumpWidget(
      _host(
        SubagentRow(
          subagent: _sub(done: false, lastActivityTs: tenMinAgo),
          onOpen: () {},
        ),
      ),
    );

    expect(find.textContaining('10m'), findsOneWidget);
  });

  testWidgets('an undatable agent shows no age at all', (tester) async {
    await tester.pumpWidget(
      _host(SubagentRow(subagent: _sub(done: false), onOpen: () {})),
    );

    expect(find.textContaining('0s'), findsNothing);
  });

  testWidgets('tapping opens the delegated conversation', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(
        SubagentRow(subagent: _subagent, onOpen: () => opened++),
      ),
    );

    await tester.tap(find.byType(SubagentRow));
    expect(opened, 1);
  });

  /// Spawned without a description, the agent type carries the row alone rather
  /// than leaving it blank.
  testWidgets('falls back to the agent type when there is no description', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SubagentRow(
          subagent: const Subagent(
            agentId: 'a1',
            toolUseId: 't1',
            agentType: 'Explore',
            description: '',
            spawnDepth: 1,
          ),
          onOpen: () {},
        ),
      ),
    );

    expect(find.text('Explore'), findsWidgets);
  });
}
