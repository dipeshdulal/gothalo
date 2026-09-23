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

/// Builds a route's page, choosing the motion by window size.
///
/// A phone keeps the plain [MaterialPage] and its 300ms slide. A desktop gets a
/// [CustomTransitionPage] so the **duration** can be set at all — the theme's
/// [PageTransitionsTheme] only picks the visual, the route still animates for
/// its fixed 300ms, which is what made the desktop swap feel slow and ghosty.
/// The visual is a short fade over [kDesktopPageTransition]: no slide (the rail
/// and the list do not move) and no cross-dissolve long enough to read as two
/// screens at once.
Page<void> _page(BuildContext context, GoRouterState state, Widget child) {
  if (!context.isDesktopLayout) {
    return MaterialPage<void>(key: state.pageKey, child: child);
  }
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: kDesktopPageTransition,
    reverseTransitionDuration: kDesktopPageTransition,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(
          opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
          child: child,
        ),
  );
}

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
            _page(context, state, const PairingScreen()),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            DesktopShell(location: state.uri.toString(), child: child),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) =>
                _page(context, state, const ServersScreen()),
          ),
          GoRoute(
            path: '/inbox',
            pageBuilder: (context, state) =>
                _page(context, state, const InboxScreen()),
          ),
          GoRoute(
            path: '/priority',
            pageBuilder: (context, state) =>
                _page(context, state, const PriorityScreen()),
          ),
          GoRoute(
            path: '/overview',
            pageBuilder: (context, state) =>
                _page(context, state, const OverviewScreen()),
          ),
          GoRoute(
            path: '/timeline',
            pageBuilder: (context, state) =>
                _page(context, state, const TimelineScreen()),
          ),
          GoRoute(
            path: '/overview/:workspace',
            pageBuilder: (context, state) => _page(
              context,
              state,
              OverviewScreen(workspaceId: state.pathParameters['workspace']),
            ),
          ),
          GoRoute(
            path: '/terminal/:pane',
            pageBuilder: (context, state) => _page(
              context,
              state,
              TerminalScreen(
                pane: Uri.decodeComponent(state.pathParameters['pane'] ?? ''),
              ),
            ),
          ),
          GoRoute(
            path: '/transcript/:pane',
            pageBuilder: (context, state) => _page(
              context,
              state,
              TranscriptScreen(
                pane: Uri.decodeComponent(state.pathParameters['pane'] ?? ''),
                openPrompt: state.uri.queryParameters['prompt'] == '1',
                subagent: state.uri.queryParameters['subagent'] ?? '',
                subagentLabel: state.uri.queryParameters['label'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/diff/:pane',
            pageBuilder: (context, state) => _page(
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
