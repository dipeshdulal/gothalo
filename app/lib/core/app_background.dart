import 'package:flutter/material.dart';

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

/// Paints a full-screen background image behind [child] (which should be a
/// transparent [Scaffold]). Images are designed dark-at-top / scene-at-bottom,
/// so content stays readable; a light top scrim guards busier images.
///
/// Wrap a screen like:
/// ```dart
/// AppBackground(asset: Backgrounds.flock, child: Scaffold(...));
/// ```
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.child,
    this.asset,
    this.opacity = 0.18,
  });

  final Widget child;

  /// The background asset; when null, [child] shows over the theme's own
  /// backdrop gradient (from `GothaloApp`).
  final String? asset;

  /// How present the artwork is. Kept low so it reads as a faint atmosphere
  /// behind the content, not a picture competing with it.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    if (asset == null) return child;
    return Stack(
      children: [
        // The theme's dark backdrop is already painted app-wide; fade the
        // artwork over it so only a hint shows through.
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
    );
  }
}
