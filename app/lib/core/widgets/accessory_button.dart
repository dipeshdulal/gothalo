import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// One button of the terminal's accessory bars — the single visual vocabulary
/// for everything below the buffer: the key strip (Esc/Ctrl/Tab/^C), the arrow
/// pad's toggle, and the quick-command row above them.
///
/// It exists because those three started out in different vocabularies — filled
/// mono key blocks under outlined Material chips with proportional text — which
/// read as two unrelated toolbars stacked on one screen. One primitive keeps the
/// radius, height and type identical, and lets width be the only thing that
/// varies: [size]-square for a single glyph, intrinsic for a label. The terminal
/// key row can opt into the same quiet outlined treatment as the app's action
/// chips without changing the more-sheet's denser key styling.
class AccessoryButton extends StatelessWidget {
  const AccessoryButton({
    super.key,
    this.label,
    this.icon,
    this.leading,
    required this.onTap,
    this.onLongPress,
    this.active = false,
    this.outlined = false,
    this.semanticLabel,
    this.tooltip,
  }) : assert(
         label != null || icon != null,
         'AccessoryButton needs a label or an icon',
       );

  /// Text face of the button. Sizes the button to fit, with a floor of [size].
  final String? label;

  /// Glyph face of the button, for a control with no good short word.
  final IconData? icon;

  /// Small glyph before [label] — marks a quick command that fires a raw
  /// keystroke rather than typing text.
  final IconData? leading;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Lit: a sticky modifier that's armed, or a panel that's open.
  final bool active;

  /// Uses the flat, hairline-edged action-chip surface instead of the filled
  /// terminal-key surface. Scoped callers can adopt the quieter treatment
  /// without restyling the terminal more-sheet at the same time.
  final bool outlined;

  final String? semanticLabel;
  final String? tooltip;

  /// The bar's unit block. Small, because seven of them plus their spacing and
  /// a curved screen's edge clearance has to fit a ~393dp phone row; uniform,
  /// because the row spreads its buttons evenly and one odd size would break
  /// that read.
  static const Size size = Size(42, 34);

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(10));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color fg;
    final Color fill;
    if (active && outlined) {
      fg = scheme.onPrimaryContainer;
      fill = scheme.primaryContainer;
    } else if (active) {
      fg = scheme.onPrimary;
      fill = scheme.primary;
    } else if (outlined) {
      fg = scheme.onSurface;
      fill = scheme.panelFill;
    } else {
      fg = scheme.onSurface;
      fill = scheme.surfaceContainerHighest;
    }

    Widget face;
    if (icon != null) {
      face = Icon(icon, size: 19, color: fg, semanticLabel: semanticLabel);
    } else {
      face = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            Icon(leading, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label!,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: AppTheme.monoFamily,
            ),
          ),
        ],
      );
      face = Semantics(label: semanticLabel, child: face);
    }

    final radius = outlined ? Radii.smAll : _radius;
    final button = Material(
      // Keep the filled variant's Material colour observable to existing
      // terminal controls/tests; the outlined variant paints its panel in the
      // child so its border and fill share one shape.
      color: outlined ? Colors.transparent : fill,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          height: size.height,
          constraints: BoxConstraints(minWidth: size.width),
          padding: EdgeInsets.symmetric(horizontal: label != null ? 8 : 0),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: outlined ? fill : null,
            borderRadius: radius,
            border: outlined ? Border.all(color: scheme.hairline) : null,
          ),
          child: face,
        ),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
