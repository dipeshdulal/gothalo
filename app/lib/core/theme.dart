import 'package:flutter/material.dart';

import '../data/bridge/models/snapshot.dart';
import 'tokens.dart';

/// gothalo's themes. Dark-first (a terminal remote lives in the dark), but a
/// light theme is provided too and [ThemeMode.system] lets the OS decide.
/// Seeded from a single teal so both modes stay in family.
///
/// The language is terminal-native: flat opaque surfaces held by hairlines,
/// tight corners, dense type. Colour is one accent (the seed teal) plus status
/// colours reserved for status dots. The bundled typefaces (Inter for prose,
/// JetBrains Mono for identifiers) are declared here and applied to every
/// style — the earlier build hardcoded Roboto via `Typography.material2021()`
/// and quietly overrode the family the pubspec already shipped.
class AppTheme {
  AppTheme._();

  static const _seed = Color(0xFF00BFA5); // Herdr-ish teal

  /// UI typeface (bundled Inter).
  static const fontFamily = 'Inter';

  /// Monospace family (bundled JetBrains Mono) — pane ids, code, the terminal.
  static const monoFamily = 'JetBrains Mono';

  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  /// The one flat colour every screen sits on. Kept a hair apart from
  /// [AppSurfaces.panelFill] so a panel's fill is distinguishable from the
  /// page itself, and dark enough (light enough) that hairlines read in both
  /// modes.
  static Color scaffoldBase(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF0A0E0F)
      : const Color(0xFFECEEED);

  /// The type scale.
  ///
  /// Two rules, applied everywhere: display and title sizes get **negative**
  /// tracking (large text set at default tracking reads loose and webby), and
  /// body/label sizes get slightly positive tracking so small UI text stays
  /// legible on dense rows. Weight tops out at w600 — the bundled faces stop
  /// there, and the app has plenty of other ways to say "important".
  static TextTheme _typography(TextTheme base) => base
      .copyWith(
        headlineSmall: base.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.5,
        ),
        titleLarge: base.titleLarge?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        titleMedium: base.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleSmall: base.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
          letterSpacing: -0.1,
        ),
        bodyMedium: base.bodyMedium?.copyWith(height: 1.3),
        bodySmall: base.bodySmall?.copyWith(height: 1.3, letterSpacing: 0.1),
        labelLarge: base.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
        ),
        labelSmall: base.labelSmall?.copyWith(letterSpacing: 0.4),
      )
      // The pubspec has shipped Inter since the scaffold; the theme was the
      // thing not using it. Applied LAST, after every copyWith override: a
      // TextStyle.merge replaces fontFamily wholesale, so a family stamped on
      // the base is lost the moment any style is overridden from it. Stamping
      // the finished theme is what actually keeps Roboto out.
      .apply(fontFamily: fontFamily);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    // **The tokens' hairline, not a second copy of it.** This used to compute
    // its own at 8% — which is what the token was before the contrast pass
    // raised it — so every surface the *theme* draws (cards, chips, dividers,
    // fields) kept the faint edge while `PanelRow` and friends moved to the
    // legible one. Two definitions of one line is how a design language drifts
    // from itself in a single file.
    final hairline = scheme.hairline;

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
      // own flat backdrop through the Scaffold. Utility screens that aren't
      // wrapped set an opaque [AppTheme.scaffoldBase] on their Scaffold so they
      // still slide as a solid layer.
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        // Set HERE, not per screen. Three screens had already picked 12 while
        // the rest kept Material's 16, so headers drifted apart before anyone
        // looked; a per-screen override is how that happens. Flutter has no
        // themeable leadingWidth, which is exactly why nothing should override
        // it locally either.
        titleSpacing: 12,
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      // Raw Card chrome, for the stray Card that still slips into a sheet.
      // Everything deliberate lives in [PanelRow]. Flat, opaque, hairline,
      // tight — the same rules the deliberate surfaces follow.
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        color: scheme.panelFill,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.mdAll,
          side: BorderSide(color: hairline, width: 1),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      ),
      // Chips are Material's most visible tell and the two restyled screens
      // don't use them at all — this keeps the shape language for the screens
      // that still do: tight corner, flat fill, hairline edge.
      chipTheme: ChipThemeData(
        backgroundColor: scheme.panelFill,
        side: BorderSide(color: hairline),
        shape: RoundedRectangleBorder(borderRadius: Radii.xsAll),
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        showCheckmark: false,
      ),
      dividerTheme: DividerThemeData(color: hairline, space: 1, thickness: 1),
      // **The app's one text-field treatment**, in the theme rather than as a
      // widget, so every `TextField` and `TextFormField` gets it without being
      // told: a flat panel fill inside a hairline at the panel radius, the
      // accent showing only on focus, and a muted hint.
      //
      // It is the Jump search field's look, which was the odd one out and
      // turned out to be the good one. The previous theme differed from it in
      // three ways — a sunken `wellFill`, the tighter `sm` radius, and a 1.2px
      // focus ring — each of which made a field read as a hole in the page
      // rather than as a panel you can type in. Fields that need more (the
      // composer's inline controls, a mono value for an identifier) take it as
      // a parameter; none of them redeclare the border.
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: scheme.panelFill,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
        border: OutlineInputBorder(
          borderRadius: Radii.mdAll,
          borderSide: BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Radii.mdAll,
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Radii.mdAll,
          borderSide: BorderSide(color: scheme.primary),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: Radii.mdAll,
          borderSide: BorderSide(color: hairline),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: Radii.mdAll,
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: Radii.mdAll,
          borderSide: BorderSide(color: scheme.error),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      // A label-width underline instead of a full-width bar, and no divider
      // beneath the tab row — the flat header already ends in a hairline, and
      // two lines a pixel apart look like a rendering bug.
      tabBarTheme: TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
        unselectedLabelStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      // Sheets and dialogs share the panels' flat, hairline-edged language.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.panelFill,
        surfaceTintColor: Colors.transparent,
        showDragHandle: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.md)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.panelFill,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.mdAll,
          side: BorderSide(color: hairline, width: 1),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.panelFill,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.smAll,
          side: BorderSide(color: hairline, width: 1),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        shape: RoundedRectangleBorder(borderRadius: Radii.smAll),
      ),
      // Flat, tight-cornered buttons; the stadium is a Material tell.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: Radii.smAll),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: Radii.smAll),
          side: BorderSide(color: scheme.hairlineStrong),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: Radii.smAll),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.mdAll,
          side: BorderSide(color: hairline, width: 1),
        ),
      ),
      textTheme: _typography(
        dark
            ? Typography.material2021().white
            : Typography.material2021().black,
      ),
    );
  }
}

/// Terminal-native rule: identifiers (branch names, pane ids, paths, ports,
/// SHAs, commands) are set in the mono face; prose stays proportional. Apply
/// this to any [TextStyle] that will carry an identifier.
extension IdentifierText on TextStyle {
  TextStyle get mono => copyWith(fontFamily: AppTheme.monoFamily);
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

  /// The dot colour for this status — vivid where the status means something,
  /// muted where it doesn't. In this language the dot is the whole badge, so
  /// it does not share the pill's translucent background.
  Color dot(ColorScheme scheme) => colors(scheme).fg;

  /// Background/foreground for the small flat chips the tallies use, tuned per
  /// brightness.
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
