import 'package:flutter/material.dart';

import '../tokens.dart';

/// The app's standard content block: a rounded, translucent, hairline-edged
/// surface — used for list rows, panels, and anything that used to be a
/// [ListTile] separated by a [Divider].
///
/// Rows became cards on purpose. A divider-separated list says "these are lines
/// in one table"; spaced cards say "these are separate things you can act on",
/// which is what an agent, a server, or a workspace actually is. It also gives
/// status somewhere to live: [accent] tints the whole card's edge and glow, so a
/// blocked agent is visible from across the room rather than being a small
/// coloured dot in a wall of identical rows.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    this.margin = const EdgeInsets.fromLTRB(
      Space.gutter,
      Space.xs,
      Space.gutter,
      Space.xs,
    ),
    this.accent,
    this.selected = false,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  /// Tints the edge and casts a soft glow of the same colour — for a row that
  /// needs attention (blocked) or is otherwise live. Null is the resting state.
  final Color? accent;

  /// A stronger fill, for the current/focused item.
  final bool selected;

  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = borderRadius ?? Radii.mdAll;
    final accent = this.accent;

    return Padding(
      padding: margin,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        decoration: BoxDecoration(
          color: selected ? scheme.cardFillStrong : scheme.cardFill,
          borderRadius: radius,
          border: Border.all(
            color: accent?.withValues(alpha: 0.45) ?? scheme.hairline,
            width: accent != null ? 1 : 0.5,
          ),
          boxShadow: accent != null
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.14),
                    blurRadius: 16,
                    spreadRadius: -2,
                  ),
                ]
              : null,
        ),
        // Material + InkWell rather than a bare GestureDetector: the ripple is
        // the only feedback on a card with no other pressed state, and it has
        // to be clipped to the same radius or it paints square corners.
        child: Material(
          type: MaterialType.transparency,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: radius,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// A section heading between groups of [AppCard]s — small, wide-tracked, muted.
/// Cards give a list rhythm; this gives it structure without drawing a line.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter + 2,
        Space.lg,
        Space.gutter,
        Space.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.9,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
