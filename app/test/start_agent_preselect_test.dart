import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/features/agents/agent_lifecycle_providers.dart';
import 'package:gothalo/features/agents/start_agent_sheet.dart';

/// The launch sheet opens on the agent you last started, and never on nothing.
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

AvailableAgent _installed(String kind) =>
    AvailableAgent(kind: kind, path: '/usr/bin/$kind', stateReporting: true);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<String> installed,
  String? remembered,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        availableAgentsProvider.overrideWith(
          (ref) async => [for (final k in installed) _installed(k)],
        ),
        lastAgentKindProvider.overrideWith(() => _FixedLastKind(remembered)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showStartAgentSheet(
                context,
                ref,
                target: const StartAgentTarget(
                  placement: StartAgentPlacement.newTab,
                  id: 'w1',
                  where: 'A new tab in gothalo',
                  defaultCwd: '/d/projects/gothalo',
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
