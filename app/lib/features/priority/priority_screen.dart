import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/live_activity_line.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../inbox/widgets/agent_avatar.dart';
import '../../core/widgets/agent_age.dart';
import '../inbox/widgets/status_badge.dart';
import 'priority_providers.dart';

/// A cross-server "priority" view: star the agents you care about and see them
/// pinned here, aggregated from every saved server. Star management lives
/// entirely on this screen, so it stays clear of the actively-edited inbox and
/// terminal screens.
class PriorityScreen extends ConsumerWidget {
  const PriorityScreen({super.key});

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    ServerSummary server,
    Agent agent,
  ) async {
    // Point the app at that agent's server, then open its terminal.
    await ref.read(activeServerIdProvider.notifier).set(server.id);
    if (context.mounted) {
      context.push('/transcript/${Uri.encodeComponent(agent.paneId)}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = watchAllServerAgents(ref);
    final hits = ref.watch(priorityHitsProvider);

    return Scaffold(
      backgroundColor: AppTheme.scaffoldBase(Theme.of(context).brightness),
      appBar: AppBar(title: const Text('Priority')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(serverAgentsProvider),
        // No screen-wide loading state: each server resolves independently, so a
        // reachable one renders straight away instead of waiting behind a
        // sleeping one, and each section shows that server's own reachability.
        // A single spinner over the whole list meant one asleep machine hid
        // every blocked agent on every other machine.
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _SectionHeader(
              icon: Icons.star,
              label: 'Priority${hits.isEmpty ? '' : '  ${hits.length}'}',
            ),
            if (hits.isEmpty)
              const _Hint(
                'Nothing needs you right now. Blocked agents appear here '
                'automatically; star any agent to always pin it.',
              )
            else
              for (final h in hits)
                _AgentRow(
                  server: h.server,
                  agent: h.agent,
                  starred: h.starred,
                  client: h.client,
                  onTap: () => _open(context, ref, h.server, h.agent),
                  onStar: () => ref
                      .read(starredAgentsProvider.notifier)
                      .toggle(h.server.id, h.agent.paneId),
                ),
            const Divider(height: 28),
            // All agents, grouped by server, with star toggles.
            for (final sa in servers) ...[
              _SectionHeader(
                icon: Icons.dns_outlined,
                label: sa.server.name,
                trailing: sa.ok ? null : 'unreachable',
              ),
              if (!sa.ok)
                _Hint('Couldn\'t reach ${sa.server.name}.')
              else if (sa.agents.isEmpty)
                const _Hint('No agents.')
              else
                for (final agent in sa.agents)
                  Consumer(
                    builder: (context, ref, _) {
                      final starred = ref
                          .watch(starredAgentsProvider.notifier)
                          .isStarred(sa.server.id, agent.paneId);
                      return _AgentRow(
                        server: sa.server,
                        agent: agent,
                        starred: starred,
                        client: sa.client,
                        showServer: false,
                        onTap: () => _open(context, ref, sa.server, agent),
                        onStar: () => ref
                            .read(starredAgentsProvider.notifier)
                            .toggle(sa.server.id, agent.paneId),
                      );
                    },
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({
    required this.server,
    required this.agent,
    required this.starred,
    required this.onTap,
    required this.onStar,
    this.client,
    this.showServer = true,
  });

  final ServerSummary server;
  final Agent agent;
  final bool starred;
  final VoidCallback onTap;
  final VoidCallback onStar;

  /// The server's client, for [LiveActivityLine] — null when that server
  /// couldn't be reached (no line to show either way).
  final BridgeClient? client;
  final bool showServer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      leading: AgentAvatar(agent: agent.agent, radius: 18),
      title: Text(
        agent.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            showServer
                ? '${server.name}  ·  ${agent.gitLabel}'
                : agent.gitLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (client != null)
            LiveActivityLine(
              paneId: agent.paneId,
              status: agent.agentStatus,
              client: client,
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The wait itself, next to the state. "Blocked" tells you what;
          // this tells you whether to care.
          AgentAge(
            agent.sinceLastActivity,
            emphasize: agent.agentStatus == AgentStatus.blocked,
          ),
          const SizedBox(width: 8),
          StatusBadge(agent.agentStatus),
          IconButton(
            tooltip: starred ? 'Unstar' : 'Star',
            onPressed: onStar,
            icon: Icon(
              starred ? Icons.star : Icons.star_border,
              color: starred
                  ? const Color(0xFFF5C043)
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.label,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (trailing != null) ...[
            const Spacer(),
            Text(
              trailing!,
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
