import 'package:flutter/material.dart';

import '../data/bridge/models/snapshot.dart';

/// gothalo's Material 3 themes. Dark-first (a terminal remote lives in the
/// dark), but a light theme is provided too and [ThemeMode.system] lets the OS
/// decide. Seeded from a single teal so both modes stay in family.
class AppTheme {
  AppTheme._();

  static const _seed = Color(0xFF00BFA5); // Herdr-ish teal

  /// UI typeface (bundled Inter).
  static const fontFamily = 'Inter';

  /// Monospace family (bundled JetBrains Mono) — pane ids, code, the terminal.
  static const monoFamily = 'JetBrains Mono';

  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  /// A subtle full-screen backdrop gradient, painted behind every screen (see
  /// [GothaloApp]). Kept low-contrast so content and cards still read clearly —
  /// a faint teal glow up top fading to near-black.
  static Gradient backgroundGradient(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF102021), Color(0xFF0A0E0F), Color(0xFF0C1314)],
        stops: [0.0, 0.5, 1.0],
      );
    }
    return const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFF1F6F5), Color(0xFFE8F0EF)],
    );
  }

  /// A flat, **opaque** backdrop colour matching the gradient's base — for
  /// utility screens that just need a solid, transition-safe background rather
  /// than the full [AppBackground] gradient/artwork. Near-identical to the
  /// gradient's midpoint, so pages read consistently either way.
  static Color scaffoldBase(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF0A0E0F)
      : const Color(0xFFECF2F1);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      // A dead-simple screen switch (see [_SimpleSlideTransitionsBuilder]).
      // The two built-ins both read as "weird" here: Zoom (Android default)
      // scale-cross-fades so two screens sit half-visible on a slow gesture,
      // and Cupertino adds an iOS parallax that feels foreign on Android. A
      // plain slide-over — new screen in from the right, old one static, no
      // fade, no parallax — is the least surprising thing. Same on both
      // platforms so they behave identically.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _SimpleSlideTransitionsBuilder(),
          TargetPlatform.iOS: _SimpleSlideTransitionsBuilder(),
        },
      ),
      // Transparent by default so an [AppBackground]-wrapped screen shows its
      // own gradient/artwork through the Scaffold. Utility screens that aren't
      // wrapped set an opaque [AppTheme.scaffoldBase] on their Scaffold so they
      // still slide as a solid layer.
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
        // Set HERE, not per screen. Three screens had already picked 12 while
        // the rest kept Material's 16, so headers drifted apart before anyone
        // looked; a per-screen override is how that happens. Flutter has no
        // themeable leadingWidth, which is exactly why nothing should override
        // it locally either — one screen tightening its back button is
        // immediately visible as inconsistent when you move between them.
        titleSpacing: 12,
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }
}

/// The app's page transition: the incoming route slides in from the right and
/// the outgoing route (revealed on a back) slides back out the same way —
/// nothing else. No opacity cross-fade (so two screens never sit half-visible
/// at once — the original "it went transparent" complaint), no parallax on the
/// page underneath, no scale. Just a clean left/right slide, the least
/// surprising "switched screens" motion.
class _SimpleSlideTransitionsBuilder extends PageTransitionsBuilder {
  const _SimpleSlideTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // `animation` runs forward on push and reverse on pop, so driving the
    // top route's position off it covers both directions: it slides in from
    // the right on push and back out to the right on pop. The route beneath
    // isn't touched (secondaryAnimation ignored), so it just sits still.
    return SlideTransition(
      position: animation.drive(
        Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
      ),
      child: child,
    );
  }
}

/// The palette + label + icon for each [AgentStatus], resolved against the
/// active [ColorScheme] so badges read well in light and dark.
extension AgentStatusUi on AgentStatus {
  String get label => switch (this) {
    AgentStatus.idle => 'Idle',
    AgentStatus.working => 'Working',
    AgentStatus.blocked => 'Blocked',
    AgentStatus.done => 'Done',
    AgentStatus.unknown => 'Unknown',
  };

  IconData get icon => switch (this) {
    AgentStatus.idle => Icons.pause_circle_outline,
    AgentStatus.working => Icons.autorenew,
    AgentStatus.blocked => Icons.pan_tool_outlined,
    AgentStatus.done => Icons.check_circle_outline,
    AgentStatus.unknown => Icons.help_outline,
  };

  /// Background/foreground for the badge, tuned per brightness.
  ({Color bg, Color fg}) colors(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    Color pair(Color base) =>
        dark ? base.withValues(alpha: 0.22) : base.withValues(alpha: 0.14);
    Color fg(Color base) => dark
        ? base
        : Color.alphaBlend(base.withValues(alpha: 0.85), Colors.black);

    return switch (this) {
      AgentStatus.blocked => (
        bg: pair(const Color(0xFFFF5252)),
        fg: fg(const Color(0xFFFF5252)),
      ),
      AgentStatus.working => (
        bg: pair(const Color(0xFF448AFF)),
        fg: fg(const Color(0xFF448AFF)),
      ),
      AgentStatus.done => (
        bg: pair(const Color(0xFF69F0AE)),
        fg: fg(const Color(0xFF00C853)),
      ),
      AgentStatus.idle => (
        bg: scheme.surfaceContainerHighest,
        fg: scheme.onSurfaceVariant,
      ),
      AgentStatus.unknown => (
        bg: scheme.surfaceContainerHighest,
        fg: scheme.onSurfaceVariant,
      ),
    };
  }
}
