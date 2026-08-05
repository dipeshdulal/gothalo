import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../../data/db/database.dart';
import '../../data/db/db_providers.dart';
import '../inbox/inbox_providers.dart';

/// The full alerts log (pushed blocked/done events), newest first. Reactive off
/// drift, so it updates the instant a push is logged.
final alertsProvider = StreamProvider<List<AgentEvent>>(
  (ref) => ref.watch(databaseProvider).watchAllEvents(),
);

/// Count of alerts you haven't looked at yet — drives the bell badge.
///
/// Deliberately "unseen", not "needs you". Priority already answers *what needs
/// you* from live state, across every server; a second count derived from stored
/// alert rows was a worse answer to the same question, and the two could
/// disagree — a resolved block whose row was never marked would keep inflating
/// the badge while Priority correctly showed nothing.
///
/// So the two surfaces split the work: Priority owns urgency, and the bell owns
/// "something happened since you last looked" — including the completions and
/// the already-resolved blocks that Priority, being a view of the present,
/// cannot show at all.
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
/// bridge id — the material for judging an alert's [AlertLiveness]. Watching
/// the snapshot here means opening Alerts pulls a fresh state to check against.
final activeAgentsByPaneProvider =
    Provider<({String? serverId, Map<String, Agent> byPane})>((ref) {
  final serverId = ref.watch(serverIdentityProvider).asData?.value;
  final snap = ref.watch(snapshotControllerProvider).asData?.value;
  final byPane = snap == null
      ? const <String, Agent>{}
      : {for (final a in snap.agents) a.paneId: a};
  return (serverId: serverId, byPane: byPane);
});

/// Judge a single alert against live state. Only the active server's alerts can
/// be judged (that's the only snapshot we hold); everything else stays
/// [AlertLiveness.needsYou] and is rendered normally.
AlertLiveness alertLiveness(
  AgentEvent e, {
  required String? activeServerId,
  required Map<String, Agent> byPane,
}) {
  // A completion notice is terminal and non-actionable — always its own kind,
  // regardless of what the agent does next.
  if (e.status == 'done') return AlertLiveness.done;
  if (e.status != 'blocked') return AlertLiveness.done;

  // From here it's a `blocked` alert. It can only be judged against the snapshot
  // of the bridge it came from; an alert from another machine, or one predating
  // server attribution (empty server id), stays needs-you rather than being
  // guessed away against the wrong server's panes.
  final matchesActive = activeServerId != null &&
      activeServerId.isNotEmpty &&
      (e.serverId.isEmpty || e.serverId == activeServerId);
  if (!matchesActive || byPane.isEmpty) return AlertLiveness.needsYou;

  final agent = byPane[e.paneId];
  // Snapshot is loaded but the pane is gone, or it's no longer blocked → the
  // ask is stale; you don't need to act anymore.
  if (agent == null) return AlertLiveness.resolved;
  return agent.agentStatus == AgentStatus.blocked
      ? AlertLiveness.needsYou
      : AlertLiveness.resolved;
}
