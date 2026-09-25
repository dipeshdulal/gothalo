import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/bridge/models/snapshot.dart';
import '../../features/agents/agent_groups.dart';
import '../../features/agents/widgets/agent_sections.dart';
import '../../features/inbox/inbox_providers.dart';
import '../../features/recents/recent_providers.dart';
import '../adaptive.dart';
import '../connection/connection.dart';
import '../connection/connection_providers.dart';
import '../theme.dart';
import '../tokens.dart';
import '../widgets/app_mark.dart';

/// Width of the persistent icon rail down the left of the desktop view.
const double kDesktopRailWidth = 76;

/// Width of the agent list the shell puts beside an open transcript/terminal.
const double kDesktopListWidth = 320;

/// The desktop frame: a nav rail, an optional agent list, then the routed
/// screen.
///
/// This is the whole "desktop view". On a phone it returns the routed screen
/// untouched — the phone flow is the one that already worked, and nothing here
/// is allowed to change it. At or above [AppBreakpoints.desktop] the route
/// nests inside [Row] instead:
///
///   [ nav rail | (agent list) | the screen ]
///
/// The rail replaces the phone's habit of walking back out of a screen to reach
/// another; it stays put across every route in its shell. The agent list appears
/// only when a **detail** route is open (`/transcript/:pane`, `/terminal/:pane`,
/// `/diff/:pane`) — that is the master–detail pair: the flock on the left, the
/// agent you picked on the right, both live. On `/inbox` the screen *is* the
/// list, so drawing a second copy beside it would just be the same rows twice.
///
/// It sits inside a `ShellRoute`, not above the `Navigator`, so push/pop still
/// work exactly as they did: opening an agent pushes its route, and the rail and
/// list stay because they belong to the shell rather than to the screen.
class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key, required this.location, required this.child});

  /// The current location, e.g. `/transcript/w1%3Ap2`.
  final String location;

  /// The routed screen.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!context.isDesktopLayout) return child;

    final pane = _paneOf(location);
    return ColoredBox(
      color: AppTheme.scaffoldBase(Theme.of(context).brightness),
      child: Row(
        children: [
          _NavRail(location: location),
          const _ShellHairline(),
          if (pane != null) ...[
            _AgentPanel(activePane: pane),
            const _ShellHairline(),
          ],
          Expanded(child: child),
        ],
      ),
    );
  }

  /// The pane a detail route is about, or null when the route is not one.
  ///
  /// `Uri.parse` rather than string splitting: the pane id is path-encoded
  /// (`w1:p2` carries a colon), and its decoded form is what the rest of the
  /// app compares against.
  static String? _paneOf(String location) {
    final uri = Uri.tryParse(location);
    if (uri == null) return null;
    final segments = uri.pathSegments;
    if (segments.length < 2) return null;
    return switch (segments.first) {
      'transcript' || 'terminal' || 'diff' => segments[1],
      _ => null,
    };
  }
}

/// The hairline between shell columns — the same edge the panels use, drawn
/// full-height because these columns have no panel of their own.
class _ShellHairline extends StatelessWidget {
  const _ShellHairline();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    color: Theme.of(context).colorScheme.hairline,
  );
}

/// One destination in the rail.
class _Destination {
  const _Destination({
    required this.icon,
    required this.label,
    required this.path,
    required this.matches,
  });

  final IconData icon;
  final String label;
  final String path;
  final bool Function(String location) matches;
}

/// The persistent left rail: the app mark, the app's five top-level
/// destinations, and nothing else. Labels are spelled out — a desktop has the
/// width, and an icon-only rail is a memory test.
class _NavRail extends StatelessWidget {
  const _NavRail({required this.location});

  final String location;

  static final _destinations = <_Destination>[
    _Destination(
      icon: Icons.home_outlined,
      label: 'Home',
      path: '/',
      matches: (l) => l == '/',
    ),
    _Destination(
      icon: Icons.dns_outlined,
      label: 'Flock',
      path: '/inbox',
      matches: (l) =>
          l == '/inbox' ||
          l.startsWith('/transcript/') ||
          l.startsWith('/terminal/') ||
          l.startsWith('/diff/'),
    ),
    _Destination(
      icon: Icons.priority_high,
      label: 'Priority',
      path: '/priority',
      matches: (l) => l.startsWith('/priority'),
    ),
    _Destination(
      icon: Icons.grid_view_outlined,
      label: 'Projects',
      path: '/overview',
      matches: (l) => l.startsWith('/overview'),
    ),
    _Destination(
      icon: Icons.history,
      label: 'Activity',
      path: '/timeline',
      matches: (l) => l.startsWith('/timeline'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.panelFill,
      child: SizedBox(
        width: kDesktopRailWidth,
        child: Padding(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + Space.md,
            bottom: Space.md,
          ),
          child: Column(
            children: [
              const AppMark(radius: 15),
              const SizedBox(height: Space.xl),
              for (final destination in _destinations)
                _NavButton(
                  icon: destination.icon,
                  label: destination.label,
                  active: destination.matches(location),
                  onTap: () => GoRouter.of(context).go(destination.path),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One rail destination: icon over a small tracked label, on a panel that
/// lifts when it is the current one.
class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return Tooltip(
      message: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 1),
        child: Material(
          color: active ? scheme.panelFillRaised : Colors.transparent,
          borderRadius: Radii.smAll,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 56,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(height: 4),
                  Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.7,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The active server's flock, as the master half of the desktop
/// master–detail pair.
///
/// It is the same list the Flock screen renders — [groupAgents] and
/// [buildAgentSections], the one implementation of the agent list — scoped to
/// the active server and squeezed into a fixed column. Tapping a row opens that
/// agent's transcript in the detail column; the row for the pane already open
/// is lifted, so the list shows where you are.
class _AgentPanel extends ConsumerWidget {
  const _AgentPanel({required this.activePane});

  final String activePane;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final connection = ref.watch(activeConnectionProvider).asData?.value;
    final snapshot = ref.watch(snapshotControllerProvider);
    final agents = snapshot.asData?.value.agents;

    return Material(
      color: scheme.panelFill,
      child: SizedBox(
        width: kDesktopListWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                Space.lg,
                MediaQuery.paddingOf(context).top + Space.lg,
                Space.lg,
                Space.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      connection?.name ?? 'Agents',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ),
                  if (agents != null)
                    Text(
                      '${agents.length}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ).mono,
                    ),
                ],
              ),
            ),
            const _PanelRule(),
            Expanded(
              child: snapshot.when(
                skipLoadingOnRefresh: true,
                skipLoadingOnReload: true,
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (error, _) => _PanelNotice('$error'),
                data: (snap) => _FlockList(
                  snap: snap,
                  connection: connection,
                  activePane: activePane,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelRule extends StatelessWidget {
  const _PanelRule();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: Theme.of(context).colorScheme.hairline);
}

class _PanelNotice extends StatelessWidget {
  const _PanelNotice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _FlockList extends ConsumerWidget {
  const _FlockList({
    required this.snap,
    required this.connection,
    required this.activePane,
  });

  final Snapshot snap;
  final Connection? connection;
  final String activePane;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (snap.agents.isEmpty) {
      return const _PanelNotice('No agents on this server.');
    }
    // The same (server, agent) pairing home uses, with the active connection
    // standing in for the server — this list is always scoped to one.
    final summary = ServerSummary(
      id: connection?.id ?? '',
      name: connection?.name ?? '',
      baseUrl: connection?.baseUrl ?? '',
      isActive: true,
    );
    final groups = groupAgents([
      for (final agent in snap.agents) ServerAgentHit(summary, agent),
    ]);
    return ListView(
      padding: const EdgeInsets.only(top: Space.sm, bottom: Space.xl),
      children: buildAgentSections(
        context,
        ref,
        groups: groups,
        showServer: false,
        selectedKey: recentKey(summary.id, activePane),
        capSections: false,
        onOpen: (hit) => GoRouter.of(
          context,
        ).push('/transcript/${Uri.encodeComponent(hit.agent.paneId)}'),
      ),
    );
  }
}
