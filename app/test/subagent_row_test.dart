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

void main() {
  testWidgets('names the delegated task and the agent that ran it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(SubagentRow(subagent: _subagent, running: false, onOpen: () {})),
    );

    expect(find.text('Trace the retry path'), findsOneWidget);
    expect(find.text('general-purpose'), findsOneWidget);
  });

  /// A Task call with no result yet is a subagent still working — the state the
  /// phone most needs to show, and the one the chat view could not.
  testWidgets('marks a subagent whose Task call has no result as running', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(SubagentRow(subagent: _subagent, running: true, onOpen: () {})),
    );

    expect(find.text('RUNNING'), findsOneWidget);
  });

  testWidgets('a finished subagent shows no running badge', (tester) async {
    await tester.pumpWidget(
      _host(SubagentRow(subagent: _subagent, running: false, onOpen: () {})),
    );

    expect(find.text('RUNNING'), findsNothing);
  });

  testWidgets('tapping opens the delegated conversation', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(
        SubagentRow(
          subagent: _subagent,
          running: false,
          onOpen: () => opened++,
        ),
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
          running: false,
          onOpen: () {},
        ),
      ),
    );

    expect(find.text('Explore'), findsWidgets);
  });
}
