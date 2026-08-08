import 'package:flutter/material.dart';

import 'theme.dart';

/// Background image asset paths, one per screen. Add a new entry, drop the file
/// in `assets/img/`, list it in pubspec, and pass it to [AppBackground] — that's
/// the whole recipe for a per-screen backdrop.
class Backgrounds {
  Backgrounds._();

  /// The Flock (inbox) screen — a flock grazing at the bottom.
  static const flock = 'assets/img/flock_bg.png';

  /// The Servers screen — a "server farm with sheep" scene.
  static const servers = 'assets/img/servers_bg.png';
}

/// A screen's **opaque** backdrop: the theme's dark gradient, with an optional
/// faint artwork faded over it, behind a transparent [Scaffold].
///
/// Every top-level screen wraps in this so it paints its OWN opaque background,
/// rather than relying on one gradient painted app-wide behind transparent
/// scaffolds. That app-wide approach looked fine at rest but broke page
/// transitions: with see-through scaffolds, a sliding page revealed the page
/// beneath it (and the gradient) through itself — reading as overlapping,
/// flickering screens. An opaque per-page backdrop slides as one solid layer.
///
/// Wrap a screen like:
/// ```dart
/// AppBackground(asset: Backgrounds.flock, child: Scaffold(...));  // with art
/// AppBackground(child: Scaffold(...));                            // gradient only
/// ```
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.child,
    this.asset,
    this.opacity = 0.18,
  });

  final Widget child;

  /// An optional faint artwork faded over the gradient. When null, the backdrop
  /// is just the gradient (still opaque — the point is a solid page).
  final String? asset;

  /// How present the artwork is. Kept low so it reads as a faint atmosphere
  /// behind the content, not a picture competing with it.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      // The opaque base — this is what makes the page a solid layer for a clean
      // slide transition.
      decoration: BoxDecoration(
        gradient: AppTheme.backgroundGradient(Theme.of(context).brightness),
      ),
      child: Stack(
        children: [
          // A single soft glow of the seed colour, off in one corner. It is the
          // cheapest way to make a flat gradient feel like it has a light
          // source, and it is what the blurred glass surfaces pick up and smear
          // — without it, blurring a near-flat backdrop produces nothing.
          Positioned(
            top: -140,
            right: -110,
            child: IgnorePointer(
              child: Container(
                width: 380,
                height: 380,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      scheme.primary.withValues(alpha: 0.14),
                      scheme.primary.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (asset != null)
            Positioned.fill(
              child: Opacity(
                opacity: opacity,
                child: Image.asset(
                  asset!,
                  fit: BoxFit.cover,
                  alignment: Alignment.bottomCenter,
                ),
              ),
            ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}
