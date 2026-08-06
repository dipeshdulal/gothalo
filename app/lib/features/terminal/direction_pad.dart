import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/widgets/accessory_button.dart';

/// An arrow cluster for the terminal — the inverted-T layout of a desktop
/// keyboard's arrow keys, which is what agent TUIs (menus, history, approval
/// prompts) actually want from a phone.
///
/// It is a popup, not a fixture: [DirectionPadToggle] in the accessory row
/// opens it directly above itself and closes it again. That keeps the arrows
/// one tap away without permanently spending either a row of an already-short
/// viewport or a patch of the buffer. It's translucent so the text it does
/// cover stays readable while it's open.
///
/// Holding a key auto-repeats, so walking a long menu isn't forty taps.
class DirectionPad extends StatelessWidget {
  const DirectionPad({super.key, required this.onKey});

  /// The bytes for the pressed key, ready for the PTY (`\e[A`, `\r`, `\x7f`).
  final void Function(String bytes) onKey;

  /// Size of the pad, exposed for callers that need to reason about the space
  /// it covers.
  static const Size size = Size(_width, _height);

  static const double _keySize = 46;
  static const double _gap = 4;
  static const double _inset = 6;
  static const double _width = _keySize * 3 + _gap * 2 + _inset * 2;
  static const double _height = _keySize * 3 + _gap * 2 + _inset * 2;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.fromSize(
      size: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          // Frosted rather than merely transparent: the terminal stays legible
          // underneath without the glyphs fighting the key labels.
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(_inset),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The arrows keep the inverted-T of a desktop keyboard, so
                  // the shape itself says which key is which.
                  _PadKey(
                    icon: Icons.keyboard_arrow_up,
                    semanticLabel: 'Up',
                    onKey: () => onKey('\x1b[A'),
                  ),
                  const SizedBox(height: _gap),
                  Row(
                    children: [
                      _PadKey(
                        icon: Icons.keyboard_arrow_left,
                        semanticLabel: 'Left',
                        onKey: () => onKey('\x1b[D'),
                      ),
                      const SizedBox(width: _gap),
                      _PadKey(
                        icon: Icons.keyboard_arrow_down,
                        semanticLabel: 'Down',
                        onKey: () => onKey('\x1b[B'),
                      ),
                      const SizedBox(width: _gap),
                      _PadKey(
                        icon: Icons.keyboard_arrow_right,
                        semanticLabel: 'Right',
                        onKey: () => onKey('\x1b[C'),
                      ),
                    ],
                  ),
                  const SizedBox(height: _gap),
                  Row(
                    children: [
                      _PadKey(
                        icon: Icons.backspace_outlined,
                        semanticLabel: 'Backspace',
                        // DEL, not BS — what a terminal's erase key sends.
                        onKey: () => onKey('\x7f'),
                      ),
                      const SizedBox(width: _gap),
                      // Enter takes the rest of the row: it's the key you hit
                      // hardest and the one you least want to miss.
                      _PadKey(
                        icon: Icons.keyboard_return,
                        semanticLabel: 'Enter',
                        width: _keySize * 2 + _gap,
                        // Never auto-repeat a submit — a leaned-on thumb would
                        // fire the same prompt a dozen times.
                        repeat: false,
                        onKey: () => onKey('\r'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The accessory-bar button that summons and dismisses the soft keyboard.
/// Nothing else on the terminal screen does that deliberately — the keyboard
/// otherwise comes and goes as a side effect of tapping the buffer, which is
/// also how you scroll it.
class KeyboardToggle extends StatelessWidget {
  const KeyboardToggle({super.key, required this.open, required this.onToggle});

  /// Whether the soft keyboard is currently up.
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final label = open ? 'Hide keyboard' : 'Show keyboard';
    return AccessoryButton(
      icon: open ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined,
      onTap: onToggle,
      semanticLabel: label,
      tooltip: label,
    );
  }
}

/// The accessory-bar button that opens and closes the [DirectionPad] above it.
/// Lit while the pad is open, so the bar itself shows whether the arrows are
/// out — there's no other chrome saying so.
class DirectionPadToggle extends StatelessWidget {
  const DirectionPadToggle({
    super.key,
    required this.open,
    required this.onToggle,
  });

  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return AccessoryButton(
      icon: Icons.control_camera,
      active: open,
      onTap: onToggle,
      semanticLabel: open ? 'Hide arrows' : 'Show arrows',
      tooltip: open ? 'Hide arrows' : 'Show arrows',
    );
  }
}

/// One key of the [DirectionPad]. Fires on press (not release) and, unless
/// [repeat] is off, repeats while held — the way a real key does.
class _PadKey extends StatefulWidget {
  const _PadKey({
    required this.icon,
    required this.semanticLabel,
    required this.onKey,
    this.width = DirectionPad._keySize,
    this.repeat = true,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onKey;
  final double width;

  /// Off for keys where a held thumb would be destructive (Enter) or
  /// meaningless (the keyboard toggle).
  final bool repeat;

  @override
  State<_PadKey> createState() => _PadKeyState();
}

class _PadKeyState extends State<_PadKey> {
  /// Hold-to-repeat, matching typical keyboard auto-repeat: a pause to prove
  /// it's a hold and not a tap, then a steady stream.
  static const _repeatDelay = Duration(milliseconds: 400);
  static const _repeatInterval = Duration(milliseconds: 90);

  Timer? _delay;
  Timer? _repeat;
  bool _down = false;

  @override
  void dispose() {
    _delay?.cancel();
    _repeat?.cancel();
    super.dispose();
  }

  void _press() {
    setState(() => _down = true);
    widget.onKey();
    if (!widget.repeat) return;
    _delay = Timer(_repeatDelay, () {
      _repeat = Timer.periodic(_repeatInterval, (_) => widget.onKey());
    });
  }

  void _release() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
    if (mounted) setState(() => _down = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _press(),
      onTapUp: (_) => _release(),
      onTapCancel: _release,
      child: Container(
        width: widget.width,
        height: DirectionPad._keySize,
        decoration: BoxDecoration(
          color: _down
              ? scheme.primary.withValues(alpha: 0.85)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          widget.icon,
          size: 26,
          color: _down ? scheme.onPrimary : scheme.onSurface,
          semanticLabel: widget.semanticLabel,
        ),
      ),
    );
  }
}
