import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/widgets/accessory_button.dart';
import 'package:gothalo/features/terminal/accessory_key_row.dart';
import 'package:gothalo/features/terminal/direction_pad.dart';
import 'package:gothalo/features/transcript/quick_commands_providers.dart';

/// Saved quick commands, as the row's screen would see them. The row must not
/// care how many there are — that is the whole point of this file.
class _FakeQuickCommands extends QuickCommands {
  _FakeQuickCommands(this.commands);

  final List<QuickCommand> commands;

  @override
  Future<List<QuickCommand>> build() async => commands;
}

/// Mounts the row the way the terminal screen does: pinned to the bottom, at a
/// phone's width, with [saved] quick commands in the shared store.
Future<List<String>> _pumpRow(
  WidgetTester tester, {
  List<QuickCommand> saved = const [],
  double width = 412, // Pixel-class, where the regression was spotted
}) async {
  final sent = <String>[];
  tester.view.physicalSize = Size(width * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        quickCommandsProvider.overrideWith(() => _FakeQuickCommands(saved)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AccessoryKeyRow(
                padOpen: false,
                onTogglePad: () {},
                keyboardOpen: false,
                onToggleKeyboard: () {},
                moreArmed: false,
                onMore: () {},
                uploading: false,
                onAttachImage: () {},
                onKey: sent.add,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return sent;
}

List<QuickCommand> _commands(int n) => [
  for (var i = 0; i < n; i++) QuickCommand(label: 'cmd$i', text: 'echo $i'),
];

void main() {
  group('AccessoryKeyRow is a fixed seven', () {
    // The regression this file exists for: the row used to prepend one button
    // per saved quick command (and carried `+` and sticky Ctrl), so its width
    // and its centre moved with the user's config. Adding the image button to
    // that variable row is what made the pad toggle "sit in a weird position".
    for (final n in [0, 1, 3, 8]) {
      testWidgets('$n saved quick commands still make seven buttons', (
        tester,
      ) async {
        await _pumpRow(tester, saved: _commands(n));

        expect(
          find.byType(AccessoryButton),
          findsNWidgets(AccessoryKeyRow.buttonCount),
        );
        // None of the saved commands leaked into the row — they live in the
        // more-sheet now.
        for (var i = 0; i < n; i++) {
          expect(find.text('cmd$i'), findsNothing);
        }
      });
    }

    testWidgets('the pad toggle is the 4th button, so it is the middle one', (
      tester,
    ) async {
      await _pumpRow(tester, saved: _commands(4));

      final toggle = find.descendant(
        of: find.byType(DirectionPadToggle),
        matching: find.byType(AccessoryButton),
      );
      expect(toggle, findsOneWidget);
      expect(
        find.byType(AccessoryButton).evaluate().toList().indexOf(
          toggle.evaluate().single,
        ),
        AccessoryKeyRow.padToggleIndex,
      );
    });

    // Centred by construction, not by luck: with seven buttons the row fits a
    // phone, so spaceEvenly has free space and the middle button lands on the
    // bar's centre line. A row wider than the screen left-aligns instead, which
    // is exactly how the toggle drifted off centre before.
    for (final width in [393.0, 412.0]) {
      testWidgets(
        'the middle button sits on the bar centre line at ${width.toInt()}dp',
        (tester) async {
          await _pumpRow(tester, width: width, saved: _commands(4));

          final rowCentre = tester.getCenter(find.byType(AccessoryKeyRow)).dx;
          final toggleCentre = tester
              .getCenter(find.byType(DirectionPadToggle))
              .dx;
          expect((toggleCentre - rowCentre).abs(), lessThan(1));
        },
      );
    }

    // 393dp is an iPhone 15/16; 412dp is Pixel-class, where the off-centre
    // toggle was reported. Both must have room to spare, because a row even a
    // couple of dp over its bar left-aligns and the centring is gone.
    for (final width in [393.0, 412.0]) {
      testWidgets('it does not overflow a ${width.toInt()}dp bar', (
        tester,
      ) async {
        await _pumpRow(tester, width: width, saved: _commands(4));

        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        expect(
          position.maxScrollExtent,
          0,
          reason: 'seven buttons must fit, or spaceEvenly has nothing to spread',
        );
      });
    }
  });

  group('AccessoryKeyRow keys', () {
    testWidgets('Esc, ^C and Tab send the bytes a PTY expects', (tester) async {
      final sent = await _pumpRow(tester);

      await tester.tap(find.text('Esc'));
      await tester.tap(find.text('^C'));
      await tester.tap(find.text('Tab'));
      await tester.pump();

      expect(sent, ['\x1b', '\x03', '\t']);
    });

    testWidgets('the image button is a no-op while an upload is in flight', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: AccessoryKeyRow(
                padOpen: false,
                onTogglePad: () {},
                keyboardOpen: false,
                onToggleKeyboard: () {},
                moreArmed: false,
                onMore: () {},
                uploading: true,
                onAttachImage: () => taps++,
                onKey: (_) {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Attach an image'));
      await tester.pump();
      expect(taps, 0);
    });
  });
}
