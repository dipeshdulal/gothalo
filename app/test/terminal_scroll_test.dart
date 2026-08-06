import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:gothalo/features/terminal/pty_mouse_handler.dart';

/// The final DEC private mode state herdr replays when the bridge attaches to
/// a Claude Code pane, captured off the wire: alternate screen plus mouse
/// tracking with SGR extended coordinates.
const _agentPaneModes =
    '\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h';

/// A terminal wired the way [TerminalScreen] wires it, collecting everything it
/// would send to the PTY.
({Terminal terminal, List<String> out}) _terminal({String modes = ''}) {
  final out = <String>[];
  final terminal = Terminal(
    maxLines: 1000,
    mouseHandler: const PtyMouseHandler(),
  );
  terminal.onOutput = out.add;
  if (modes.isNotEmpty) terminal.write(modes);
  return (terminal: terminal, out: out);
}

/// Every wheel report in [out], as `(code, x, y)`.
List<int> _wheelCodes(List<String> out) => [
  for (final s in out)
    if (RegExp(r'^\x1b\[<(\d+);\d+;\d+M$').firstMatch(s) case final m?)
      int.parse(m.group(1)!),
];

void main() {
  group('PtyMouseHandler', () {
    test('encodes the wheel as SGR 64/65, not xterm.dart 68/69', () {
      final t = _terminal(modes: _agentPaneModes);

      t.terminal.mouseInput(
        TerminalMouseButton.wheelUp,
        TerminalMouseButtonState.down,
        const CellOffset(9, 19),
      );
      t.terminal.mouseInput(
        TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        const CellOffset(9, 19),
      );

      // 1-based coordinates; 68/69 would carry the shift bit and be ignored by
      // the application (verified against a live Claude Code pane).
      expect(t.out, ['\x1b[<64;10;20M', '\x1b[<65;10;20M']);
    });

    test('reports nothing when the application never asked for the mouse', () {
      // No DECSET at all: a plain shell. Returning null here leaves xterm's own
      // arrow-key simulation in charge instead of sending bytes a shell would
      // read as line-editing.
      final t = _terminal();

      final handled = t.terminal.mouseInput(
        TerminalMouseButton.wheelUp,
        TerminalMouseButtonState.down,
        const CellOffset(0, 0),
      );

      expect(handled, isFalse);
      expect(t.out, isEmpty);
    });

    test('does not report a wheel release', () {
      final t = _terminal(modes: _agentPaneModes);

      final handled = t.terminal.mouseInput(
        TerminalMouseButton.wheelUp,
        TerminalMouseButtonState.up,
        const CellOffset(0, 0),
      );

      expect(handled, isFalse);
      expect(t.out, isEmpty);
    });

    test('leaves button clicks to xterm — only the wheel was wrong', () {
      final t = _terminal(modes: _agentPaneModes);

      t.terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        const CellOffset(9, 19),
      );

      expect(t.out, ['\x1b[<0;10;20M']);
    });
  });

  group('drag on the terminal view', () {
    testWidgets('scrolls an alt-screen agent pane with wheel reports', (
      tester,
    ) async {
      final t = _terminal(modes: _agentPaneModes);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TerminalView(t.terminal))),
      );
      await tester.pumpAndSettle();
      expect(t.terminal.isUsingAltBuffer, isTrue);
      t.out.clear();

      // Dragging the content down reveals what came before it — wheel up.
      await tester.drag(find.byType(TerminalView), const Offset(0, 240));
      await tester.pumpAndSettle();
      final up = _wheelCodes(t.out);
      expect(up, isNotEmpty);
      expect(up, everyElement(64));

      t.out.clear();
      await tester.drag(find.byType(TerminalView), const Offset(0, -240));
      await tester.pumpAndSettle();
      final down = _wheelCodes(t.out);
      expect(down, isNotEmpty);
      expect(down, everyElement(65));
    });

    testWidgets('sends nothing on a plain pane, which scrolls locally', (
      tester,
    ) async {
      // No alternate screen: xterm's own scrollback owns the gesture, and
      // nothing should reach the PTY — a shell would read arrow keys as
      // history recall.
      final t = _terminal();
      for (var i = 0; i < 80; i++) {
        t.terminal.write('line $i\r\n');
      }
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TerminalView(t.terminal))),
      );
      await tester.pumpAndSettle();
      t.out.clear();

      await tester.drag(find.byType(TerminalView), const Offset(0, 240));
      await tester.pumpAndSettle();

      expect(t.out, isEmpty);
    });
  });
}
