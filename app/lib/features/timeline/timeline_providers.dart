import 'dart:async';

// `select` is an extension on ProviderListenable that riverpod_annotation
// re-exports the TYPE but not the extension for, so the import that brings the
// method into scope has to be explicit.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../inbox/inbox_providers.dart';

part 'timeline_providers.g.dart';

/// How often the activity log is re-read while the screen is on it.
///
/// Deliberately slow. Unlike the live surfaces, most of what this screen shows
/// is the PAST, which does not change — the only thing that goes stale on its
/// own is the "how long ago" on each row, and a minute's worth of drift on a
/// "3h ago" label is invisible. Real changes don't wait for this tick anyway:
/// [_agentStatusFingerprint] pulls them in the moment the bridge signals one.
const timelineRefresh = Duration(seconds: 30);

/// How many entries to ask the bridge for.
///
/// Comfortably more than a phone screen holds, so scrolling never hits a hole,
/// and well under the bridge's own cap (500) so the page size we get is the one
/// we asked for. The bridge answers from memory, so the cost is transfer, not
/// work on the host.
const timelinePageSize = 200;

/// A fingerprint of every agent's current status, used to decide when the
/// timeline is worth re-reading.
///
/// The screen needs to react the instant an agent transitions — that transition
/// IS the new row, and waiting up to [timelineRefresh] to show it would make the
/// one screen about "what just happened" the slowest to notice it. But the
/// `/events` stream carries far more than transitions (focus moves, layout
/// changes, tab renames), and each of those settles a fresh `Snapshot` object
/// that is never `==` to the last one. Watching the snapshot directly would
/// therefore refetch on churn that cannot possibly have added a row.
///
/// Reducing it to `pane:status` pairs means the provider re-runs only when a
/// status actually changed — or when a pane appeared or vanished, which is a row
/// too (the bridge records a closing pane as a transition to `gone`).
String _agentStatusFingerprint(Snapshot? snap) {
  if (snap == null) return '';
  final parts = [
    for (final a in snap.agents) '${a.paneId}:${a.agentStatus.name}',
  ]..sort();
  return parts.join(',');
}

/// The active server's recent agent activity, newest first.
///
/// `autoDispose` (the default) is load-bearing: the refresh timer below is
/// scoped to the provider's life, so closing the screen stops the polling
/// outright. A phone should not be waking a bridge for a screen nobody is
/// looking at.
@riverpod
Future<List<TimelineEntry>> activityTimeline(Ref ref) async {
  // Self-invalidate on a timer, so the relative times on screen keep up with the
  // clock even on a completely quiet bridge.
  final timer = Timer(timelineRefresh, ref.invalidateSelf);
  ref.onDispose(timer.cancel);

  // Piggy-back on the live `/events` socket for everything that isn't the clock.
  // See [_agentStatusFingerprint] for why this is a projection and not the whole
  // snapshot.
  ref.watch(
    snapshotControllerProvider.select(
      (snap) => _agentStatusFingerprint(snap.value),
    ),
  );

  final client = ref.watch(bridgeClientProvider);
  if (client == null) {
    throw BridgeException('No bridge connection configured yet.');
  }
  return client.getTimeline(limit: timelinePageSize);
}
