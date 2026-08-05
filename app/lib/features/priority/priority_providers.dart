import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection.dart';
import '../../core/connection/connection_providers.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../inbox/inbox_providers.dart';

/// Persisted set of starred agents, keyed `"<serverId>::<paneId>"`. Stored in
/// secure storage (no schema, so it stays clear of the shared drift database).
/// Manual providers throughout — no codegen — to avoid stepping on the parallel
/// build_runner.
final starredAgentsProvider =
    AsyncNotifierProvider<StarredAgents, Set<String>>(StarredAgents.new);

class StarredAgents extends AsyncNotifier<Set<String>> {
  static const _key = 'gothalo.starred_agents';

  static String starKey(String serverId, String paneId) =>
      '$serverId::$paneId';

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
      (state.asData?.value ?? const <String>{})
          .contains(starKey(serverId, paneId));

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

/// Fetches every saved server's `/snapshot` in parallel (each with its own
/// bearer), so the Priority view can aggregate starred agents across all of
/// them.
///
/// Refreshes itself on a timer for as long as something is watching it. Without
/// that it fetched exactly once and then never again — the servers list and
/// Priority froze at whatever was true when the app opened, which reads as the
/// app being broken even though every other surface is live.
final allServersAgentsProvider =
    FutureProvider.autoDispose<List<ServerAgents>>((ref) async {
  // Self-invalidate on a timer. autoDispose is what scopes it: the timer dies
  // with the last listener, so nothing polls once the screen is gone.
  final timer = Timer(_crossServerRefresh, ref.invalidateSelf);
  ref.onDispose(timer.cancel);

  // The active server already has a live socket; piggy-back on it so its rows
  // update the instant something changes rather than on the next tick.
  ref.watch(snapshotControllerProvider);

  final servers = ref.watch(serversProvider).asData?.value ?? const [];
  final repo = ref.watch(serversRepositoryProvider);

  return Future.wait(
    servers.map((s) async {
      try {
        final bearer = await repo.bearerFor(s.id);
        if (bearer == null || bearer.isEmpty) {
          return ServerAgents(server: s, error: 'No saved token');
        }
        final client = BridgeClient(
          Connection(id: s.id, name: s.name, baseUrl: s.baseUrl, bearer: bearer),
        );
        final snap = await client.getSnapshot();
        return ServerAgents(server: s, agents: snap.agents, client: client);
      } catch (e) {
        return ServerAgents(server: s, error: e);
      }
    }),
  );
});

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
/// rank, so what needs you sits on top — and in the same order as the inbox.
final priorityHitsProvider = Provider<List<PriorityHit>>((ref) {
  final stars = ref.watch(starredAgentsProvider).asData?.value ?? const {};
  final servers = ref.watch(allServersAgentsProvider).asData?.value ?? const [];

  final hits = <PriorityHit>[];
  for (final sa in servers) {
    for (final agent in sa.agents) {
      final starred =
          stars.contains(StarredAgents.starKey(sa.server.id, agent.paneId));
      final auto = agent.agentStatus.needsAttention; // blocked or done
      if (starred || auto) {
        hits.add(PriorityHit(
          server: sa.server,
          agent: agent,
          starred: starred,
          reachable: sa.ok,
          client: sa.client,
        ));
      }
    }
  }
  hits.sort((a, b) => a.agent.attention - b.agent.attention);
  return hits;
});
