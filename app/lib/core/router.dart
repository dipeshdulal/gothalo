import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/diff/diff_screen.dart';
import '../features/inbox/inbox_screen.dart';
import '../features/overview/overview_screen.dart';
import '../features/pairing/pairing_screen.dart';
import '../features/priority/priority_screen.dart';
import '../features/servers/servers_screen.dart';
import '../features/terminal/terminal_screen.dart';
import '../features/timeline/timeline_screen.dart';
import '../features/transcript/transcript_screen.dart';
import 'adaptive.dart';
import 'shell/desktop_shell.dart';
import 'theme.dart';

/// How long a phone route swap takes.
///
/// Material's own page duration, spelled out here because the route is no
/// longer a [MaterialPage] to inherit it from. The motion is unchanged: the
/// same slide [buildSlidePageTransition] has always drawn, over the same 300ms.
const _kPhonePageTransition = Duration(milliseconds: 300);

/// Builds a route's page, choosing the motion by window size.
///
/// Both sizes get a [CustomTransitionPage]; only the duration and the
/// transition differ — a phone slides the new screen in over 300ms, a desktop
/// fades the detail column over [kDesktopPageTransition]. A desktop needs the
/// custom page because the theme's [PageTransitionsTheme] only picks the
/// visual: the route still animates for its fixed 300ms, which is what made the
/// desktop swap feel slow and ghosty.
///
/// The page **type** is deliberately the same on both sides of the breakpoint.
/// [Page.canUpdate] compares `runtimeType`, so a window dragged across
/// [AppBreakpoints.desktop] with a [MaterialPage] on one side and a
/// [CustomTransitionPage] on the other is not an update — the Navigator
/// disposes the route and builds a new one. The screen's `State` goes with it:
/// an open transcript drops its socket and its scroll position, a terminal
/// loses its buffer, and both then reconnect. Keeping one page type makes a
/// resize what it looks like — the same screen, wider.
@visibleForTesting
Page<void> buildRoutePage(
  BuildContext context,
  GoRouterState state,
  Widget child,
) {
  final desktop = context.isDesktopLayout;
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: desktop
        ? kDesktopPageTransition
        : _kPhonePageTransition,
    reverseTransitionDuration: desktop
        ? kDesktopPageTransition
        : _kPhonePageTransition,
    transitionsBuilder: desktop
        ? _fadeTransition
        : (context, animation, secondaryAnimation, child) =>
              buildSlidePageTransition(animation, child),
  );
}

/// The desktop's page motion: a short fade, no slide.
///
/// The rail and the agent list do not move across a route swap, so a slide
/// would be the wrong story — only the detail column is becoming something
/// else. Short enough that it never reads as two screens at once.
Widget _fadeTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) => FadeTransition(
  opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
  child: child,
);

/// App routes.
///
/// Home is the **agent list**; opening a server activates it and pushes its
/// flock. Adding and editing a server are not routes — they are bottom sheets
/// (`showAddServerSheet` / `showEditServerSheet`), like every other small form
/// in the app. Declarative URLs are also what let an FCM push deep-link straight to a
/// blocked agent's terminal (`/terminal/<pane>`) once push handling lands.
///
/// Every route except pairing sits inside a [ShellRoute]. On a phone that shell
/// is a pass-through (see [DesktopShell]) and the routes behave exactly as they
/// always did; on a desktop-sized window it draws the persistent nav rail and,
/// for a detail route, the agent list beside the screen. Pairing stays outside:
/// it is a full-window camera/onboarding surface, and a rail around it would be
/// chrome around a flow that has nowhere to go yet.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/pair',
        pageBuilder: (context, state) =>
            buildRoutePage(context, state, const PairingScreen()),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            DesktopShell(location: state.uri.toString(), child: child),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) =>
                buildRoutePage(context, state, const ServersScreen()),
          ),
          GoRoute(
            path: '/inbox',
            pageBuilder: (context, state) =>
                buildRoutePage(context, state, const InboxScreen()),
          ),
          GoRoute(
            path: '/priority',
            pageBuilder: (context, state) =>
                buildRoutePage(context, state, const PriorityScreen()),
          ),
          GoRoute(
            path: '/overview',
            pageBuilder: (context, state) =>
                buildRoutePage(context, state, const OverviewScreen()),
          ),
          GoRoute(
            path: '/timeline',
            pageBuilder: (context, state) =>
                buildRoutePage(context, state, const TimelineScreen()),
          ),
          GoRoute(
            path: '/overview/:workspace',
            pageBuilder: (context, state) => buildRoutePage(
              context,
              state,
              OverviewScreen(workspaceId: state.pathParameters['workspace']),
            ),
          ),
          GoRoute(
            path: '/terminal/:pane',
            pageBuilder: (context, state) => buildRoutePage(
              context,
              state,
              TerminalScreen(
                pane: Uri.decodeComponent(state.pathParameters['pane'] ?? ''),
              ),
            ),
          ),
          GoRoute(
            path: '/transcript/:pane',
            pageBuilder: (context, state) => buildRoutePage(
              context,
              state,
              TranscriptScreen(
                pane: Uri.decodeComponent(state.pathParameters['pane'] ?? ''),
                subagent: state.uri.queryParameters['subagent'] ?? '',
                subagentLabel: state.uri.queryParameters['label'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/diff/:pane',
            pageBuilder: (context, state) => buildRoutePage(
              context,
              state,
              DiffScreen(
                pane: Uri.decodeComponent(state.pathParameters['pane'] ?? ''),
              ),
            ),
          ),
        ],
      ),
    ],
  );
});
