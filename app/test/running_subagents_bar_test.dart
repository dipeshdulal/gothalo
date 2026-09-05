import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/theme.dart';
import 'package:gothalo/features/transcript/running_subagents_bar.dart';
import 'package:gothalo/features/transcript/transcript_models.dart';

Subagent _sub(String id, String description, {bool done = false, int? ts}) =>
    Subagent(
      agentId: id,
      toolUseId: 'toolu_$id',
      agentType: 'general-purpose',
      description: description,
      spawnDepth: 1,
      done: done,
      lastActivityTs: ts,
    );

Widget _host(SubagentRoster roster, {void Function(Subagent)? onOpen}) =>
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: RunningSubagentsBar(
          roster: roster,
          onOpen: onOpen ?? (_) {},
        ),
      ),
    );

void main() {
  /// The whole point is not scrolling to find them, so the bar states the count
  /// without being opened.
  testWidgets('states how many agents are running', (tester) async {
    await tester.pumpWidget(
      _host(
        SubagentRoster([
          _sub('a1', 'Audit the caching layer'),
          _sub('a2', 'Survey the plugin API'),
        ]),
      ),
    );

    expect(find.text('2 agents running'), findsOneWidget);
  });

  testWidgets('says one agent in the singular', (tester) async {
    await tester.pumpWidget(
      _host(SubagentRoster([_sub('a1', 'Audit the caching layer')])),
    );

    expect(find.text('1 agent running'), findsOneWidget);
  });

  /// Same rule as the suggestions bar: no height at all when there is nothing
  /// to say. A permanent empty strip costs more chat than it ever saves.
  testWidgets('takes no height when nothing is running', (tester) async {
    await tester.pumpWidget(
      _host(SubagentRoster([_sub('a1', 'Finished', done: true)])),
    );

    expect(tester.getSize(find.byType(RunningSubagentsBar)).height, 0);
  });

  testWidgets('takes no height when the session delegated nothing', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const SubagentRoster.empty()));

    expect(tester.getSize(find.byType(RunningSubagentsBar)).height, 0);
  });

  testWidgets('opens the list on tap, naming every running agent in full', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SubagentRoster([
          _sub('a1', 'Audit the caching layer'),
          _sub('a2', 'Survey the plugin API'),
          _sub('a3', 'Already home', done: true),
        ]),
      ),
    );

    await tester.tap(find.text('2 agents running'));
    await tester.pumpAndSettle();

    expect(find.text('Audit the caching layer'), findsOneWidget);
    expect(find.text('Survey the plugin API'), findsOneWidget);
    expect(find.text('Already home'), findsNothing);
  });

  testWidgets('opening a row hands back the agent that was tapped', (
    tester,
  ) async {
    Subagent? opened;
    await tester.pumpWidget(
      _host(
        SubagentRoster([
          _sub('a1', 'Audit the caching layer'),
          _sub('a2', 'Survey the plugin API'),
        ]),
        onOpen: (s) => opened = s,
      ),
    );

    await tester.tap(find.text('2 agents running'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Survey the plugin API'));
    await tester.pumpAndSettle();

    expect(opened?.agentId, 'a2');
  });
}
