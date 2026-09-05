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

/// App routes.
///
/// Home is the **agent list**; opening a server activates it and pushes its
/// flock. Adding and editing a server are not routes — they are bottom sheets
/// (`showAddServerSheet` / `showEditServerSheet`), like every other small form
/// in the app. Declarative URLs are also what let an FCM push deep-link straight to a
/// blocked agent's terminal (`/terminal/<pane>`) once push handling lands.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const ServersScreen()),
      GoRoute(
        path: '/pair',
        builder: (context, state) => const PairingScreen(),
      ),
      GoRoute(path: '/inbox', builder: (context, state) => const InboxScreen()),
      GoRoute(
        path: '/priority',
        builder: (context, state) => const PriorityScreen(),
      ),
      GoRoute(
        path: '/overview',
        builder: (context, state) => const OverviewScreen(),
      ),
      GoRoute(
        path: '/timeline',
        builder: (context, state) => const TimelineScreen(),
      ),
      GoRoute(
        path: '/overview/:workspace',
        builder: (context, state) =>
            OverviewScreen(workspaceId: state.pathParameters['workspace']),
      ),
      GoRoute(
        path: '/terminal/:pane',
        builder: (context, state) => TerminalScreen(
          pane: Uri.decodeComponent(state.pathParameters['pane'] ?? ''),
        ),
      ),
      GoRoute(
        path: '/transcript/:pane',
        builder: (context, state) => TranscriptScreen(
          pane: Uri.decodeComponent(state.pathParameters['pane'] ?? ''),
          openPrompt: state.uri.queryParameters['prompt'] == '1',
          subagent: state.uri.queryParameters['subagent'] ?? '',
          subagentLabel: state.uri.queryParameters['label'] ?? '',
        ),
      ),
      GoRoute(
        path: '/diff/:pane',
        builder: (context, state) => DiffScreen(
          pane: Uri.decodeComponent(state.pathParameters['pane'] ?? ''),
        ),
      ),
    ],
  );
});
