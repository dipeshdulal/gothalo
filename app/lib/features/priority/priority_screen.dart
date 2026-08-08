import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/agent_age.dart';
import '../../core/widgets/flat_app_bar.dart';
import '../../core/widgets/live_activity_line.dart';
import '../../core/widgets/panel_row.dart';
import '../../core/widgets/status_mark.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../inbox/widgets/agent_avatar.dart';
import 'priority_providers.dart';
import 'widgets/priority_overflow_bar.dart';

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
    final scheme = Theme.of(context).colorScheme;
    final servers = watchAllServerAgents(ref);
    final hits = ref.watch(priorityHitsProvider);
    // Same cap, same remembered state as the home surface — this is the same
    // list rendered twice, and it would read as a bug if one of them were open
    // and the other shut. Nothing becomes unreachable here either way: every
    // agent, starred or not, is also listed under its server below.
    final overflow = PriorityOverflow.of(
      hits,
      expanded: ref.watch(priorityExpandedProvider),
    );

    return AppBackground(
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: FlatAppBar(title: const Text('Priority')),
        // Builder: `FlatAppBar.padding` reads the MediaQuery that
        // `extendBodyBehindAppBar` rewrites, so it has to be asked from inside
        // the body. See `FlatAppBar.padding`.
        body: Builder(
          builder: (context) => RefreshIndicator(
            onRefresh: () async => ref.invalidate(serverAgentsProvider),
            // No screen-wide loading state: each server resolves independently, so a
            // reachable one renders straight away instead of waiting behind a
            // sleeping one, and each section shows that server's own reachability.
            // A single spinner over the whole list meant one asleep machine hid
            // every blocked agent on every other machine.
            child: ListView(
              padding: EdgeInsets.only(
                top: FlatAppBar.padding(context),
                bottom: Space.xl,
              ),
              children: [
                SectionLabel(
                  'Priority',
                  trailing: hits.isEmpty
                      ? null
                      : Text(
                          '${hits.length}',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: scheme.onSurfaceVariant,
                            letterSpacing: 0.4,
                          ).mono,
                        ),
                ),
                if (hits.isEmpty)
                  const _Hint(
                    'Nothing needs you right now. Blocked agents appear here '
                    'automatically; star any agent to always pin it.',
                    small: true,
                  )
                else ...[
                  for (final h in overflow.visible)
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
                  PriorityOverflowBar(
                    overflow: overflow,
                    onToggle: () =>
                        ref.read(priorityExpandedProvider.notifier).toggle(),
                  ),
                ],
                // The divider that used to separate Priority from the servers list
                // is gone: spaced panels already read as separate groups, and a
                // rule between them lands as a second, weaker edge next to the
                // panel borders.
                const SizedBox(height: Space.sm),
                // All agents, grouped by server, with star toggles.
                for (final sa in servers) ...[
                  SectionLabel(
                    sa.server.name,
                    trailing: sa.ok
                        ? null
                        : Text(
                            'unreachable',
                            style: TextStyle(
                              fontSize: 10,
                              color: scheme.error,
                            ).mono,
                          ),
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
    // Status and star sit on a second line rather than crowding a trailing
    // column: on a phone the old row put age, badge and star into the space
    // left over after the title, which ellipsised the title to nothing on any
    // reasonably named task.
    return PanelRow(
      onTap: onTap,
      borderColor: agent.agentStatus == AgentStatus.blocked
          ? scheme.error
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AgentAvatar(agent: agent.agent, radius: 16),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      agent.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        height: 1.25,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // Prose keeps the proportional face; the git identity is an
                    // identifier and is set in mono — the mono rule in action.
                    _IdentityLine(
                      server: server,
                      gitLabel: agent.gitLabel,
                      showServer: showServer,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: starred ? 'Unstar' : 'Star',
                onPressed: onStar,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  starred ? Icons.star : Icons.star_border,
                  color: starred
                      ? const Color(0xFFF5C043)
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (client != null)
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: LiveActivityLine(
                paneId: agent.paneId,
                status: agent.agentStatus,
                client: client,
              ),
            ),
          const SizedBox(height: Space.sm),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Row(
              children: [
                StatusMark(agent.agentStatus),
                const SizedBox(width: Space.lg),
                // The wait itself, next to the state. "Blocked" tells you what;
                // this tells you whether to care.
                AgentAge(
                  agent.sinceLastActivity,
                  emphasize: agent.agentStatus == AgentStatus.blocked,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The row's second line: the server name in prose, the git identity in mono.
/// A single line of both, so the identifier part of it follows the mono rule
/// without dragging the proper noun along.
class _IdentityLine extends StatelessWidget {
  const _IdentityLine({
    required this.server,
    required this.gitLabel,
    required this.showServer,
  });

  final ServerSummary server;
  final String gitLabel;
  final bool showServer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        children: [
          if (showServer) ...[
            TextSpan(text: server.name),
            const TextSpan(text: '  ·  '),
          ],
          TextSpan(text: gitLabel, style: TextStyle(fontSize: 11.5).mono),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.small = false});
  final String text;

  /// A quieter hint: the "nothing needs you" empty state reads as a notice
  /// rather than an instruction, so it sits a step down from the hints that
  /// explain why something is missing.
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: small ? 12 : null,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
