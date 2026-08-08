import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// A translucent, blurred surface — the app's "glass" material.
///
/// Use it for chrome that sits **over** content: the transcript's composer, a
/// bottom bar, a floating header. The blur only reads as glass when something
/// is painted behind it, so a glass panel must overlay the scrolling content
/// (a [Stack]), not sit beside it in a [Column] — over a flat backdrop the
/// blur has nothing to work with and the panel just looks washed out.
///
/// The tint is deliberately opaque enough to keep text legible: pure
/// transparency over a busy transcript makes a hint or a chip label unreadable
/// exactly when the user is typing. Blur + a ~60% tint keeps the content
/// underneath as a suggestion of depth rather than something you try to read.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blur = 24,
    this.opacity,
    this.borderRadius,
    this.topBorder = false,
    this.border = false,
  });

  final Widget child;

  /// Gaussian sigma for the backdrop blur. Higher reads softer/frostier; much
  /// above ~30 costs real GPU time on a phone for no visible gain.
  final double blur;

  /// Tint strength over the blur. Defaults per brightness — a dark theme needs
  /// less tint to stay legible than a light one.
  final double? opacity;

  final BorderRadius? borderRadius;

  /// A hairline along the top edge only — for bars pinned to the bottom of the
  /// screen, where the top edge is the only one that meets content.
  final bool topBorder;

  /// A hairline all the way round — for floating cards and sheets.
  final bool border;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = borderRadius ?? BorderRadius.zero;
    final tint = scheme.surfaceContainerHigh.withValues(
      alpha: opacity ?? (dark ? 0.62 : 0.72),
    );
    final line = BorderSide(
      color: dark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.06),
    );

    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: radius,
            border: border
                ? Border.fromBorderSide(line)
                : (topBorder ? Border(top: line) : null),
          ),
          child: child,
        ),
      ),
    );
  }
}
