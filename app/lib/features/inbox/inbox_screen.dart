import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/live_activity_line.dart';
import '../alerts/alerts_providers.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../approvals/approve_action.dart';
import '../jump/jump_sheet.dart';
import 'inbox_providers.dart';
import 'widgets/agent_avatar.dart';
import 'widgets/status_badge.dart';

/// The inbox for the active server, structured like Herdr's sidebar: an
/// **Agents** tab (every agent, attention-first) and a **Spaces** tab (agents
/// grouped by workspace). Pull to refresh on either. Tapping a row opens its
/// (stubbed) terminal.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(snapshotControllerProvider);
    final connection = ref.watch(activeConnectionProvider).asData?.value;

    return AppBackground(
      asset: Backgrounds.flock,
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Servers',
              onPressed: () => context.go('/'),
              icon: const Icon(Icons.dns_outlined),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Flock'),
                if (connection != null)
                  Text(
                    connection.name,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Jump to an agent',
                onPressed: () => showJumpSheet(context),
                icon: const Icon(Icons.bolt),
              ),
              IconButton(
                tooltip: 'Alerts',
                onPressed: () => context.push('/alerts'),
                icon: Badge(
                  isLabelVisible:
                      (ref.watch(unreadAlertsProvider).asData?.value ?? 0) > 0,
                  label: Text(
                    '${ref.watch(unreadAlertsProvider).asData?.value ?? 0}',
                  ),
                  child: const Icon(Icons.notifications_none),
                ),
              ),
              IconButton(
                tooltip: 'Overview',
                onPressed: () => context.push('/overview'),
                icon: const Icon(Icons.dashboard_outlined),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: () =>
                    ref.read(snapshotControllerProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
              ),
              if (connection != null)
                IconButton(
                  tooltip: 'Edit this server',
                  onPressed: () =>
                      context.push('/servers/${connection.id}/edit'),
                  icon: const Icon(Icons.settings_outlined),
                ),
            ],
            bottom: TabBar(
              tabs: [
                Tab(
                  text:
                      'Agents${_countSuffix(snapshot, (s) => s.agents.length)}',
                ),
                Tab(
                  text:
                      'Spaces${_countSuffix(snapshot, (s) => s.workspaces.length)}',
                ),
              ],
            ),
          ),
          body: snapshot.when(
            skipLoadingOnRefresh: true,
            skipLoadingOnReload: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => _ErrorState(error: err),
            data: (snap) => TabBarView(
              children: [
                _Refreshable(
                  ref: ref,
                  child: _AgentsTab(snap: snap),
                ),
                _Refreshable(
                  ref: ref,
                  child: _SpacesTab(snap: snap),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _countSuffix(AsyncValue<Snapshot> snap, int Function(Snapshot) count) {
    final s = snap.asData?.value;
    return s == null ? '' : '  ${count(s)}';
  }
}

class _Refreshable extends StatelessWidget {
  const _Refreshable({required this.ref, required this.child});
  final WidgetRef ref;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => ref.read(snapshotControllerProvider.notifier).refresh(),
      child: child,
    );
  }
}

/// Flat, attention-first list of every agent.
class _AgentsTab extends StatelessWidget {
  const _AgentsTab({required this.snap});
  final Snapshot snap;

  @override
  Widget build(BuildContext context) {
    if (snap.agents.isEmpty) return const _EmptyState();
    final agents = snap.agentsSorted;
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: agents.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) => _AgentTile(agent: agents[i]),
    );
  }
}

/// Agents grouped by project (repo folder), merging a project's main checkout
/// with its worktrees. Herdr's raw `w5`/`w8` workspace ids are demoted to a
/// subtle per-row detail.
class _SpacesTab extends StatelessWidget {
  const _SpacesTab({required this.snap});
  final Snapshot snap;

  @override
  Widget build(BuildContext context) {
    if (snap.workspaces.isEmpty) return const _EmptyState();
    // Representative cwd per workspace (from its first pane) → git context, so
    // worktrees sort right under their parent project.
    final cwdByWs = <String, String>{};
    for (final p in snap.panes) {
      cwdByWs.putIfAbsent(p.workspaceId, () => p.cwd);
    }
    ({String project, String? worktree}) git(WorkspaceInfo w) =>
        gitContextForCwd(cwdByWs[w.workspaceId] ?? '');

    final spaces = [...snap.workspaces]
      ..sort((a, b) {
        final ca = git(a), cb = git(b);
        final p = ca.project.toLowerCase().compareTo(cb.project.toLowerCase());
        if (p != 0) return p;
        final wa = ca.worktree == null ? 0 : 1;
        final wb = cb.worktree == null ? 0 : 1;
        if (wa != wb) return wa - wb; // main checkout before its worktrees
        return a.number.compareTo(b.number);
      });

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: spaces.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) =>
          _SpaceTile(space: spaces[i], git: git(spaces[i])),
    );
  }
}

/// One space (workspace). Worktree spaces are marked with a branch icon and
/// indented under their parent project. Tapping opens the space's overview.
class _SpaceTile extends StatelessWidget {
  const _SpaceTile({required this.space, required this.git});
  final WorkspaceInfo space;
  final ({String project, String? worktree}) git;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isWt = git.worktree != null;
    final label = isWt
        ? git.worktree!
        : (space.label.isNotEmpty
              ? space.label
              : (space.workspaceId.isEmpty ? 'Ungrouped' : space.workspaceId));
    final blocked = space.agentStatus == AgentStatus.blocked;
    return ListTile(
      onTap: () =>
          context.push('/overview/${Uri.encodeComponent(space.workspaceId)}'),
      contentPadding: EdgeInsets.only(left: isWt ? 32 : 16, right: 16),
      leading: CircleAvatar(
        backgroundColor: space.focused
            ? scheme.primary
            : scheme.surfaceContainerHighest,
        child: Icon(
          isWt ? Icons.call_split : Icons.workspaces_outline,
          color: space.focused
              ? scheme.onPrimary
              : (isWt ? scheme.primary : scheme.onSurfaceVariant),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontFamily: isWt ? AppTheme.monoFamily : null,
                color: isWt ? scheme.primary : null,
              ),
            ),
          ),
          if (blocked) ...[
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: scheme.error,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        '${space.paneCount} pane${space.paneCount == 1 ? '' : 's'}  ·  ${space.tabCount} tab${space.tabCount == 1 ? '' : 's'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _AgentTile extends ConsumerWidget {
  const _AgentTile({required this.agent});

  final Agent agent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isWt = agent.isWorktree;
    final dim = scheme.onSurfaceVariant;
    final showFolder = agent.gitContext.project.isNotEmpty;

    return InkWell(
      onTap: () =>
          context.push('/transcript/${Uri.encodeComponent(agent.paneId)}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AgentAvatar(agent: agent.agent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The task itself — the star of the row. Up to two lines so
                      // long Herdr titles stay readable instead of hard-truncating.
                      Text(
                        agent.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          height: 1.25,
                        ),
                      ),
                      // Project folder + branch/worktree (teal) each on their own
                      // full-width line so long names ellipsize instead of
                      // overflowing. Internal ids (pane, workspace) are not shown —
                      // the pane id is still used under the hood for navigation.
                      if (showFolder) ...[
                        const SizedBox(height: 6),
                        _GitLine(
                          icon: Icons.folder_outlined,
                          text: agent.gitContext.project,
                          color: dim,
                        ),
                      ],
                      if (isWt) ...[
                        SizedBox(height: showFolder ? 3 : 6),
                        _GitLine(
                          icon: Icons.call_split,
                          text: agent.gitContext.worktree ?? '',
                          color: scheme.primary,
                          bold: true,
                        ),
                      ],
                      // Which Herdr session hosts this agent; the default session
                      // is implied and not shown.
                      if (!agent.isDefaultSession) ...[
                        SizedBox(height: (showFolder || isWt) ? 3 : 6),
                        _GitLine(
                          icon: Icons.layers_outlined,
                          text: agent.sessionName,
                          color: dim,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const SizedBox(height: 2),
                    StatusBadge(agent.agentStatus),
                    // One-tap approve for a blocked agent (D7/D8). The bridge picks
                    // the confirm keystroke and no-ops a stale tap.
                    if (agent.agentStatus == AgentStatus.blocked) ...[
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => approveAgent(context, ref, agent),
                        child: const Text('Approve'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            // "What's it doing right now" — only for a working agent; an
            // idle/blocked/done one has nothing that changes to poll for.
            // On its own row below the title/status Row (not squeezed beside
            // the status badge, which can be wide enough to truncate it to
            // nothing), but indented to line up under the title text rather
            // than running back under the avatar — the avatar column is the
            // row's visual gutter, so this reads as "part of this agent" only
            // when it aligns with the agent's text, not the artwork.
            // No extra top gap here — LiveActivityLine carries its own small
            // top padding, so a SizedBox on top of that just double-spaced it.
            if (agent.agentStatus == AgentStatus.working)
              Padding(
                // avatar diameter (radius 20 * 2) + the 12px gap to the title.
                padding: const EdgeInsets.only(left: 52),
                child: LiveActivityLine(paneId: agent.paneId),
              ),
          ],
        ),
      ),
    );
  }
}

/// A full-width monospace metadata line (leading icon + text), used for the
/// project folder and branch on an agent row. The text takes the remaining
/// width and ellipsizes, so a long branch name never overflows the row.
class _GitLine extends StatelessWidget {
  const _GitLine({
    required this.icon,
    required this.text,
    required this.color,
    this.bold = false,
  });

  final IconData icon;
  final String text;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontFamily: AppTheme.monoFamily,
              fontSize: 12,
              fontWeight: bold ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.28),
        Icon(Icons.inbox_outlined, size: 56, color: scheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'No agents right now',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            'Start an agent in Herdr, then pull to refresh.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends ConsumerWidget {
  const _ErrorState({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bridgeErr = error is BridgeException
        ? error as BridgeException
        : null;
    final isDown = bridgeErr?.isBridgeDown ?? false;
    final isAuth = bridgeErr?.isAuth ?? false;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        Icon(
          isDown ? Icons.cloud_off_outlined : Icons.error_outline,
          size: 56,
          color: scheme.error,
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            isDown
                ? 'Bridge unreachable'
                : isAuth
                ? 'Not authorized'
                : 'Couldn\'t load the flock',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            bridgeErr?.message ?? error.toString(),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () =>
                    ref.read(snapshotControllerProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              OutlinedButton.icon(
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.dns_outlined),
                label: const Text('Servers'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
