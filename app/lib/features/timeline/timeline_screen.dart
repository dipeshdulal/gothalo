import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../inbox/inbox_providers.dart';
import '../inbox/widgets/agent_avatar.dart';
import 'timeline_providers.dart';

/// The Activity screen — the active server's recent agent history, newest first.
///
/// Every other surface answers "what is true now". This one answers "what
/// happened while I was away", which is the question you actually have when you
/// pick your phone up after an hour: the badge says *blocked* either way, and
/// only the elapsed time distinguishes "it just asked me something" from "it has
/// been stuck for fifty minutes and my afternoon is gone".
///
/// So the number every row leads with is a **duration**, not a status: how long
/// the agent spent in the state it just left. Blocked spans are called out
/// specifically — a long block is the single most expensive thing that can
/// happen to an unattended agent, and the whole screen exists to make one
/// visible at a glance.
class TimelineScreen extends ConsumerWidget {
  const TimelineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timeline = ref.watch(activityTimelineProvider);
    final connection = ref.watch(activeConnectionProvider).asData?.value;
    // `.value`, NOT `.asData?.value`: the snapshot provider is AsyncLoading
    // while it re-reads, and that state still carries the previous snapshot.
    // Reading `asData` would drop every agent's live status for the duration of
    // each refresh, so the "still blocked" markers below would blink out and
    // back on every event the bridge sends.
    final live = ref.watch(snapshotControllerProvider).value;

    return AppBackground(
      asset: Backgrounds.flock,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Activity'),
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
              onPressed: () => ref.invalidate(activityTimelineProvider),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: timeline.when(
          // The provider re-reads on a timer and on every agent transition. Both
          // are refreshes of data already on screen, and rebuilding the list
          // through a full-page spinner would make the screen flash every time
          // an agent so much as changed status — the bug fixed in #80/#81, which
          // this screen must not reintroduce. Only a genuinely cold load shows a
          // spinner.
          skipLoadingOnRefresh: true,
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => _ErrorState(
            message: err is BridgeException ? err.message : err.toString(),
            onRetry: () => ref.invalidate(activityTimelineProvider),
          ),
          data: (entries) => RefreshIndicator(
            // Awaited, so the spinner stays up until the new page actually
            // lands rather than snapping away the instant the tap is handled.
            // A failure needs no handling here: it is already the provider's
            // state, and the error branch above renders it.
            onRefresh: () async {
              ref.invalidate(activityTimelineProvider);
              try {
                await ref.read(activityTimelineProvider.future);
              } catch (_) {}
            },
            child: entries.isEmpty
                ? const _EmptyState()
                : _TimelineList(entries: entries, live: live),
          ),
        ),
      ),
    );
  }
}

/// The list itself: day headers, hour dividers inside a day, and one row per
/// recorded transition.
class _TimelineList extends StatelessWidget {
  const _TimelineList({required this.entries, required this.live});

  final List<TimelineEntry> entries;
  final Snapshot? live;

  @override
  Widget build(BuildContext context) {
    final rows = _layout(entries, live);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i].build(context),
    );
  }
}

/// One item in the flattened list — a header or an entry.
///
/// Flattening day/hour grouping into a single list (rather than nesting
/// `ListView`s or building `Column`s per group) keeps the whole screen inside
/// one lazily-built `ListView.builder`: a week of history costs the same to
/// scroll as an hour of it, and only the visible rows are ever built.
sealed class _Row {
  const _Row();
  Widget build(BuildContext context);
}

class _DayHeader extends _Row {
  const _DayHeader(this.day);
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        dayLabel(day).toUpperCase(),
        style: TextStyle(
          color: scheme.primary,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _HourHeader extends _Row {
  const _HourHeader(this.hour);
  final DateTime hour;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Text(
            '${two(hour.hour)}:00',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontFamily: AppTheme.monoFamily,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends _Row {
  const _EntryRow({
    required this.entry,
    required this.ongoing,
    required this.openable,
  });

  final TimelineEntry entry;

  /// This is the newest entry for its pane AND the live snapshot agrees the
  /// agent is still in the status it names — so the span is still running and
  /// its length is "how long until now", not a fixed number.
  final bool ongoing;

  /// The pane still exists, so the row can open it.
  final bool openable;

  @override
  Widget build(BuildContext context) =>
      _EntryTile(entry: entry, ongoing: ongoing, openable: openable);
}

/// Flattens the entries into headers + rows.
///
/// Grouped by **day** (the coarse "which sitting was this") and by **hour**
/// within a day, which is the grain a phone screen holds — an unattended
/// afternoon produces a handful of transitions an hour, so an hour block is
/// roughly a screenful.
///
/// [live] is the current snapshot, consulted for one thing only: whether the
/// newest entry for a pane is still true. The timeline records what the bridge
/// SAW, and a status change it missed (a Herdr outage) leaves no row — so
/// "newest row says blocked" is not on its own proof the agent is blocked now.
/// Asking the live state closes that gap, and when there is no snapshot to ask
/// (a cold start) nothing is claimed rather than something possibly false.
List<_Row> _layout(List<TimelineEntry> entries, Snapshot? live) {
  final liveStatus = {
    for (final a in live?.agents ?? const <Agent>[]) a.paneId: a.agentStatus,
  };
  final seenPanes = <String>{};
  final rows = <_Row>[];
  DateTime? day;
  DateTime? hour;

  for (final e in entries) {
    final at = e.at;
    if (day == null || !sameDay(day, at)) {
      day = at;
      hour = null;
      rows.add(_DayHeader(at));
    }
    if (hour == null || hour.hour != at.hour) {
      hour = at;
      rows.add(_HourHeader(at));
    }

    // Entries arrive newest-first, so the first time a pane appears is its most
    // recent transition — the only one that can still be running.
    final newest = seenPanes.add(e.pane);
    final current = liveStatus[e.pane];
    rows.add(
      _EntryRow(
        entry: e,
        ongoing: newest && !e.isGone && current != null && current.name == e.to,
        openable: current != null,
      ),
    );
  }
  return rows;
}

/// One recorded transition.
///
/// Reads as: *when*, *who*, *what changed*, and — the reason the screen exists —
/// *how long the state it just left had lasted*.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.ongoing,
    required this.openable,
  });

  final TimelineEntry entry;
  final bool ongoing;
  final bool openable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = statusFromWire(entry.to);
    final blocking = entry.to == 'blocked';
    final accent = entry.isGone
        ? scheme.onSurfaceVariant
        : status.colors(scheme).fg;

    return InkWell(
      onTap: openable
          ? () => context.push('/transcript/${Uri.encodeComponent(entry.pane)}')
          : null,
      child: Container(
        // A block is the one transition that costs you time, so it gets the
        // whole row: a red rail and a tinted ground, not just a colored word
        // among four other colored words. Scanning for "where did I lose an
        // hour" has to work at arm's length.
        decoration: BoxDecoration(
          color: blocking
              ? scheme.error.withValues(alpha: 0.07)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: blocking ? scheme.error : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(13, 9, 16, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: Text(
                '${two(entry.at.hour)}:${two(entry.at.minute)}',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontFamily: AppTheme.monoFamily,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 4),
            AgentAvatar(agent: entry.agent, radius: 13),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Expanded, not Flexible: two Flexible children split the
                      // row evenly, so the title was ellipsised at half width
                      // while the short pane id left the rest of its half blank.
                      // The title takes everything the pane id does not need.
                      Expanded(
                        child: Text(
                          // Name the WORK, not the kind. Every row on a host
                          // running several Claudes otherwise reads "Claude",
                          // which identifies nothing. Fall back to the kind, and
                          // then to a generic label, only when there is no title.
                          entry.title ??
                              (entry.agent.isEmpty
                                  ? 'Agent'
                                  : brandFor(entry.agent).label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Sizes to its content — a pane id is short and fixed-ish,
                      // so it never needs to compete with the title for width.
                      Text(
                        entry.pane,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontFamily: AppTheme.monoFamily,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 2,
                    children: [
                      _Transition(entry: entry, accent: accent),
                      _Elapsed(entry: entry, ongoing: ongoing),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `Working → Blocked`, or just `Blocked` for a first sighting (the bridge omits
/// `from` when it has never seen the pane before, which is not the same as a
/// transition out of an unnamed state).
class _Transition extends StatelessWidget {
  const _Transition({required this.entry, required this.accent});

  final TimelineEntry entry;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final to = entry.isGone ? 'Ended' : statusFromWire(entry.to).label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (entry.from != null) ...[
          Text(
            statusFromWire(entry.from!).label,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Icons.arrow_right_alt,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        Text(
          to,
          style: TextStyle(
            color: accent,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// The duration the row is really about.
///
/// Two different numbers, and the distinction matters:
/// - **`after 12m working`** — a finished span, measured by the bridge. This is
///   the fact no snapshot can reconstruct.
/// - **`blocked 50m`** — the span this transition OPENED, still running, so it
///   is measured against the clock right now.
///
/// A span with no duration at all (`prev_ms` absent) prints nothing rather than
/// "0s": the bridge omits it when it could not see where the span began, and
/// zero is a real value it uses for an instantaneous flip.
class _Elapsed extends StatelessWidget {
  const _Elapsed({required this.entry, required this.ongoing});

  final TimelineEntry entry;
  final bool ongoing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (ongoing) {
      // `ongoing` is never set for a `gone` entry — a closed pane has no running
      // span — so the status always has a name to print here.
      final blocked = entry.to == 'blocked';
      final label =
          '${statusFromWire(entry.to).label.toLowerCase()} '
          '${formatDuration(DateTime.now().difference(entry.at))}';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: blocked
              ? scheme.error.withValues(alpha: 0.16)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: blocked ? scheme.error : scheme.onSurfaceVariant,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final previous = entry.previous;
    if (previous == null || entry.from == null) return const SizedBox.shrink();
    final wasBlocked = entry.from == 'blocked';
    return Text(
      'after ${formatDuration(previous)} ${entry.from}',
      style: TextStyle(
        // A block that has just ENDED is the row that tells you what an
        // interruption cost, so its number is colored too — otherwise the only
        // red on screen is the moment things went wrong, never the moment they
        // were fixed.
        color: wasBlocked ? scheme.error : scheme.onSurfaceVariant,
        fontSize: 12,
        fontWeight: wasBlocked ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }
}

/// A fresh bridge, or one that has not seen an agent change status yet. Not an
/// error — the recorder starts empty and fills as agents work, so this state is
/// normal on a bridge that has just been restarted.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A scrollable, so pull-to-refresh still works with nothing on screen.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.28),
        Icon(Icons.history, size: 40, color: scheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'No activity yet',
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'The bridge records every agent status change from here on — '
              'start an agent and its first transition will show up.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 32, color: scheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'A bridge older than the activity log answers 404 here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting. Hand-rolled rather than pulling in `intl`: the app bundles no
// localization and these are four small, fully-covered cases.
// ---------------------------------------------------------------------------

/// Maps a wire status string onto the app's [AgentStatus], so a timeline row is
/// colored and labelled exactly like the same status on every other screen. An
/// unrecognised value (a status Herdr adds later, or the bridge's synthetic
/// `gone`) degrades to [AgentStatus.unknown] rather than throwing.
AgentStatus statusFromWire(String raw) => switch (raw) {
  'idle' => AgentStatus.idle,
  'working' => AgentStatus.working,
  'blocked' => AgentStatus.blocked,
  'done' => AgentStatus.done,
  _ => AgentStatus.unknown,
};

String two(int n) => n.toString().padLeft(2, '0');

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `Today` / `Yesterday` / `Mon 3 Aug` — the calendar-day label for a header.
String dayLabel(DateTime day, {DateTime? now}) {
  final today = now ?? DateTime.now();
  if (sameDay(day, today)) return 'Today';
  if (sameDay(day, today.subtract(const Duration(days: 1)))) return 'Yesterday';
  return '${day.day} ${_months[day.month - 1]}';
}

/// A compact, human duration: `8s`, `12m`, `1h 40m`, `3d 4h`.
///
/// Deliberately two units at most. The point of the number is a snap judgement
/// — "that block cost me an hour" — and `1h 40m 12s` reads slower than `1h 40m`
/// while saying nothing more useful.
String formatDuration(Duration d) {
  if (d.isNegative) return '0s';
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) {
    final minutes = d.inMinutes % 60;
    return minutes == 0 ? '${d.inHours}h' : '${d.inHours}h ${minutes}m';
  }
  final hours = d.inHours % 24;
  return hours == 0 ? '${d.inDays}d' : '${d.inDays}d ${hours}h';
}
