import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection.dart';
import '../../core/connection/connection_providers.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';

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
  ServerAgents({required this.server, this.agents = const [], this.error});

  final ServerSummary server;
  final List<Agent> agents;
  final Object? error;

  bool get ok => error == null;
}

/// Fetches every saved server's `/snapshot` in parallel (each with its own
/// bearer), so the Priority view can aggregate starred agents across all of
/// them. Re-runs when the server list changes; refresh by invalidating.
final allServersAgentsProvider = FutureProvider<List<ServerAgents>>((ref) async {
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
        return ServerAgents(server: s, agents: snap.agents);
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
  });

  final ServerSummary server;
  final Agent agent;
  final bool starred;
  final bool reachable;

  /// Blocked = actively waiting on you. (Done is surfaced too, but it isn't
  /// "needs you".)
  bool get needsYou => agent.agentStatus == AgentStatus.blocked;
}

/// Priority agents across all servers: **automatically** whatever needs
/// attention (blocked or done), **plus** anything you manually starred. Ordered
/// blocked → done → working → idle, so what needs you sits on top.
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
        ));
      }
    }
  }
  hits.sort((a, b) => a.agent.agentStatus.rank - b.agent.agentStatus.rank);
  return hits;
});
