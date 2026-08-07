import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection.dart';
import '../../core/connection/connection_providers.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../../data/db/db_providers.dart';
import '../inbox/inbox_providers.dart';

/// Persisted set of starred agents, keyed `"<serverId>::<paneId>"`. Stored in
/// secure storage (no schema, so it stays clear of the shared drift database).
/// Manual providers throughout — no codegen — to avoid stepping on the parallel
/// build_runner.
final starredAgentsProvider = AsyncNotifierProvider<StarredAgents, Set<String>>(
  StarredAgents.new,
);

class StarredAgents extends AsyncNotifier<Set<String>> {
  static const _key = 'gothalo.starred_agents';

  static String starKey(String serverId, String paneId) => '$serverId::$paneId';

  @override
  Future<Set<String>> build() async {
    final raw = await ref.watch(secureStorageProvider).read(key: _key);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  bool isStarred(String serverId, String paneId) =>
      (state.asData?.value ?? const <String>{}).contains(
        starKey(serverId, paneId),
      );

  Future<void> toggle(String serverId, String paneId) async {
    final key = starKey(serverId, paneId);
    final next = {...(state.asData?.value ?? const <String>{})};
    if (!next.remove(key)) next.add(key);
    state = AsyncData(next);
    await ref
        .read(secureStorageProvider)
        .write(key: _key, value: jsonEncode(next.toList()));
  }
}

/// One server's live agents (or an error reaching it).
class ServerAgents {
  ServerAgents({
    required this.server,
    this.agents = const [],
    this.error,
    this.client,
  });

  final ServerSummary server;
  final List<Agent> agents;
  final Object? error;

  /// The client used to fetch [agents] — kept so a row can poll that same
  /// server directly (e.g. [LiveActivityLine]) without re-resolving its
  /// bearer. Null only alongside [error].
  final BridgeClient? client;

  bool get ok => error == null;
}

/// How often the cross-server view refetches while it is on screen.
///
/// This screen spans EVERY paired server, and only the active one has a live
/// `/events` socket — so the rest can only be kept current by asking. Polling is
/// deliberately confined to the moments the screen is actually being looked at
/// (see the autoDispose below): a phone should not be waking N bridges in the
/// background, which is what FCM is for.
const _crossServerRefresh = Duration(seconds: 6);

/// How long one server gets to answer before it is called unreachable.
///
/// Must stay comfortably below [_crossServerRefresh]: the aggregate resolves
/// only when every server has, so a budget larger than the refresh period means
/// a new fetch starts before the last one finished and the provider never
/// reaches a settled state.
const _perServerBudget = Duration(seconds: 4);

/// One server's live agents, fetched and refreshed **independently of every
/// other server**.
///
/// A family rather than one aggregate on purpose. The aggregate used
/// `Future.wait`, so it resolved only when the slowest server had answered —
/// which meant a sleeping laptop held every other server's row hostage, and
/// with an 8s client timeout against a 6s refresh it never settled at all.
/// Each server now succeeds, fails, and retries on its own schedule, and each
/// row renders whatever that one server currently says.
final serverAgentsProvider = FutureProvider.autoDispose.family<ServerAgents, String>((
  ref,
  serverId,
) async {
  // Self-invalidate on a timer. autoDispose scopes it: the timer dies with the
  // last listener, so nothing polls once the screen is gone.
  final timer = Timer(_crossServerRefresh, ref.invalidateSelf);
  ref.onDispose(timer.cancel);

  // The active server already has a live socket; piggy-back on it so its row
  // updates the instant something changes rather than on the next tick.
  ref.watch(snapshotControllerProvider);

  final servers = ref.watch(serversProvider).value ?? const <ServerSummary>[];
  ServerSummary? server;
  for (final s in servers) {
    if (s.id == serverId) {
      server = s;
      break;
    }
  }
  // Transient: the id came from the servers list, so this only happens in the
  // gap after a server is deleted while its row is still on screen.
  if (server == null) throw StateError('unknown server $serverId');

  try {
    final bearer = await ref
        .watch(serversRepositoryProvider)
        .bearerFor(server.id);
    if (bearer == null || bearer.isEmpty) {
      return ServerAgents(server: server, error: 'No saved token');
    }
    final client = BridgeClient(
      Connection(
        id: server.id,
        name: server.name,
        baseUrl: server.baseUrl,
        bearer: bearer,
      ),
    );
    // Bounded inside the refresh interval. BridgeClient's own 8s timeout is
    // right for a user-initiated request but too long for a background poll:
    // it outlasts the refresh period, so a machine that is simply asleep would
    // keep this provider permanently unsettled instead of just saying so.
    final snap = await client.getSnapshot().timeout(_perServerBudget);

    // Learn this bridge's identity the first time we successfully reach it.
    //
    // `GET /info` used to be asked only of the ACTIVE server, so a newly paired
    // or newly upgraded bridge stayed unattributed until you happened to open
    // it — and until then a notification from that machine could not be routed,
    // because a push carries only the sender's server_id and the app had no
    // reverse mapping for it. The servers list already talks to every server, so
    // this is the natural place to close that gap.
    //
    // Once only: bridgeVersion is 0 until a bridge has reported one, so this
    // costs a single extra round-trip per server for the life of the pairing
    // rather than one per poll. An older bridge 404s and simply stays
    // unattributed, exactly as before.
    if (server.bridgeVersion == 0) {
      unawaited(_learnIdentity(ref, client, server.id));
    }

    return ServerAgents(server: server, agents: snap.agents, client: client);
  } catch (e) {
    return ServerAgents(server: server, error: e);
  }
});

/// Every saved server's agents, each resolved independently. A server still
/// loading contributes nothing yet; one that failed contributes its error, so
/// callers can render per-server reachability rather than an all-or-nothing view.
List<ServerAgents> watchAllServerAgents(WidgetRef ref) {
  final servers = ref.watch(serversProvider).value ?? const <ServerSummary>[];
  final out = <ServerAgents>[];
  for (final s in servers) {
    final sa = ref.watch(serverAgentsProvider(s.id)).value;
    if (sa != null) out.add(sa);
  }
  return out;
}

/// A priority agent resolved against live data. [starred] marks a manual pin;
/// [needsYou] marks an automatic one (blocked → waiting for input). Carries the
/// server so the view can group, open, and show reachability.
class PriorityHit {
  PriorityHit({
    required this.server,
    required this.agent,
    required this.starred,
    required this.reachable,
    this.client,
  });

  final ServerSummary server;
  final Agent agent;
  final bool starred;
  final bool reachable;

  /// The client that fetched [agent] — lets a row poll this same server
  /// directly (e.g. [LiveActivityLine]) without re-resolving its bearer.
  final BridgeClient? client;

  /// Blocked = actively waiting on you. (Done is surfaced too, but it isn't
  /// "needs you".)
  bool get needsYou => agent.agentStatus == AgentStatus.blocked;
}

/// Priority agents across all servers: **automatically** whatever needs
/// attention (blocked or done), **plus** anything you manually starred. Ordered
/// blocked → done → working → idle on the bridge's authoritative attention
/// rank, so what needs you sits on top — and in the same order as the inbox,
/// down to the recency tiebreak within a rank. This list spans servers, where
/// `recency_rank` (an index into one bridge's snapshot) means nothing, so the
/// comparison falls through to `last_activity_ts` — see
/// [Agent.byAttentionThenRecency].
final priorityHitsProvider = Provider<List<PriorityHit>>((ref) {
  final stars = ref.watch(starredAgentsProvider).value ?? const {};
  // `.value`, NOT `.asData?.value`: each per-server provider self-invalidates on
  // a timer, and during its refetch the state is AsyncLoading — which still
  // carries the previous value but is not AsyncData. Reading `asData` therefore
  // dropped that server's agents every few seconds, so a blocked agent vanished
  // from Priority and reappeared on the next tick.
  // Same walk as watchAllServerAgents, inlined because a provider gets `Ref`
  // and a widget gets `WidgetRef` — two unrelated types for the same idea.
  final all = ref.watch(serversProvider).value ?? const <ServerSummary>[];
  final servers = <ServerAgents>[];
  for (final s in all) {
    final sa = ref.watch(serverAgentsProvider(s.id)).value;
    if (sa != null) servers.add(sa);
  }

  final hits = <PriorityHit>[];
  for (final sa in servers) {
    for (final agent in sa.agents) {
      final starred = stars.contains(
        StarredAgents.starKey(sa.server.id, agent.paneId),
      );
      final auto = agent.agentStatus.needsAttention; // blocked or done
      if (starred || auto) {
        hits.add(
          PriorityHit(
            server: sa.server,
            agent: agent,
            starred: starred,
            reachable: sa.ok,
            client: sa.client,
          ),
        );
      }
    }
  }
  hits.sort((a, b) => Agent.byAttentionThenRecency(a.agent, b.agent));
  return hits;
});

/// Ask a bridge who it is and remember the answer. Best-effort and fire-and-
/// forget: it must never delay or fail the row it rides along with, and a
/// bridge too old to answer just stays unattributed.
Future<void> _learnIdentity(
  Ref ref,
  BridgeClient client,
  String profileId,
) async {
  try {
    final info = await client.info().timeout(_perServerBudget);
    if (info.serverId.isEmpty) return;
    await ref
        .read(databaseProvider)
        .setProfileIdentity(
          profileId,
          serverId: info.serverId,
          bridgeVersion: info.version,
        );
  } catch (_) {
    // Older bridge, asleep, or unreachable — try again on a later poll.
  }
}
