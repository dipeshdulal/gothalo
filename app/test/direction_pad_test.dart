import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/terminal/accessory_bar.dart';
import 'package:gothalo/features/terminal/direction_pad.dart';

/// Mounts the pad the way the terminal screen does: centred along the bottom of
/// the buffer. Returns the bytes it emitted.
Future<List<String>> _pumpPad(WidgetTester tester) async {
  final sent = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: DirectionPad(onKey: sent.add),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return sent;
}

Finder _key(String label) => find.bySemanticsLabel(label);

void main() {
  group('DirectionPad', () {
    testWidgets('each arrow sends the escape sequence a PTY expects', (
      tester,
    ) async {
      final sent = await _pumpPad(tester);

      await tester.tap(_key('Up'));
      await tester.tap(_key('Down'));
      await tester.tap(_key('Left'));
      await tester.tap(_key('Right'));
      await tester.pump();

      expect(sent, ['\x1b[A', '\x1b[B', '\x1b[D', '\x1b[C']);
    });

    testWidgets('holding a key repeats after a delay, and stops on release', (
      tester,
    ) async {
      final sent = await _pumpPad(tester);

      final gesture = await tester.startGesture(tester.getCenter(_key('Down')));
      // Press fires immediately — a tap shouldn't wait for the repeat delay.
      expect(sent, ['\x1b[B']);

      // Held below the repeat delay: still just the one press.
      await tester.pump(const Duration(milliseconds: 300));
      expect(sent, hasLength(1));

      // Past the delay, it streams.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 300));
      final held = sent.length;
      expect(held, greaterThan(3));
      expect(sent.every((b) => b == '\x1b[B'), isTrue);

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(sent, hasLength(held), reason: 'repeat must stop on release');
    });

    testWidgets('a released key leaves no timer behind after dispose', (
      tester,
    ) async {
      await _pumpPad(tester);
      final gesture = await tester.startGesture(tester.getCenter(_key('Up')));
      await tester.pump(const Duration(milliseconds: 600)); // into repeat
      await gesture.up();
      // Unmount mid-life; pumpWidget's teardown asserts no pending timers.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a key still held at dispose cancels its repeat', (
      tester,
    ) async {
      await _pumpPad(tester);
      await tester.startGesture(tester.getCenter(_key('Right')));
      await tester.pump(const Duration(milliseconds: 600)); // into repeat
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Backspace sends DEL, which is what a terminal erases on', (
      tester,
    ) async {
      final sent = await _pumpPad(tester);

      await tester.tap(_key('Backspace'));
      await tester.pump();

      expect(sent, ['\x7f']);
    });

    testWidgets('Enter submits, and never auto-repeats when held', (
      tester,
    ) async {
      final sent = await _pumpPad(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(_key('Enter')),
      );
      expect(sent, ['\r']);
      // Well past the repeat delay: a leaned-on thumb must not resubmit.
      await tester.pump(const Duration(seconds: 2));
      expect(sent, ['\r']);
      await gesture.up();
      await tester.pump();
      expect(sent, ['\r']);
    });

    testWidgets('the cluster lays out ↑ / ← ↓ → / ⌫ + Enter', (tester) async {
      await _pumpPad(tester);

      final up = tester.getRect(_key('Up'));
      final left = tester.getRect(_key('Left'));
      final down = tester.getRect(_key('Down'));
      final right = tester.getRect(_key('Right'));
      final back = tester.getRect(_key('Backspace'));
      final enter = tester.getRect(_key('Enter'));

      // The arrows keep a desktop keyboard's inverted-T.
      expect(up.center.dx, moreOrLessEquals(down.center.dx));
      expect(up.bottom, lessThanOrEqualTo(down.top));
      expect(left.center.dx, lessThan(down.center.dx));
      expect(down.center.dx, lessThan(right.center.dx));
      expect(left.center.dy, moreOrLessEquals(down.center.dy));
      expect(right.center.dy, moreOrLessEquals(down.center.dy));
      // Bottom row: ⌫ then an Enter taking the rest of the width.
      expect(back.top, greaterThanOrEqualTo(down.bottom));
      expect(enter.center.dy, moreOrLessEquals(back.center.dy));
      expect(back.left, moreOrLessEquals(left.left));
      expect(enter.left, greaterThan(back.right - 1));
      expect(enter.right, moreOrLessEquals(right.right));
      expect(enter.width, greaterThan(back.width));
      // And the whole thing occupies exactly the advertised footprint.
      expect(tester.getSize(find.byType(DirectionPad)), DirectionPad.size);
    });

    testWidgets('taps beside the pad fall through to what is underneath', (
      tester,
    ) async {
      var tapsBelow = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => tapsBelow++,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 8,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: DirectionPad(onKey: (_) {}),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // Beside the pad on its own row — the centred layout leaves live buffer
      // to both sides of it, and a tap there must still reach the terminal.
      final pad = tester.getRect(find.byType(DirectionPad));
      await tester.tapAt(Offset(pad.left / 2, pad.center.dy));
      await tester.tapAt(const Offset(60, 80)); // and well above it
      expect(tapsBelow, 2);
    });
  });

  group('DirectionPadToggle', () {
    /// Mounts the toggle inside a Row, as the accessory bar does — a bare
    /// Scaffold body would hand it a full-width tight constraint and hide the
    /// size it actually takes in the bar.
    Future<int> pumpToggle(WidgetTester tester, {required bool open}) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                DirectionPadToggle(open: open, onToggle: () => taps++),
              ],
            ),
          ),
        ),
      );
      return taps;
    }

    testWidgets('tapping it asks for a toggle', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                DirectionPadToggle(open: false, onToggle: () => taps++),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.byType(DirectionPadToggle));
      expect(taps, 1);
    });

    testWidgets('it says which way it will go, closed and open', (
      tester,
    ) async {
      await pumpToggle(tester, open: false);
      expect(_key('Show arrows'), findsOneWidget);

      await pumpToggle(tester, open: true);
      expect(_key('Hide arrows'), findsOneWidget);
    });

    testWidgets('it lights up while the pad is open', (tester) async {
      Color colorOf(WidgetTester t) => t
          .widget<Material>(
            find.descendant(
              of: find.byType(DirectionPadToggle),
              matching: find.byType(Material),
            ),
          )
          .color!;

      await pumpToggle(tester, open: false);
      final closed = colorOf(tester);
      await pumpToggle(tester, open: true);
      final opened = colorOf(tester);

      final scheme = Theme.of(
        tester.element(find.byType(DirectionPadToggle)),
      ).colorScheme;
      expect(opened, scheme.primary);
      expect(opened, isNot(closed));
    });

    testWidgets('it is exactly one accessory-bar button', (tester) async {
      await pumpToggle(tester, open: false);
      // Every button in that bar measures the same; a toggle that didn't would
      // break the evenly-spread row it sits in.
      expect(
        tester.getSize(find.byType(DirectionPadToggle)),
        AccessoryButton.size,
      );
    });
  });

  group('KeyboardToggle', () {
    Future<int> pumpToggle(WidgetTester tester, {required bool open}) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [KeyboardToggle(open: open, onToggle: () => taps++)],
            ),
          ),
        ),
      );
      return taps;
    }

    testWidgets('tapping it asks for a toggle', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [KeyboardToggle(open: false, onToggle: () => taps++)],
            ),
          ),
        ),
      );

      await tester.tap(find.byType(KeyboardToggle));
      expect(taps, 1);
    });

    testWidgets('it says which way it will go, closed and open', (
      tester,
    ) async {
      await pumpToggle(tester, open: false);
      expect(_key('Show keyboard'), findsOneWidget);

      await pumpToggle(tester, open: true);
      expect(_key('Hide keyboard'), findsOneWidget);
    });

    testWidgets('it is exactly one accessory-bar button', (tester) async {
      await pumpToggle(tester, open: false);
      expect(tester.getSize(find.byType(KeyboardToggle)), AccessoryButton.size);
    });
  });
}
