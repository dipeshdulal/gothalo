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

/// A screen's **opaque** backdrop: a flat [AppTheme.scaffoldBase] fill, with an
/// optional faint artwork faded over it, behind a transparent [Scaffold].
///
/// Terminal-native means flat: one even colour, and panels hold themselves with
/// hairlines rather than by being lit from behind. A single flat colour is also
/// what makes the otherwise-transparent Android status bar read as intentional —
/// the bar sits over the same colour the page uses, so it is one surface, not a
/// cut. The fill is opaque, which is what makes a sliding page move as one solid
/// layer instead of revealing the page beneath.
///
/// Wrap a screen like:
/// ```dart
/// AppBackground(child: Scaffold(...));                            // flat only
/// AppBackground(asset: Backgrounds.flock, child: Scaffold(...));  // + faint art
/// ```
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.child,
    this.asset,
    this.opacity = 0.14,
  });

  final Widget child;

  /// An optional faint artwork faded over the flat fill. When null, the backdrop
  /// is just the flat colour (still opaque — the point is a solid page).
  final String? asset;

  /// How present the artwork is. Kept low so it reads as a faint atmosphere
  /// behind the content, not a picture competing with it.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // The opaque base — one even colour so the status bar over its top reads
      // as one surface, and a solid layer for a clean slide transition.
      decoration: BoxDecoration(
        color: AppTheme.scaffoldBase(Theme.of(context).brightness),
      ),
      child: Stack(
        children: [
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
