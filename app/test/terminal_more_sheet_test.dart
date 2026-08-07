import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/terminal/terminal_more_sheet.dart';
import 'package:gothalo/features/transcript/quick_commands_providers.dart';

class _FakeQuickCommands extends QuickCommands {
  _FakeQuickCommands(this.commands);

  final List<QuickCommand> commands;
  final removed = <int>[];

  @override
  Future<List<QuickCommand>> build() async => commands;

  @override
  Future<void> removeAt(int index) async => removed.add(index);
}

/// Opens the sheet over a bare screen and returns what it fired.
Future<({List<String> keys, List<QuickCommand> commands, List<bool> ctrl})>
_openSheet(
  WidgetTester tester, {
  List<QuickCommand> saved = const [],
  _FakeQuickCommands? store,
  bool stickyCtrl = false,
}) async {
  final keys = <String>[];
  final commands = <QuickCommand>[];
  final ctrl = <bool>[];

  // A phone, not the 800×600 default: the sheet is capped at 70% of the screen
  // height, and on a short fake screen half of it lands off the bottom.
  tester.view.physicalSize = const Size(412 * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        quickCommandsProvider.overrideWith(
          () => store ?? _FakeQuickCommands(saved),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showTerminalMoreSheet(
                  context,
                  onKey: keys.add,
                  onCommand: commands.add,
                  stickyCtrl: stickyCtrl,
                  onToggleStickyCtrl: () => ctrl.add(true),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (keys: keys, commands: commands, ctrl: ctrl);
}

void main() {
  group('control keys', () {
    testWidgets('every listed byte is offered and sends what it says', (
      tester,
    ) async {
      final fired = await _openSheet(tester);

      // Each key is fired in turn; the sheet closes on use, so it is reopened
      // between taps the way a user would.
      for (final k in terminalControlKeys) {
        if (find.text(k.label).evaluate().isEmpty) {
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text(k.label));
        await tester.pumpAndSettle();
      }

      expect(fired.keys, [for (final k in terminalControlKeys) k.bytes]);
    });

    // ^C keeps a place in the row as well: this is the canonical list, that one
    // is the emergency stop, and it must never cost two taps.
    test('the set covers interrupt, EOF, redraw, history and line editing', () {
      expect(
        terminalControlKeys.map((k) => k.label),
        containsAll(['^C', '^D', '^L', '^R', '^U', '^A', '^E']),
      );
    });

    // Sticky Ctrl survived the move out of the row: the explicit list is a
    // shortlist, and a phone keyboard has no Ctrl key of its own, so without
    // this ^K, ^P, ^X and friends would be unreachable rather than slower.
    testWidgets('Ctrl + arms the next key and closes', (tester) async {
      final fired = await _openSheet(tester);

      await tester.tap(find.text('Ctrl +'));
      await tester.pumpAndSettle();

      expect(fired.ctrl, [true]);
      expect(find.text('Ctrl +'), findsNothing, reason: 'the sheet closed');
    });
  });

  group('quick commands', () {
    testWidgets('every saved command is listed — none is filtered out', (
      tester,
    ) async {
      // "Interrupt" fires the same key as the row's Esc button. The old row
      // dropped it, because a slot there was scarce; a sheet has room, and
      // hiding something the user saved is worse than showing it twice.
      await _openSheet(
        tester,
        saved: const [
          QuickCommand(label: 'Interrupt', key: 'esc'),
          QuickCommand(label: 'Run tests', text: 'npm test'),
        ],
      );

      expect(find.text('Interrupt'), findsOneWidget);
      expect(find.text('Run tests'), findsOneWidget);
    });

    testWidgets('tapping one fires it and closes the sheet', (tester) async {
      final fired = await _openSheet(
        tester,
        saved: const [QuickCommand(label: 'Run tests', text: 'npm test')],
      );

      await tester.tap(find.text('Run tests'));
      await tester.pumpAndSettle();

      expect(fired.commands.single.text, 'npm test');
      expect(find.text('Run tests'), findsNothing);
    });

    testWidgets('long-press removes it, after confirming', (tester) async {
      final store = _FakeQuickCommands(const [
        QuickCommand(label: 'first', text: 'a'),
        QuickCommand(label: 'second', text: 'b'),
      ]);
      await _openSheet(tester, store: store);

      await tester.longPress(find.text('second'));
      await tester.pumpAndSettle();
      expect(find.text('Remove quick command?'), findsOneWidget);

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(store.removed, [1], reason: 'the index of the one long-pressed');
    });

    testWidgets('cancelling the confirm removes nothing', (tester) async {
      final store = _FakeQuickCommands(const [
        QuickCommand(label: 'first', text: 'a'),
      ]);
      await _openSheet(tester, store: store);

      await tester.longPress(find.text('first'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(store.removed, isEmpty);
    });

    testWidgets('adding one is offered here, since the row no longer has +', (
      tester,
    ) async {
      await _openSheet(tester);

      await tester.tap(find.text('Add a command'));
      await tester.pumpAndSettle();
      expect(find.byType(AddQuickCommandDialog), findsOneWidget);
    });
  });
}
