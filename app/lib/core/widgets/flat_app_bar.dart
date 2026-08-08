import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// The app's header bar: a **frosted** bar — content blurred and scrimmed
/// behind it — with a single hairline along the bottom edge.
///
/// The bar sits over a scrolling list (`extendBodyBehindAppBar: true`), so it
/// needs to be *something*. It was fully transparent, which on a real phone
/// read as broken: rows slid up and showed through behind the title, and a
/// bright working row or a red needs-you row under the bar left the title
/// fighting the row for legibility.
///
/// **This is not a return to glass.** `glass.dart` went away with the
/// glass-and-cards direction and stays away: panels, cards and sheets are flat
/// and opaque, and nothing else in the app blurs. The bar is the one surface
/// with moving content behind it by construction, which is the one place the
/// effect is doing work rather than decorating.
///
/// The scrim, not the blur, is what makes it legible. Blur alone leaves a red
/// row as a red smear; [_scrimAlpha] of the page's own colour is what pulls any
/// row back to a tint. See [_FrostedBar].
///
/// Pair it with `extendBodyBehindAppBar: true` on the [Scaffold] and give the
/// body [FlatAppBar.padding] as top padding. Without both, the bar is opaque
/// chrome with nothing behind it — no blur to see and a hairline with nothing
/// to sit against.
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
         flexibleSpace: const _FrostedBar(),
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

/// How much of the page's own colour is laid over the blurred content.
///
/// Tuned against the worst case rather than the average one: a red `needs you`
/// row or a teal-bordered working row scrolled directly under the bar. At 0.86
/// a row's colour survives as a faint tint — enough that the bar is visibly
/// *over* something — while the title and the action icons keep essentially
/// their full contrast against the page colour they were chosen for. Lower
/// values look better on a quiet grey list and fail on exactly the rows that
/// matter most.
const double _scrimAlpha = 0.86;

/// How far the blur reaches. Large enough that text under the bar becomes
/// texture rather than half-readable words, which is the state that actually
/// looks broken.
const double _blurSigma = 18;

/// The bar's surface: blur, scrim, and a hairline along the bottom — the only
/// edge that meets content.
class _FrostedBar extends StatelessWidget {
  const _FrostedBar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The page's own base colour, not `surface`: the backdrop behind every
    // screen is `AppBackground`'s flat fill, so scrimming with anything else
    // would leave the bar a visibly different shade from the page it sits on.
    final base = AppTheme.scaffoldBase(theme.brightness);
    return ClipRect(
      // Clipped: BackdropFilter samples — and would paint — outside its bounds
      // otherwise, which smears the blur down over the first row of content.
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: base.withValues(alpha: _scrimAlpha),
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.hairlineStrong,
                width: 1,
              ),
            ),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
