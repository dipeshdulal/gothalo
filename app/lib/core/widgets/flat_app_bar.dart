import 'package:flutter/material.dart';

import '../tokens.dart';

/// The app's header bar: flat chrome with a single hairline along the bottom
/// edge. No blur, no tint lift, no scrolled-under change — the backdrop behind
/// a transparent scaffold is already opaque, so the bar is just the page's
/// colour with a rule underneath it. This replaces the earlier blurred
/// glass bar: terminal-native means flat.
///
/// Pair it with `extendBodyBehindAppBar: true` on the [Scaffold] and give the
/// body [FlatAppBar.padding] as top padding. Without both, the bar is opaque
/// chrome with nothing behind it and the hairline has nothing to sit against.
class FlatAppBar extends AppBar {
  FlatAppBar({
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
         flexibleSpace: const _BottomHairline(),
       );

  /// The space a [FlatAppBar] occupies, status bar included — what a body
  /// behind it needs as top padding so its first row starts below the bar
  /// rather than under it.
  ///
  /// [tabs] adds the [TabBar] row; pass true whenever the bar has a `bottom`.
  static double padding(BuildContext context, {bool tabs = false}) =>
      MediaQuery.paddingOf(context).top +
      kToolbarHeight +
      (tabs ? kTextTabBarHeight : 0);
}

/// The bar's only decoration: a 1px hairline along the bottom edge — the only
/// edge that meets content.
class _BottomHairline extends StatelessWidget {
  const _BottomHairline();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        height: 1,
        color: Theme.of(context).colorScheme.hairlineStrong,
      ),
    );
  }
}
