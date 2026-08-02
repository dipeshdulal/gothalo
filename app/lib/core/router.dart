import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/alerts/alerts_screen.dart';
import '../features/inbox/inbox_screen.dart';
import '../features/overview/overview_screen.dart';
import '../features/pairing/pairing_screen.dart';
import '../features/priority/priority_screen.dart';
import '../features/servers/add_edit_server_screen.dart';
import '../features/servers/servers_screen.dart';
import '../features/terminal/terminal_screen.dart';

/// App routes.
///
/// Home is the **servers list**; opening a server activates it and pushes the
/// inbox. Declarative URLs are also what let an FCM push deep-link straight to a
/// blocked agent's terminal (`/terminal/<pane>`) once push handling lands.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const ServersScreen(),
      ),
      GoRoute(
        path: '/servers/add',
        builder: (context, state) => const AddEditServerScreen(),
      ),
      GoRoute(
        path: '/pair',
        builder: (context, state) => const PairingScreen(),
      ),
      GoRoute(
        path: '/servers/:id/edit',
        builder: (context, state) =>
            AddEditServerScreen(serverId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/inbox',
        builder: (context, state) => const InboxScreen(),
      ),
      GoRoute(
        path: '/alerts',
        builder: (context, state) => const AlertsScreen(),
      ),
      GoRoute(
        path: '/priority',
        builder: (context, state) => const PriorityScreen(),
      ),
      GoRoute(
        path: '/overview',
        builder: (context, state) => const OverviewScreen(),
      ),
      GoRoute(
        path: '/overview/:workspace',
        builder: (context, state) => OverviewScreen(
          workspaceId: state.pathParameters['workspace'],
        ),
      ),
      GoRoute(
        path: '/terminal/:pane',
        builder: (context, state) => TerminalScreen(
          pane: Uri.decodeComponent(state.pathParameters['pane'] ?? ''),
        ),
      ),
    ],
  );
});
