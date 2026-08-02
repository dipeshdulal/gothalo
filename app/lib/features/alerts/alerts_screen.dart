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
  @override
  void initState() {
    super.initState();
    // Seeing the list counts as reading it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(databaseProvider).markAllHandled();
    });
  }

  @override
  Widget build(BuildContext context) {
    final alerts = ref.watch(alertsProvider);
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
                  _AlertTile(event: e),
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
  const _AlertTile({required this.event});
  final AgentEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = event.status == 'blocked';
    final color = blocked ? const Color(0xFFFF5252) : const Color(0xFF00C853);
    return ListTile(
      onTap: event.paneId.isEmpty
          ? null
          : () => context.push(
                '/terminal/${Uri.encodeComponent(event.paneId)}',
              ),
      leading: Container(
        width: 10,
        height: 10,
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      title: Text(
        event.title.isEmpty ? event.paneId : event.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Row(
        children: [
          Text(
            event.status.isEmpty ? 'alert' : event.status,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          Text('  ·  ', style: TextStyle(color: scheme.onSurfaceVariant)),
          Text(
            event.paneId,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontFamily: AppTheme.monoFamily,
              fontSize: 12,
            ),
          ),
          const Spacer(),
          Text(
            _timeAgo(event.receivedAt),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
      trailing: event.paneId.isEmpty
          ? null
          : Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
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
