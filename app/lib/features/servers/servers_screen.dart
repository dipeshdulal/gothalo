import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/app_mark.dart';
import '../../data/bridge/models/snapshot.dart';
import '../inbox/widgets/agent_avatar.dart';
import '../../core/widgets/agent_age.dart';
import '../inbox/widgets/status_badge.dart';
import '../priority/priority_providers.dart';

/// Home dashboard: your **priority** (starred) agents across every server up
/// top, then the **servers** list below with live per-server stats. Pick a
/// server to open its flock, or jump straight to a starred agent.
class ServersScreen extends ConsumerStatefulWidget {
  const ServersScreen({super.key});

  @override
  ConsumerState<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends ConsumerState<ServersScreen> {
  @override
  void initState() {
    super.initState();
    // Seed the optional dev server (from --dart-define) once on a fresh install.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(serversRepositoryProvider).ensureDevSeed();
    });
  }

  Future<void> _openServer(ServerSummary server) async {
    await ref.read(activeServerIdProvider.notifier).set(server.id);
    // push, not go: `go` replaces the whole stack, so Flock had no back entry
    // and the hardware back button exited the app. Pushing keeps Servers
    // underneath, so back returns here.
    if (mounted) context.push('/inbox');
  }

  Future<void> _openAgent(ServerSummary server, Agent agent) async {
    await ref.read(activeServerIdProvider.notifier).set(server.id);
    if (mounted) {
      // Agents open the chat/transcript view by default (with a terminal toggle).
      context.push('/transcript/${Uri.encodeComponent(agent.paneId)}');
    }
  }

  Future<void> _confirmDelete(ServerSummary server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${server.name}?'),
        content: const Text(
          'This deletes the saved server and its token from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(serversRepositoryProvider).delete(server.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serversProvider);
    final hits = ref.watch(priorityHitsProvider);
    // Live per-server agent stats, keyed by server id — each server watched
    // independently so a reachable one renders immediately instead of waiting
    // on a sleeping one.
    //
    // `.value`, NOT `.asData?.value`: during each provider's own refetch the
    // state is AsyncLoading, which still carries the previous value but is not
    // AsyncData. Reading `asData` blanked the row back to "checking…" on every
    // tick, which defeats the point of refreshing at all.
    final byServer = {
      for (final sa in watchAllServerAgents(ref)) sa.server.id: sa,
    };

    return AppBackground(
      asset: Backgrounds.servers,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              AppMark(radius: 14),
              SizedBox(width: 10),
              Text('gothalo'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Pair via QR',
              onPressed: () => context.push('/pair'),
              icon: const Icon(Icons.qr_code_scanner),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => context.push('/servers/add'),
          tooltip: 'Add server manually',
          child: const Icon(Icons.add),
        ),
        body: servers.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) {
            if (list.isEmpty) return const _EmptyServers();
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(serverAgentsProvider),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  // --- Priority (starred) ---
                  _SectionHeader(
                    icon: Icons.star,
                    label: 'Priority',
                    onAction: () => context.push('/priority'),
                    actionLabel: 'Manage',
                  ),
                  if (hits.isEmpty)
                    _PriorityEmpty(onManage: () => context.push('/priority'))
                  else
                    for (final h in hits)
                      _PriorityTile(
                        hit: h,
                        onTap: () => _openAgent(h.server, h.agent),
                      ),

                  const SizedBox(height: 8),
                  const Divider(height: 1),

                  // --- Servers ---
                  const _SectionHeader(
                    icon: Icons.dns_outlined,
                    label: 'Servers',
                  ),
                  for (final s in list)
                    _ServerTile(
                      server: s,
                      summary: byServer[s.id],
                      onTap: () => _openServer(s),
                      onEdit: () => context.push('/servers/${s.id}/edit'),
                      onDelete: () => _confirmDelete(s),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.label,
    this.onAction,
    this.actionLabel,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onAction;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 8, 6),
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
          const Spacer(),
          if (onAction != null && actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

class _PriorityTile extends StatelessWidget {
  const _PriorityTile({required this.hit, required this.onTap});
  final PriorityHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      // ListTile reserves a fixed 40dp leading slot and then adds a separate
      // 16dp horizontalTitleGap, so shrinking the avatar only grows the empty
      // space inside the slot — the text never moves closer. Both have to come
      // down together, and identically on every tile in this list.
      minLeadingWidth: 36,
      horizontalTitleGap: 10,
      leading: AgentAvatar(agent: hit.agent.agent, radius: 18),
      title: Text(
        hit.agent.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${hit.server.name}  ·  ${hit.agent.gitLabel}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hit.starred)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.star, size: 15, color: Color(0xFFF5C043)),
            ),
          // How long it has been like this. "Done" is a state; "Done · 4m" is a
          // decision. This is the first screen you see, so the number belongs
          // here more than anywhere.
          AgentAge(
            hit.agent.sinceLastActivity,
            emphasize: hit.agent.agentStatus == AgentStatus.blocked,
          ),
          const SizedBox(width: 8),
          StatusBadge(hit.agent.agentStatus),
        ],
      ),
    );
  }
}

class _PriorityEmpty extends StatelessWidget {
  const _PriorityEmpty({required this.onManage});
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onManage,
      leading: Icon(Icons.check_circle_outline, color: scheme.primary),
      title: const Text('Nothing needs you'),
      subtitle: Text(
        'Blocked agents show up here automatically. Tap to star more.',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.summary,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final ServerSummary server;
  final ServerAgents? summary;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // "need you" == blocked (waiting for input); done is finished, not waiting.
    final attention =
        summary?.agents
            .where((a) => a.agentStatus == AgentStatus.blocked)
            .length ??
        0;

    return ListTile(
      onTap: onTap,
      // Radius 18 to match AgentAvatar in the Priority rows above; the leading
      // slot and title gap match for the same reason — the two sections read as
      // one list, so they share a grid.
      minLeadingWidth: 36,
      horizontalTitleGap: 10,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: server.isActive
            ? scheme.primary
            : scheme.surfaceContainerHighest,
        child: Icon(
          Icons.dns_outlined,
          size: 20,
          color: server.isActive ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (server.isActive) ...[
            const SizedBox(width: 8),
            _ActivePill(scheme: scheme),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _hostLabel(server.baseUrl),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontFamily: AppTheme.monoFamily,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 2),
          _StatsLine(
            summary: summary,
            attention: attention,
            needsUpgrade: server.needsUpgrade,
          ),
        ],
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Remove')),
        ],
      ),
    );
  }
}

class _StatsLine extends StatelessWidget {
  const _StatsLine({
    required this.summary,
    required this.attention,
    required this.needsUpgrade,
  });
  final ServerAgents? summary;
  final int attention;

  /// This bridge has never reported a version — see [ServerSummary.needsUpgrade].
  final bool needsUpgrade;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (summary == null) {
      return Text(
        'checking…',
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      );
    }
    if (!summary!.ok) {
      return Text(
        'unreachable',
        style: TextStyle(color: scheme.error, fontSize: 12),
      );
    }
    final count = summary!.agents.length;
    return Row(
      children: [
        Text(
          '$count agent${count == 1 ? '' : 's'}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
        // A bridge that has never identified itself can't have its notifications
        // attributed or routed. Worth showing — the alternative is discovering
        // it only when a notification tap declines to open anything — but it is
        // a nudge, not an alarm: everything else about the server works, so it
        // sits quietly next to the agent count rather than beside the name.
        if (needsUpgrade) ...[
          const SizedBox(width: 6),
          const Tooltip(
            message:
                'Update gothalo on this machine to route its notifications',
            child: Icon(
              Icons.warning_amber_rounded,
              size: 15,
              color: _warnColor,
            ),
          ),
          const SizedBox(width: 4),
          // Labelled, not icon-only: a tooltip needs a long-press on a phone, so
          // a bare glyph says "something is wrong" without saying what — which
          // is worse than saying nothing. Mirrors the "N need you" idiom used
          // for attention on this same line.
          const Text(
            'update bridge',
            style: TextStyle(
              color: _warnColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (attention > 0) ...[
          const SizedBox(width: 8),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: scheme.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            '$attention need you',
            style: TextStyle(
              color: scheme.error,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

/// Amber for "works, but needs attention" — distinct from the error red used
/// for an unreachable server, because this one is reachable and fine apart from
/// notification routing.
const _warnColor = Color(0xFFFFB300);

/// host[:port] for the tile subtitle — keeps the port (e.g. :5338) visible.
String _hostLabel(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null || uri.host.isEmpty) return baseUrl;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

class _ActivePill extends StatelessWidget {
  const _ActivePill({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Active',
        style: TextStyle(
          color: scheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyServers extends StatelessWidget {
  const _EmptyServers();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'No servers yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Add a gothalo bridge to see your agents. Enter its URL and token, '
              'or pair by scanning a QR.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => context.push('/pair'),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Pair via QR'),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () => context.push('/servers/add'),
              icon: const Icon(Icons.add),
              label: const Text('Add manually'),
            ),
          ],
        ),
      ),
    );
  }
}
