import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gothalo/core/adaptive.dart';
import 'package:gothalo/core/router.dart';
import 'package:gothalo/core/theme.dart';

/// Counts how many times a routed screen has been built from scratch.
///
/// `initState` runs once per `State`, so a second count means the Navigator
/// threw the route away and made a new one — which is exactly what losing a
/// transcript's socket and scroll position looks like from the outside.
int screenInits = 0;

class _Screen extends StatefulWidget {
  const _Screen();

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  @override
  void initState() {
    super.initState();
    screenInits++;
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('screen')));
}

Future<void> _pumpRoute(WidgetTester tester, {required Size size}) async {
  screenInits = 0;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) =>
            buildRoutePage(context, state, const _Screen()),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a window dragged past the breakpoint keeps the same screen', (
    tester,
  ) async {
    await _pumpRoute(tester, size: const Size(1200, 800));
    expect(screenInits, 1);

    // Desktop -> phone, the drag that used to swap MaterialPage for
    // CustomTransitionPage and take the open screen down with it.
    tester.view.physicalSize = const Size(600, 800);
    await tester.pumpAndSettle();
    expect(
      screenInits,
      1,
      reason: 'narrowing past the breakpoint must not rebuild the screen',
    );

    // And back out again.
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(
      screenInits,
      1,
      reason: 'widening past the breakpoint must not rebuild the screen',
    );
  });

  testWidgets('both sizes route through one page type', (tester) async {
    await _pumpRoute(tester, size: const Size(1200, 800));
    final desktopPage = tester
        .widget<Navigator>(find.byType(Navigator).last)
        .pages
        .last;

    await _pumpRoute(tester, size: const Size(600, 800));
    final phonePage = tester
        .widget<Navigator>(find.byType(Navigator).last)
        .pages
        .last;

    // Page.canUpdate compares runtimeType, so this is the property that keeps
    // a resize an update rather than a teardown.
    expect(phonePage.runtimeType, desktopPage.runtimeType);
    expect(desktopPage, isA<CustomTransitionPage<void>>());
  });

  testWidgets('the phone keeps its 300ms slide, the desktop gets a fast fade', (
    tester,
  ) async {
    await _pumpRoute(tester, size: const Size(600, 800));
    final phone =
        tester.widget<Navigator>(find.byType(Navigator).last).pages.last
            as CustomTransitionPage<void>;
    expect(phone.transitionDuration, const Duration(milliseconds: 300));

    await _pumpRoute(tester, size: const Size(1200, 800));
    final desktop =
        tester.widget<Navigator>(find.byType(Navigator).last).pages.last
            as CustomTransitionPage<void>;
    expect(desktop.transitionDuration, kDesktopPageTransition);
  });
}
