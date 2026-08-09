import 'package:flutter/material.dart';

import '../tokens.dart';

/// A one-tap action, as a chip. **The** chip — there is not a second one.
///
/// The pane suggestions bar established this shape; the Flock screen's quick
/// actions now use the same widget rather than a second chip style, for the
/// same reason the agent row is shared: two chip implementations drift, and
/// then the app has two chip languages for one idea.
///
/// Flat, opaque, tight-cornered, hairline-edged — a chip is a small panel, not
/// a filled pill. [color] tints the icon and the label for the rare chip that
/// needs to say something about itself (a conflict is urgent; a chip that can
/// only half-act is dimmed); everything else stays neutral, because a row where
/// every chip shouts is a row you stop reading.
class AppActionChip extends StatelessWidget {
  const AppActionChip({
    super.key,
    required this.icon,
    this.label,
    required this.onTap,
    this.detail,
    this.detailChild,
    this.color,
    this.active = false,
    this.onLongPress,
    this.semanticLabel,
    this.tooltip,
  });

  final IconData icon;

  /// Optional text face. Omit it for a compact icon-only action; the caller
  /// should provide [semanticLabel] and [tooltip] in that case.
  final String? label;
  final VoidCallback onTap;

  /// A muted trailing note — a port number, a count.
  final String? detail;

  /// A custom trailing note when text alone is not enough — for example, a
  /// compact icon-plus-count summary. It replaces [detail] when both are set.
  final Widget? detailChild;

  /// Overrides the icon and label colour. Null is the resting neutral.
  final Color? color;

  /// Gives a toggle-like action a quiet selected surface without switching to a
  /// filled pill.
  final bool active;

  final VoidCallback? onLongPress;

  /// Spoken/long-press name for an icon-only chip.
  final String? semanticLabel;

  /// Optional tooltip for an icon-only chip.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = color ?? (active ? scheme.primary : null);
    final fill = active ? scheme.primaryContainer : scheme.panelFill;
    final chip = InkWell(
      borderRadius: Radii.smAll,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        // Keep the face compact while retaining a 32dp visual/tap floor; the
        // row that holds it supplies the surrounding breathing room.
        constraints: BoxConstraints(
          minHeight: 32,
          minWidth: label == null ? 36 : 0,
        ),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: Radii.smAll,
          border: Border.all(color: active ? scheme.primary : scheme.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: fg),
            if (label != null) ...[
              const SizedBox(width: 4),
              Text(
                label!,
                style: TextStyle(
                  color: fg,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            if (detailChild != null) ...[
              if (label != null) const SizedBox(width: 4),
              detailChild!,
            ] else if (detail != null && detail!.isNotEmpty) ...[
              if (label != null) const SizedBox(width: 4),
              Text(
                detail!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
    Widget result = chip;
    if (onLongPress != null) {
      // GestureDetector rather than a parameter on the InkWell: wrapping keeps
      // the tap on the chip itself so the ink splash still reads as one control.
      result = GestureDetector(onLongPress: onLongPress, child: result);
    }
    if (semanticLabel != null) {
      result = Semantics(button: true, label: semanticLabel, child: result);
    }
    if (tooltip != null) {
      result = Tooltip(message: tooltip!, child: result);
    }
    return result;
  }
}
