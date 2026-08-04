import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
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

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      // Android's default (Zoom: scale + cross-fade) looks broken on a slow
      // back-swipe — both screens sit at partial opacity at once, so the
      // outgoing one reads as "gone transparent" over the incoming one. A
      // plain slide has no opacity blending at any drag position, so every
      // frame of a slow or held gesture still looks correct. Applied on both
      // platforms so the two behave identically.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      // Transparent so the app-wide backdrop gradient shows through.
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
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
    Color pair(Color base) => dark ? base.withValues(alpha: 0.22) : base.withValues(alpha: 0.14);
    Color fg(Color base) => dark ? base : Color.alphaBlend(base.withValues(alpha: 0.85), Colors.black);

    return switch (this) {
      AgentStatus.blocked => (bg: pair(const Color(0xFFFF5252)), fg: fg(const Color(0xFFFF5252))),
      AgentStatus.working => (bg: pair(const Color(0xFF448AFF)), fg: fg(const Color(0xFF448AFF))),
      AgentStatus.done => (bg: pair(const Color(0xFF69F0AE)), fg: fg(const Color(0xFF00C853))),
      AgentStatus.idle => (bg: scheme.surfaceContainerHighest, fg: scheme.onSurfaceVariant),
      AgentStatus.unknown => (bg: scheme.surfaceContainerHighest, fg: scheme.onSurfaceVariant),
    };
  }
}
