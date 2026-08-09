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
    required this.label,
    required this.onTap,
    this.detail,
    this.detailChild,
    this.color,
    this.onLongPress,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// A muted trailing note — a port number, a count.
  final String? detail;

  /// A custom trailing note when text alone is not enough — for example, a
  /// compact icon-plus-count summary. It replaces [detail] when both are set.
  final Widget? detailChild;

  /// Overrides the icon and label colour. Null is the resting neutral.
  final Color? color;

  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chip = InkWell(
      borderRadius: Radii.smAll,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        // The chip is 32 tall; the row that holds it gives the tap slot its
        // height. Small control, adult-sized target.
        constraints: const BoxConstraints(minHeight: 32),
        decoration: BoxDecoration(
          color: scheme.panelFill,
          borderRadius: Radii.smAll,
          border: Border.all(color: scheme.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (detailChild != null) ...[
              const SizedBox(width: 6),
              detailChild!,
            ] else if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(width: 6),
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
    if (onLongPress == null) return chip;
    // GestureDetector rather than a parameter on the InkWell: wrapping keeps
    // the tap on the chip itself so the ink splash still reads as one control.
    return GestureDetector(onLongPress: onLongPress, child: chip);
  }
}
