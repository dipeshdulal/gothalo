import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../../data/db/database.dart';
import '../../data/db/db_providers.dart';
import '../inbox/inbox_providers.dart';

/// The full alerts log (pushed blocked/done events), newest first. Reactive off
/// drift, so it updates the instant a push is logged.
final alertsProvider = StreamProvider<List<AgentEvent>>(
  (ref) => ref.watch(databaseProvider).watchAllEvents(),
);

/// Count of unread alerts — drives the bell badge on the Flock screen.
final unreadAlertsProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchUnreadCount(),
);

/// How an alert should read *now*, given the agent's live state.
///
/// A `blocked` alert is **actionable**: it [needsYou] until the agent moves past
/// blocked, then it's [resolved] (stale — no longer wants you). A `done` alert
/// is not actionable at all: it's a completion notice, its own terminal [done]
/// kind that never "reopens" and never resolves — it just ages out. We keep an
/// alert as [needsYou] rather than guessing resolved when we can't confirm (no
/// live snapshot, or a different server).
enum AlertLiveness { needsYou, resolved, done }

/// Current agents of the **active** server keyed by pane id, plus that server's
/// profile id — the material for judging an alert's [AlertLiveness]. Watching
/// the snapshot here means opening Alerts pulls a fresh state to check against.
final activeAgentsByPaneProvider =
    Provider<({String? profileId, Map<String, Agent> byPane})>((ref) {
  final profileId = ref.watch(activeServerIdProvider).asData?.value;
  final snap = ref.watch(snapshotControllerProvider).asData?.value;
  final byPane = snap == null
      ? const <String, Agent>{}
      : {for (final a in snap.agents) a.paneId: a};
  return (profileId: profileId, byPane: byPane);
});

/// Judge a single alert against live state. Only the active server's alerts can
/// be judged (that's the only snapshot we hold); everything else is [unknown]
/// and rendered normally.
AlertLiveness alertLiveness(
  AgentEvent e, {
  required String? activeProfileId,
  required Map<String, Agent> byPane,
}) {
  // A completion notice is terminal and non-actionable — always its own kind,
  // regardless of what the agent does next.
  if (e.status == 'done') return AlertLiveness.done;
  if (e.status != 'blocked') return AlertLiveness.done;

  // From here it's a `blocked` alert. Pushes are logged without a profile id
  // (they arrive via FCM, background included), so an empty profile is assumed
  // to be the active connection — the one server whose live snapshot we hold.
  // When we can't confirm (a different server, or no snapshot yet), keep it as
  // needs-you rather than guess it away.
  final matchesActive = activeProfileId != null &&
      (e.profileId.isEmpty || e.profileId == activeProfileId);
  if (!matchesActive || byPane.isEmpty) return AlertLiveness.needsYou;

  final agent = byPane[e.paneId];
  // Snapshot is loaded but the pane is gone, or it's no longer blocked → the
  // ask is stale; you don't need to act anymore.
  if (agent == null) return AlertLiveness.resolved;
  return agent.agentStatus == AgentStatus.blocked
      ? AlertLiveness.needsYou
      : AlertLiveness.resolved;
}
