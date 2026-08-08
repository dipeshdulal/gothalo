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

  testWidgets('the app bar is frosted, and it is the only thing that blurs', (
    tester,
  ) async {
    await tester.pumpWidget(host(const SizedBox.expand()));
    await tester.pumpAndSettle();

    expect(find.byType(FlatAppBar), findsOneWidget);
    // Exactly one blur in the whole tree, and it is inside the bar. The bar has
    // moving content behind it by construction (the body extends underneath),
    // and fully transparent read as broken on a phone — rows showing through
    // the title. Everywhere else stays flat and opaque: this is a narrow
    // reintroduction for one surface, not a return to glass.
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(FlatAppBar),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bar scrims hard enough to read over any row', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        host(const SizedBox.expand(), brightness: brightness),
      );
      await tester.pumpAndSettle();

      final deco = tester
          .widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byType(BackdropFilter),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .decoration as BoxDecoration;
      // Blur alone leaves a red needs-you row as a red smear under the title.
      // The scrim is what pulls any row back to a tint, so it is the number
      // worth pinning — and it must not reach 1.0 either, or the bar is just
      // opaque chrome and the blur is dead weight.
      expect(deco.color!.a, greaterThan(0.8), reason: '$brightness');
      expect(deco.color!.a, lessThan(1.0), reason: '$brightness');
      // The hairline survived the change.
      expect((deco.border as Border).bottom.width, 1);
    }
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

  /// WCAG contrast ratio between two opaque colours.
  double contrast(Color a, Color b) {
    final la = luminance(a), lb = luminance(b);
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  testWidgets('a panel is separable from the page, in both themes', (
    tester,
  ) async {
    // The failure this exists for: the first pass put the panel 1.07 off the
    // page with a 1.23 edge, and six rows read as one undifferentiated mass on
    // a real phone. When you drop elevation and tinted fills, these two numbers
    // are the *only* things holding a row apart from its neighbour, so both are
    // pinned rather than left to taste.
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      final scheme = theme.colorScheme;
      final page = AppTheme.scaffoldBase(scheme.brightness);
      final fill = scheme.panelFill;
      final label = '${scheme.brightness}';

      expect(fill.a, 1.0, reason: label); // flat and opaque
      expect(contrast(fill, page), greaterThan(1.09), reason: label);

      final edge = Color.alphaBlend(scheme.hairline, fill);
      expect(contrast(edge, fill), greaterThan(1.35), reason: label);
      // And not a wireframe: past roughly 2.5 on a light surface every box
      // reads as outlined and nothing is quiet.
      expect(contrast(edge, fill), lessThan(2.5), reason: label);

      // A selected row and an inset well both have to be tellable from the
      // resting panel, or "focused" and "this is a code line" say nothing.
      expect(contrast(scheme.panelFillRaised, fill), greaterThan(1.02),
          reason: label);
      expect(contrast(scheme.wellFill, fill), greaterThan(1.05), reason: label);
      // The strong edge is strictly stronger than the resting one.
      final strong = Color.alphaBlend(scheme.hairlineStrong, fill);
      expect(contrast(strong, fill), greaterThan(contrast(edge, fill)),
          reason: label);
    }
  });

  testWidgets('a panel hairline renders as a 1px border, not a shadow', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        host(const PanelRow(child: Text('row')), brightness: brightness),
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
      expect((deco.border as Border).top.width, 1);
      expect(deco.boxShadow, isNull);
      expect(deco.color!.a, 1.0);
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
    // No blur *in the list*. The bar above it is allowed one; a row is not.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
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
