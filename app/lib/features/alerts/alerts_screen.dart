import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../data/db/db_providers.dart';
import 'alerts_providers.dart';

/// The persistent alerts log: every blocked/done push, newest first, grouped by
/// day. Tapping one deep-links to that agent's terminal. Opening the screen
/// marks everything read (clears the badge); old alerts self-prune (7 days).
class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  /// Row ids that were unread when this screen opened — highlighted for this
  /// viewing even after we clear the badge, so "what's new" stays visible.
  /// Captured from the first data emission (before [markAllHandled] runs).
  Set<int>? _unreadOnOpen;
  bool _markedRead = false;

  @override
  Widget build(BuildContext context) {
    final alerts = ref.watch(alertsProvider);
    final live = ref.watch(activeAgentsByPaneProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        actions: [
          if ((alerts.asData?.value ?? const []).isNotEmpty)
            IconButton(
              tooltip: 'Clear all',
              onPressed: () => ref.read(databaseProvider).clearEvents(),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: alerts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (events) {
          if (events.isEmpty) return const _EmptyAlerts();
          // Snapshot the unread set once, from the first real data, then mark
          // everything read on the next frame (clears the bell badge).
          _unreadOnOpen ??= {
            for (final e in events)
              if (!e.handled) e.rowId,
          };
          if (!_markedRead) {
            _markedRead = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              ref.read(databaseProvider).markAllHandled();
            });
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: events.length,
            itemBuilder: (context, i) {
              final e = events[i];
              final prev = i == 0 ? null : events[i - 1];
              final header = _dayLabel(e.receivedAt);
              final showHeader =
                  prev == null || _dayLabel(prev.receivedAt) != header;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showHeader) _DayHeader(label: header),
                  _AlertTile(
                    event: e,
                    unread: _unreadOnOpen!.contains(e.rowId),
                    liveness: alertLiveness(
                      e,
                      activeProfileId: live.profileId,
                      byPane: live.byPane,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({
    required this.event,
    required this.unread,
    required this.liveness,
  });
  final AgentEvent event;

  /// Was this alert unread when the screen opened — drives the emphasis.
  final bool unread;

  /// Does the alert still reflect the agent's live state.
  final AlertLiveness liveness;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Only a still-blocked alert wants you; done and resolved are both settled,
    // so both recede (dimmed, muted title) — just with different markers.
    final needsYou = liveness == AlertLiveness.needsYou;
    final settled = !needsYou;
    const blockedColor = Color(0xFFFF5252);
    const doneColor = Color(0xFF00C853);

    // Three reads: needs-you (urgent red), done (calm green completion), and
    // resolved (a stale ask that no longer wants you — dimmed, hollow).
    final (statusLabel, statusColor) = switch (liveness) {
      AlertLiveness.needsYou => ('blocked', blockedColor),
      AlertLiveness.done => ('done', doneColor),
      AlertLiveness.resolved => ('resolved', scheme.onSurfaceVariant),
    };

    final tile = ListTile(
      onTap: event.paneId.isEmpty
          ? null
          : () => context.push(
                // Alerts are always about an agent → open its chat view.
                '/transcript/${Uri.encodeComponent(event.paneId)}',
              ),
      // A needs-you alert gets an urgent filled dot; done a completion check;
      // resolved a hollow ring — the kind reads at a glance without the label.
      leading: SizedBox(
        width: 16,
        child: switch (liveness) {
          AlertLiveness.done => const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Icon(Icons.check_circle, size: 15, color: doneColor),
            ),
          AlertLiveness.resolved => Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border:
                    Border.all(color: scheme.onSurfaceVariant, width: 1.5),
              ),
            ),
          AlertLiveness.needsYou => Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(top: 6),
              decoration: const BoxDecoration(
                color: blockedColor,
                shape: BoxShape.circle,
              ),
            ),
        },
      ),
      title: Text(
        event.title.isEmpty ? event.paneId : event.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
          color: settled ? scheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              statusLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: statusColor, fontWeight: FontWeight.w600),
            ),
          ),
          Text('  ·  ', style: TextStyle(color: scheme.onSurfaceVariant)),
          Flexible(
            child: Text(
              event.paneId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontFamily: AppTheme.monoFamily,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _timeAgo(event.receivedAt),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
      trailing: unread
          ? Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
            )
          : (event.paneId.isEmpty
              ? null
              : Icon(Icons.chevron_right, color: scheme.onSurfaceVariant)),
    );

    // Unread → accent left-bar + faint tint. Resolved → dimmed as a whole.
    return Container(
      decoration: unread
          ? BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.05),
              border: Border(
                left: BorderSide(color: scheme.primary, width: 3),
              ),
            )
          : null,
      child: settled ? Opacity(opacity: 0.6, child: tile) : tile,
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyAlerts extends StatelessWidget {
  const _EmptyAlerts();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No alerts yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'When an agent gets blocked or finishes, it shows up here.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _timeAgo(int millis) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final diff = Duration(milliseconds: now - millis);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

String _dayLabel(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final delta = today.difference(that).inDays;
  if (delta <= 0) return 'Today';
  if (delta == 1) return 'Yesterday';
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
