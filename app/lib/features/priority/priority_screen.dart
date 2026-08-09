import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/flat_app_bar.dart';
import '../../core/widgets/panel_row.dart';
import '../../data/bridge/models/snapshot.dart';
import '../agents/widgets/agent_row.dart';
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
                  const _PriorityEmpty()
                else ...[
                  for (final h in overflow.visible)
                    AgentRow(
                      agent: h.agent,
                      serverName: h.server.name,
                      starred: h.starred,
                      showActivity: true,
                      activityClient: h.client,
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
                          return AgentRow(
                            agent: agent,
                            starred: starred,
                            showActivity: true,
                            activityClient: sa.client,
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

/// The empty Priority state uses the same panel treatment as Home. The screen
/// itself is already the management destination, so there is no extra action
/// button here — just the same quiet explanation and check mark.
class _PriorityEmpty extends StatelessWidget {
  const _PriorityEmpty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PanelRow(
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: scheme.primary),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nothing needs you',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                ),
                const SizedBox(height: 2),
                Text(
                  'Blocked agents appear here automatically; star any agent to '
                  'always pin it.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
