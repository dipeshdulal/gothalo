import 'package:flutter/material.dart';

import '../tokens.dart';

/// The app's standard content block: a flat, opaque, hairline-edged panel —
/// used for list rows, pane tiles, and anything that used to be a [ListTile]
/// or a card.
///
/// A panel in this language is held by its border, not by elevation or
/// translucency. [borderColor] tints that edge for a row that needs attention
/// (a blocked agent) or is otherwise live (the focused pane); [selected] lifts
/// the fill a single step.
class PanelRow extends StatelessWidget {
  const PanelRow({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.margin = const EdgeInsets.fromLTRB(
      Space.gutter,
      Space.xs,
      Space.gutter,
      Space.xs,
    ),
    this.borderColor,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  /// A status-tinted edge — blocked (error) or focused (primary). Null is the
  /// resting hairline.
  final Color? borderColor;

  /// A stronger fill, for the current/focused item.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? scheme.panelFillRaised : scheme.panelFill,
          borderRadius: Radii.mdAll,
          border: Border.all(color: borderColor ?? scheme.hairline, width: 1),
        ),
        // Material + InkWell rather than a bare GestureDetector: the ripple is
        // the only feedback on a panel with no other pressed state, and it has
        // to be clipped to the same radius or it paints square corners.
        child: Material(
          type: MaterialType.transparency,
          borderRadius: Radii.mdAll,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: Radii.mdAll,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// A section heading between groups of [PanelRow]s — small, uppercase,
/// wide-tracked, muted. [color] lets one section claim attention (a "NEEDS YOU"
/// row); [trailing] carries a mono count or a status note.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.color});

  final String text;
  final Widget? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
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
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.1,
                color: color ?? scheme.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
