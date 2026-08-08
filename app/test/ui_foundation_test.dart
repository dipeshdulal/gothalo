import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/app_background.dart';
import 'package:gothalo/core/glass.dart';
import 'package:gothalo/core/theme.dart';
import 'package:gothalo/core/widgets/app_card.dart';
import 'package:gothalo/core/widgets/entrance.dart';
import 'package:gothalo/core/widgets/glass_app_bar.dart';

/// The shared design layer, exercised without a bridge or a device.
///
/// These are render tests, not golden tests: the point is that the pieces every
/// screen now depends on — a blurred bar the body extends behind, cards inside a
/// list, the entrance animation — actually lay out and paint, rather than
/// throwing at build time or overflowing. A layout error in any of them would
/// otherwise only be discovered on a phone.
void main() {
  Widget host(Widget child, {bool tabs = false}) => MaterialApp(
    theme: AppTheme.dark,
    home: AppBackground(
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: GlassAppBar(
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

  testWidgets('a glass app bar renders and the body extends behind it', (
    tester,
  ) async {
    await tester.pumpWidget(host(const SizedBox.expand()));
    await tester.pumpAndSettle();

    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GlassAppBar.padding accounts for the tab row', (tester) async {
    late double plain;
    late double withTabs;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) {
            plain = GlassAppBar.padding(context);
            withTabs = GlassAppBar.padding(context, tabs: true);
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

  testWidgets('a list of cards lays out under the bar without overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => ListView.builder(
            padding: EdgeInsets.only(
              top: GlassAppBar.padding(context, tabs: true),
            ),
            itemCount: 12,
            itemBuilder: (context, i) => Entrance(
              index: i,
              child: AppCard(
                onTap: () {},
                accent: i == 0 ? Colors.red : null,
                selected: i == 1,
                child: Text('row $i'),
              ),
            ),
          ),
        ),
        tabs: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('row 0'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The first card must clear the header rather than sitting under it.
    final barBottom = tester.getRect(find.byType(GlassAppBar)).bottom;
    expect(tester.getRect(find.text('row 0')).top, greaterThan(barBottom - 1));
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
}
