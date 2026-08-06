import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// One button of the terminal's accessory bars — the single visual vocabulary
/// for everything below the buffer: the key strip (Esc/Ctrl/Tab/^C), the arrow
/// pad's toggle, and the quick-command row above them.
///
/// It exists because those three started out in different vocabularies — filled
/// mono key blocks under outlined Material chips with proportional text — which
/// read as two unrelated toolbars stacked on one screen. One primitive keeps
/// the fill, radius, height and type identical, and lets width be the only
/// thing that varies: [size]-square for a single glyph, intrinsic for a label.
class AccessoryButton extends StatelessWidget {
  const AccessoryButton({
    super.key,
    this.label,
    this.icon,
    this.leading,
    required this.onTap,
    this.onLongPress,
    this.active = false,
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
    final fg = active ? scheme.onPrimary : scheme.onSurface;

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

    final button = Material(
      color: active ? scheme.primary : scheme.surfaceContainerHighest,
      borderRadius: _radius,
      child: InkWell(
        borderRadius: _radius,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          height: size.height,
          constraints: BoxConstraints(minWidth: size.width),
          padding: EdgeInsets.symmetric(horizontal: label != null ? 8 : 0),
          alignment: Alignment.center,
          child: face,
        ),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
