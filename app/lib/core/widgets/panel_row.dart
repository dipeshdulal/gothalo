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
      3,
      Space.gutter,
      3,
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
      // A little more above than below: the label belongs to the rows under
      // it, and the gap that matters is the one separating it from the section
      // before.
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.xl + Space.sm,
        Space.gutter,
        Space.md,
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


/// A run of rows sharing **one** panel, divided by hairlines, with an optional
/// footer inside the same edge.
///
/// The alternative — every row carrying its own outline — turns a list into a
/// grid of boxes: the same hairline that separates one panel from the page
/// reads as heavy when it is repeated a dozen times down a column. The edge is
/// not too strong (the agent lists need exactly that contrast to be legible);
/// there is simply one too many of them. So a list of small, related things
/// gets one border round the lot and hairlines between.
///
/// A [PanelRow] is still right for a row that is its own subject — an agent you
/// act on. This is for rows that are a list.
class PanelList extends StatelessWidget {
  const PanelList({
    super.key,
    required this.rows,
    this.footer,
    this.margin = const EdgeInsets.fromLTRB(
      Space.gutter,
      Space.xs,
      Space.gutter,
      Space.xs,
    ),
  });

  final List<Widget> rows;

  /// Drawn below a divider inside the panel — a "show N more", say.
  final Widget? footer;

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.panelFill,
          borderRadius: Radii.mdAll,
          border: Border.all(color: scheme.hairline, width: 1),
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: Radii.mdAll,
          // Clipped, or a row's ink ripple paints square corners over the
          // panel's rounded ones.
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const PanelDivider(),
                rows[i],
              ],
              if (footer != null) ...[const PanelDivider(), footer!],
            ],
          ),
        ),
      ),
    );
  }
}

/// The line between two rows inside one [PanelList]. Inset past the leading
/// glyph so the rows read as a list rather than as stacked cells, and drawn at
/// [AppSurfaces.hairline] — the same edge the panel itself uses, because it is
/// the same idea.
class PanelDivider extends StatelessWidget {
  const PanelDivider({super.key, this.indent = 10});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Container(
        height: 1,
        color: Theme.of(context).colorScheme.hairline,
      ),
    );
  }
}
