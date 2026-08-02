import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/theme.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../approvals/approve_action.dart';
import '../inbox/inbox_providers.dart';
import '../inbox/widgets/agent_avatar.dart';
import '../inbox/widgets/status_badge.dart';

/// The Overview — every pane at a glance, reachable from the terminal app bar.
///
/// Two lenses over the same panes:
/// - **Grid**: equal-size cards (status badge · agent avatar · stripped title ·
///   `workspace › tab` breadcrumb), tap to open that pane's terminal.
/// - **Urgency**: a compact list sorted blocked → working → idle → done.
///
/// A blocked pane exposes an inline **Approve** in either lens. (The geometric
/// minimap is a deliberately deferred third lens.)
class OverviewScreen extends ConsumerStatefulWidget {
  const OverviewScreen({super.key});

  @override
  ConsumerState<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends ConsumerState<OverviewScreen> {
  bool _grid = true;

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(snapshotControllerProvider);

    return AppBackground(
      asset: Backgrounds.flock,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Overview'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: () =>
                  ref.read(snapshotControllerProvider.notifier).refresh(),
              icon: const Icon(Icons.refresh),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.grid_view_outlined),
                    tooltip: 'Grid',
                  ),
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.list),
                    tooltip: 'Urgency',
                  ),
                ],
                selected: {_grid},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _grid = s.first),
              ),
            ),
          ],
        ),
        body: snapshot.when(
          skipLoadingOnRefresh: true,
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                err is BridgeException ? err.message : err.toString(),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          data: (snap) {
            if (snap.agents.isEmpty) {
              return const Center(child: Text('No agents right now'));
            }
            final agents = _urgencySorted(snap.agents);
            return RefreshIndicator(
              onRefresh: () =>
                  ref.read(snapshotControllerProvider.notifier).refresh(),
              child: _grid ? _Grid(agents: agents) : _UrgencyList(agents: agents),
            );
          },
        ),
      ),
    );
  }
}

/// Urgency rank: blocked first, then working, then idle, then done, unknown last.
int _urgencyRank(AgentStatus s) => switch (s) {
  AgentStatus.blocked => 0,
  AgentStatus.working => 1,
  AgentStatus.idle => 2,
  AgentStatus.done => 3,
  AgentStatus.unknown => 4,
};

List<Agent> _urgencySorted(List<Agent> agents) {
  final list = [...agents];
  list.sort((x, y) {
    final r = _urgencyRank(x.agentStatus) - _urgencyRank(y.agentStatus);
    if (r != 0) return r;
    return x.displayTitle.toLowerCase().compareTo(y.displayTitle.toLowerCase());
  });
  return list;
}

/// `workspace › tab` breadcrumb. Herdr pane ids look like `w5:p2`; the tab is
/// the pane segment after the colon.
String _breadcrumb(Agent a) {
  final ws = a.workspaceId.isNotEmpty ? a.workspaceId : '—';
  final colon = a.paneId.indexOf(':');
  final tab = colon >= 0 ? a.paneId.substring(colon + 1) : a.paneId;
  return tab.isEmpty ? ws : '$ws › $tab';
}

class _Grid extends StatelessWidget {
  const _Grid({required this.agents});
  final List<Agent> agents;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisExtent: 168,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: agents.length,
      itemBuilder: (context, i) => _PaneCard(agent: agents[i]),
    );
  }
}

class _PaneCard extends ConsumerWidget {
  const _PaneCard({required this.agent});
  final Agent agent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = agent.agentStatus == AgentStatus.blocked;
    return Card(
      child: InkWell(
        onTap: () =>
            context.push('/terminal/${Uri.encodeComponent(agent.paneId)}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AgentAvatar(agent: agent.agent, radius: 16),
                  const Spacer(),
                  StatusBadge(agent.agentStatus),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Text(
                  agent.displayTitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              if (blocked)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () => approveAgent(context, ref, agent),
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text('Approve'),
                  ),
                )
              else
                _Breadcrumb(text: _breadcrumb(agent), color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _UrgencyList extends StatelessWidget {
  const _UrgencyList({required this.agents});
  final List<Agent> agents;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: agents.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 64),
      itemBuilder: (context, i) => _PaneListTile(agent: agents[i]),
    );
  }
}

class _PaneListTile extends ConsumerWidget {
  const _PaneListTile({required this.agent});
  final Agent agent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = agent.agentStatus == AgentStatus.blocked;
    return ListTile(
      onTap: () =>
          context.push('/terminal/${Uri.encodeComponent(agent.paneId)}'),
      leading: AgentAvatar(agent: agent.agent, radius: 18),
      title: Text(
        agent.displayTitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: _Breadcrumb(text: _breadcrumb(agent), color: scheme.onSurfaceVariant),
      ),
      trailing: blocked
          ? FilledButton.tonal(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 34),
              ),
              onPressed: () => approveAgent(context, ref, agent),
              child: const Text('Approve'),
            )
          : StatusBadge(agent.agentStatus),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color,
        fontFamily: AppTheme.monoFamily,
        fontSize: 11,
      ),
    );
  }
}
