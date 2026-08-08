import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/app_background.dart';
import 'package:gothalo/core/theme.dart';
import 'package:gothalo/core/tokens.dart';
import 'package:gothalo/core/widgets/entrance.dart';
import 'package:gothalo/core/widgets/flat_app_bar.dart';
import 'package:gothalo/core/widgets/panel_row.dart';
import 'package:gothalo/core/widgets/status_mark.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/inbox/widgets/status_badge.dart';

/// The shared design layer, exercised without a bridge or a device.
///
/// The language is terminal-native: flat opaque surfaces held by 1px hairlines,
/// one mono face for identifiers, and no Material chrome — no Card, no
/// FilterChip, no blur. These are render tests, not golden tests: the point is
/// that the pieces every screen depends on lay out and paint, in BOTH themes,
/// and that the hairline actually reads against its surface in each.
void main() {
  Widget host(Widget child, {bool tabs = false, Brightness brightness = Brightness.dark}) =>
      MaterialApp(
        theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
        home: AppBackground(
          child: DefaultTabController(
            length: 2,
            child: Scaffold(
              extendBodyBehindAppBar: true,
              appBar: FlatAppBar(
                title: const Text('Title'),
                bottom: tabs
                    ? const TabBar(tabs: [Tab(text: 'A'), Tab(text: 'B')])
                    : null,
              ),
              body: child,
            ),
          ),
        ),
      );

  /// WCAG-style relative luminance, for pinning the hairline's visibility
  /// without a golden image.
  double luminance(Color c) {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  testWidgets('a flat app bar renders and the body extends behind it', (
    tester,
  ) async {
    await tester.pumpWidget(host(const SizedBox.expand()));
    await tester.pumpAndSettle();

    expect(find.byType(FlatAppBar), findsOneWidget);
    // The glass era is over: no blur, no translucent material anywhere.
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FlatAppBar.padding accounts for the tab row', (tester) async {
    late double plain;
    late double withTabs;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) {
            plain = FlatAppBar.padding(context);
            withTabs = FlatAppBar.padding(context, tabs: true);
            return const SizedBox.expand();
          },
        ),
      ),
    );

    expect(plain, greaterThanOrEqualTo(kToolbarHeight));
    // A bar with tabs is taller by exactly the tab row — this is the number
    // every list uses as its top padding, so an error here hides a row of
    // content under the header on every screen at once.
    expect(withTabs - plain, kTextTabBarHeight);
  });

  testWidgets('the theme applies the bundled typefaces, not Roboto', (
    tester,
  ) async {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      // The pubspec has shipped Inter since the scaffold; this is the pin that
      // stops the theme silently falling back to the M3 default family.
      expect(theme.textTheme.bodyMedium?.fontFamily, AppTheme.fontFamily);
      expect(theme.textTheme.bodyMedium?.fontFamily, isNot('Roboto'));
      expect(theme.textTheme.labelLarge?.fontFamily, AppTheme.fontFamily);

      // The identifier rule, at the style level: `.mono` stamps the mono face.
      const prose = TextStyle(fontSize: 12);
      expect(prose.mono.fontFamily, AppTheme.monoFamily);
    }
  });

  testWidgets('a panel hairline is visible against its surface in both themes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        host(
          const PanelRow(child: Text('row')),
          brightness: brightness,
        ),
      );

      final deco = tester
          .widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byType(PanelRow),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .decoration as BoxDecoration;
      final border = deco.border as Border;
      // A hairline: exactly 1px, not a shadow, not a 2px outline.
      expect(border.top.width, 1);
      expect(deco.boxShadow, isNull);

      final fill = deco.color!;
      // Flat and opaque — the anti-glass rule.
      expect(fill.a, 1.0);
      // Visible but subtle: composite the hairline over its surface and check
      // the edge reads against it in both themes — or the language collapses
      // in light mode.
      final edge = Color.alphaBlend(border.top.color, fill);
      final contrast = (luminance(edge) - luminance(fill)).abs();
      expect(contrast, greaterThan(0.005), reason: 'dark: $brightness');
      expect(contrast, lessThan(0.5));
    }
  });

  testWidgets('status is a dot in mono, prose stays proportional', (
    tester,
  ) async {
    await tester.pumpWidget(host(const StatusMark(AgentStatus.working)));

    expect(find.byType(StatusMark), findsOneWidget);
    final label = tester.widget<Text>(find.text('WORKING'));
    expect(label.style?.fontFamily, AppTheme.monoFamily);
  });

  testWidgets('a list of rows renders no Material chrome', (tester) async {
    await tester.pumpWidget(
      host(
        ListView(
          children: const [
            PanelRow(
              child: StatusMark(AgentStatus.working),
            ),
            PanelRow(
              child: StatusMark(AgentStatus.blocked),
            ),
            PanelRow(
              selected: true,
              child: Text('focused'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PanelRow), findsNWidgets(3));
    expect(find.byType(Card), findsNothing);
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.byType(Chip), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the status badge is a tight pill, not a stadium', (tester) async {
    await tester.pumpWidget(host(const StatusBadge(AgentStatus.working)));

    final deco = tester
        .widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(StatusBadge),
                matching: find.byType(DecoratedBox),
              )
              .first,
        )
        .decoration as BoxDecoration;
    final radius = (deco.borderRadius as BorderRadius).topLeft.x;
    // Radius language: nothing past 8. A 999 corner is the Material tell this
    // design removes from status too.
    expect(radius, lessThanOrEqualTo(Radii.md));
    expect(deco.boxShadow, isNull);
  });

  testWidgets('an entering row ends fully opaque and in place', (tester) async {
    await tester.pumpWidget(
      host(const Entrance(index: 3, child: Text('settled'))),
    );
    await tester.pumpAndSettle();

    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('settled'), matching: find.byType(Opacity)),
    );
    expect(opacity.opacity, 1.0);
  });

  testWidgets('tokens are the tight, dense terminal numbers', (tester) async {
    // Radius language: 4/6/8, nothing bigger. Spacing: gutters and gaps that
    // fit more rows per screen.
    expect(Radii.md, lessThanOrEqualTo(8));
    expect(Radii.sm, lessThan(Radii.md));
    expect(Radii.xs, lessThan(Radii.sm));
    expect(Space.gutter, lessThanOrEqualTo(12));
    expect(Space.xl, lessThanOrEqualTo(16));
  });
}
