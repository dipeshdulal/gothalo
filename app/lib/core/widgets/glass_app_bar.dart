import 'package:flutter/material.dart';

import '../glass.dart';

/// An app bar made of [GlassSurface] — content scrolls *underneath* it, blurred.
///
/// Pair it with `extendBodyBehindAppBar: true` on the [Scaffold] and give the
/// body [GlassAppBar.padding] as top padding. Without both, the bar is opaque
/// chrome with nothing behind it and the blur is wasted.
///
/// The blur is lighter than the composer's (18 vs 24): a header sits over
/// scrolling text all the time, and at high sigma the smear of a moving list
/// behind it is more distracting than atmospheric.
class GlassAppBar extends AppBar {
  GlassAppBar({
    super.key,
    super.title,
    super.leading,
    super.actions,
    super.bottom,
    super.automaticallyImplyLeading,
    super.titleSpacing,
  }) : super(
         backgroundColor: Colors.transparent,
         surfaceTintColor: Colors.transparent,
         scrolledUnderElevation: 0,
         elevation: 0,
         flexibleSpace: const _GlassBackground(),
       );

  /// The space a [GlassAppBar] occupies, status bar included — what a body
  /// behind it needs as top padding so its first row starts below the glass
  /// rather than under it.
  ///
  /// [tabs] adds the [TabBar] row; pass true whenever the bar has a `bottom`.
  static double padding(BuildContext context, {bool tabs = false}) =>
      MediaQuery.paddingOf(context).top +
      kToolbarHeight +
      (tabs ? kTextTabBarHeight : 0);
}

/// The bar's material: blur plus tint plus a hairline along the bottom edge —
/// the only edge that meets content.
class _GlassBackground extends StatelessWidget {
  const _GlassBackground();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GlassSurface(
      blur: 18,
      opacity: dark ? 0.55 : 0.68,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: 1,
          color: dark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.07),
        ),
      ),
    );
  }
}
