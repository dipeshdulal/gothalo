import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
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
              Tab(text: 'Agents${_countSuffix(snapshot, (s) => s.agents.length)}'),
              Tab(text: 'Spaces${_countSuffix(snapshot, (s) => s.byWorkspace.length)}'),
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
              _Refreshable(ref: ref, child: _AgentsTab(snap: snap)),
              _Refreshable(ref: ref, child: _SpacesTab(snap: snap)),
            ],
          ),
        ),
      ),
      ),
    );
  }

  String _countSuffix(
    AsyncValue<Snapshot> snap,
    int Function(Snapshot) count,
  ) {
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
    if (snap.agents.isEmpty) return const _EmptyState();
    final groups = snap.byProject;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: groups.length,
      itemBuilder: (context, i) =>
          _ProjectSection(project: groups[i].key, agents: groups[i].value),
    );
  }
}

class _ProjectSection extends StatelessWidget {
  const _ProjectSection({required this.project, required this.agents});

  final String project;
  final List<Agent> agents;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final attention = agents.where((a) => a.agentStatus.needsAttention).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  project.isEmpty ? 'Ungrouped' : project,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${agents.length}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (attention > 0) ...[
                const Spacer(),
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
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            child: Column(
              children: [
                for (var i = 0; i < agents.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 72),
                  // Project is the header here; the row shows just the branch
                  // for worktrees (nothing extra for the main checkout).
                  _AgentTile(agent: agents[i], showProject: false),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({required this.agent, this.showProject = true});

  final Agent agent;

  /// Show the project folder segment. Off inside a project group (the section
  /// header already names it), on in the flat Agents tab.
  final bool showProject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isWt = agent.isWorktree;
    final dim = scheme.onSurfaceVariant;
    final showFolder = showProject && agent.gitContext.project.isNotEmpty;

    return InkWell(
      onTap: () =>
          context.push('/terminal/${Uri.encodeComponent(agent.paneId)}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
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
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: StatusBadge(agent.agentStatus),
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
          child: Text('No agents right now',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            'Start an agent in Herdr, then pull to refresh.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
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
    final bridgeErr = error is BridgeException ? error as BridgeException : null;
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
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
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
