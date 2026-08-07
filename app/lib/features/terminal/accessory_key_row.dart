import 'package:flutter/material.dart';

import '../../core/widgets/accessory_button.dart';
import 'direction_pad.dart';

/// D6: the single bar above the soft keyboard — **exactly seven buttons, always
/// the same seven**, evenly spread:
///
/// ```
/// Esc   ^C   ⋯   [pad]   Tab   ⌨   🖼
/// ```
///
/// Fixed is the whole point. The pad toggle is the 4th of 7, so it sits on the
/// bar's centre line, directly under the pad it opens — and that is true by
/// construction rather than by luck. The earlier version of this row grew with
/// the user's config: it prepended one button per saved quick command and
/// carried `+` and a sticky `Ctrl`, so a single saved command (or the image
/// button added later) pushed the toggle off centre and pushed the strip past
/// the screen, where `spaceEvenly` has no free space to distribute and the
/// whole thing left-aligns and scrolls. A bar whose layout depends on what you
/// have saved is a bar that is never quite in the same place twice.
///
/// Everything variable therefore lives behind `⋯` in the more-sheet: the
/// control bytes beyond `^C`, the quick commands, and adding one. See
/// [showTerminalMoreSheet].
///
/// What stayed, and why:
/// - **Esc / Tab** — no soft keyboard has them, and agent TUIs want both.
/// - **^C** — the emergency stop. It must never cost two taps, so it is the one
///   control byte that keeps a place of its own.
/// - **the pad toggle** — arrows are what agent TUIs ask for most (D6).
/// - **the keyboard toggle** — a screen control, not a keystroke; without it the
///   soft keyboard only ever appears as a side effect of tapping the buffer,
///   which is also how you scroll it.
/// - **attach an image** — it types a path into the pane, so it belongs with the
///   input controls rather than up in the app bar.
///
/// Seven small buttons plus their spacing measure ~374dp against a 393–412dp
/// phone, so the row fits and genuinely spreads. It stays inside a horizontal
/// scroll view anyway, for very narrow phones and large text scales.
class AccessoryKeyRow extends StatelessWidget {
  const AccessoryKeyRow({
    super.key,
    required this.padOpen,
    required this.onTogglePad,
    required this.keyboardOpen,
    required this.onToggleKeyboard,
    required this.moreArmed,
    required this.onMore,
    required this.uploading,
    required this.onAttachImage,
    required this.onKey,
  });

  final bool padOpen;
  final VoidCallback onTogglePad;
  final bool keyboardOpen;
  final VoidCallback onToggleKeyboard;

  /// Lights `⋯` when the sheet left something armed — today, sticky Ctrl. The
  /// sheet closes on use, so without this the armed state would be invisible
  /// and the next letter typed would come out mangled with no warning.
  final bool moreArmed;
  final VoidCallback onMore;

  /// Lights the image button while an upload is in flight; a tap is a no-op
  /// then, so one upload at a time and the strip above always describes the one
  /// being watched.
  final bool uploading;
  final VoidCallback onAttachImage;

  /// Raw bytes for the PTY.
  final void Function(String bytes) onKey;

  /// How many buttons this row has, always. Pinned as a constant because the
  /// count *is* the design (see the class doc) and a test asserts it.
  static const int buttonCount = 7;

  /// Index of the arrow-pad toggle — the middle button. Also asserted.
  static const int padToggleIndex = 3;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Container(
        // Two M3 steps below the buttons' own `surfaceContainerHighest`, not
        // one: at one step the buttons and the bar behind them are close enough
        // to read as a single flat slab.
        color: scheme.surfaceContainerLow,
        // Wide side margins: a curved screen's glass falls away at the edge, so
        // a button sitting 8dp in gets its corner cut off. SafeArea covers a
        // notch, not a curve — phones don't report a side inset for one in
        // portrait — so the clearance has to be spent here.
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final buttons = <Widget>[
              AccessoryButton(label: 'Esc', onTap: () => onKey('\x1b')),
              AccessoryButton(label: '^C', onTap: () => onKey('\x03')),
              AccessoryButton(
                icon: Icons.more_horiz,
                active: moreArmed,
                onTap: onMore,
                semanticLabel: 'More keys and commands',
                tooltip: 'More keys and commands',
              ),
              DirectionPadToggle(open: padOpen, onToggle: onTogglePad),
              AccessoryButton(label: 'Tab', onTap: () => onKey('\t')),
              KeyboardToggle(open: keyboardOpen, onToggle: onToggleKeyboard),
              AccessoryButton(
                icon: Icons.add_photo_alternate_outlined,
                onTap: uploading ? () {} : onAttachImage,
                active: uploading,
                semanticLabel: 'Attach an image',
                tooltip: 'Attach an image',
              ),
            ];
            assert(buttons.length == buttonCount);

            // Spread evenly — which it can, now that the row fits. The scroll
            // view is the safety net for a very narrow phone or a large text
            // scale, not the normal case it used to be. The minimum gap is 4dp
            // rather than the 6dp of the variable-width row: seven buttons plus
            // 6dp gaps measure ~2dp wider than a 393dp phone's bar, and 2dp of
            // overflow is enough to strand `spaceEvenly` with no free space and
            // knock the pad toggle off the centre line — which is the entire
            // property this row exists to hold.
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var i = 0; i < buttons.length; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      buttons[i],
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
