import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import 'inbox_providers.dart';
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

    return DefaultTabController(
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
              const Text('Inbox'),
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
      itemBuilder: (context, i) => _AgentTile(agent: agents[i], showWorkspace: true),
    );
  }
}

/// Agents grouped by workspace (space).
class _SpacesTab extends StatelessWidget {
  const _SpacesTab({required this.snap});
  final Snapshot snap;

  @override
  Widget build(BuildContext context) {
    if (snap.agents.isEmpty) return const _EmptyState();
    final groups = snap.byWorkspace;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: groups.length,
      itemBuilder: (context, i) =>
          _WorkspaceSection(workspaceId: groups[i].key, agents: groups[i].value),
    );
  }
}

class _WorkspaceSection extends StatelessWidget {
  const _WorkspaceSection({required this.workspaceId, required this.agents});

  final String workspaceId;
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
              Icon(Icons.workspaces_outline, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                workspaceId.isEmpty ? 'Ungrouped' : workspaceId,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
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
                  _AgentTile(agent: agents[i]),
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
  const _AgentTile({required this.agent, this.showWorkspace = false});

  final Agent agent;
  final bool showWorkspace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isWt = agent.isWorktree;
    final gitAccent = isWt ? scheme.primary : scheme.onSurfaceVariant;
    final dim = scheme.onSurfaceVariant;

    return InkWell(
      onTap: () =>
          context.push('/terminal/${Uri.encodeComponent(agent.paneId)}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: scheme.surfaceContainerHighest,
              child: Text(
                agent.agent.isEmpty ? '?' : agent.agent[0].toUpperCase(),
                style: TextStyle(
                  color: dim,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
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
                  const SizedBox(height: 6),
                  // One compact secondary line: git ref + pane id (+ space on
                  // the flat Agents tab).
                  Row(
                    children: [
                      Icon(
                        isWt ? Icons.call_split : Icons.folder_outlined,
                        size: 13,
                        color: gitAccent,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          agent.gitLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: gitAccent,
                            fontFamily: AppTheme.monoFamily,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Text('  ·  ', style: TextStyle(color: dim, fontSize: 11)),
                      Text(
                        agent.paneId,
                        style: TextStyle(
                          color: dim,
                          fontFamily: AppTheme.monoFamily,
                          fontSize: 11.5,
                        ),
                      ),
                      if (showWorkspace) ...[
                        Text('  ·  ', style: TextStyle(color: dim, fontSize: 11)),
                        Text(
                          agent.workspaceId,
                          style: TextStyle(color: dim, fontSize: 11.5),
                        ),
                      ],
                    ],
                  ),
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
                    : 'Couldn\'t load the inbox',
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
