import 'package:xterm/xterm.dart';

/// Wheel-up / wheel-down as the SGR button codes a terminal application
/// actually expects. Mouse button reports are a bitfield: the low two bits are
/// the button, **bit 2 (value 4) is the shift modifier**, and bit 6 (value 64)
/// marks the "extra" buttons 4–7 — the wheel. So wheel-up is `64 | (4 - 4)` =
/// 64 and wheel-down is 65.
const _sgrWheelUp = 64;
const _sgrWheelDown = 65;

/// Mouse reporting for the live PTY, with xterm.dart's wheel encoding fixed.
///
/// Scrolling an alternate-screen pane from the phone can only work one way: the
/// application (Claude Code, an editor, a pager) owns the viewport and herdr
/// keeps **no scrollback** for it — every agent pane reports
/// `max_offset_from_bottom: 0`, and `pane read --source recent` returns exactly
/// the visible frame. So the drag has to reach the application itself as a
/// mouse wheel report, which is also how Moshi does it.
///
/// xterm.dart already converts the drag: on an alt-screen buffer its
/// `TerminalScrollGestureHandler` turns a vertical drag into wheel events. But
/// it encodes them from `TerminalMouseButton.wheelUp(id: 64 + 4)` /
/// `wheelDown(id: 64 + 5)`, emitting `ESC[<68;…M` and `ESC[<69;…M` — button 64
/// or 65 *with the shift bit set*. Applications read that as shift+wheel and
/// ignore it. Confirmed against a live Claude Code pane: five `ESC[<68;20;20M`
/// changed nothing, five `ESC[<64;20;20M` scrolled it.
///
/// Only wheel buttons are rewritten; clicks and drags fall through to xterm's
/// own handler, which encodes them correctly.
class PtyMouseHandler implements TerminalMouseHandler {
  const PtyMouseHandler([this._fallback = defaultMouseHandler]);

  final TerminalMouseHandler _fallback;

  @override
  String? call(TerminalMouseEvent event) {
    if (!event.button.isWheel) return _fallback(event);

    // The application has to have asked for scroll reporting (DECSET 1000 /
    // 1002 / 1003). Returning null when it hasn't leaves xterm's own fallback
    // in charge, which simulates the scroll with arrow keys.
    if (!event.state.mouseMode.reportScroll) return null;

    // A wheel "release" is not a thing — real terminals report the click only.
    if (event.buttonState == TerminalMouseButtonState.up) return null;

    final code = switch (event.button) {
      TerminalMouseButton.wheelUp => _sgrWheelUp,
      TerminalMouseButton.wheelDown => _sgrWheelDown,
      // Horizontal wheel: 66/67 by the same rule. No gesture produces these
      // today, but encode them rather than emitting a bogus button.
      TerminalMouseButton.wheelLeft => 66,
      TerminalMouseButton.wheelRight => 67,
      _ => null,
    };
    if (code == null) return _fallback(event);

    // Reports are 1-based; CellOffset is 0-based.
    final x = event.position.x + 1;
    final y = event.position.y + 1;

    return switch (event.state.mouseReportMode) {
      // The mode Claude Code (and anything else that sets DECSET 1006) uses.
      MouseReportMode.sgr => '\x1b[<$code;$x;${y}M',
      // Legacy X10 encoding: every field is offset by 32 into printable ASCII,
      // and a coordinate past the encodable range is sent as a null byte.
      MouseReportMode.normal || MouseReportMode.utf => '\x1b[M'
          '${String.fromCharCode(32 + code)}'
          '${_x10(x, event.state.mouseReportMode)}'
          '${_x10(y, event.state.mouseReportMode)}',
      MouseReportMode.urxvt => '\x1b[${32 + code};$x;${y}M',
    };
  }

  /// One X10-encoded coordinate, or a null byte when it doesn't fit the mode's
  /// range (223 for [MouseReportMode.normal], 2015 for [MouseReportMode.utf]).
  String _x10(int value, MouseReportMode mode) {
    final limit = mode == MouseReportMode.normal ? 223 : 2015;
    if (value > limit) return '\x00';
    return String.fromCharCode(32 + value);
  }
}
