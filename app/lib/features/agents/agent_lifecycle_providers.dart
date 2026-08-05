import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';

part 'agent_lifecycle_providers.g.dart';

/// The agent kinds the active server can actually launch (`GET
/// /agents/available`).
///
/// Fetched per server rather than held as a constant because "which agents
/// exist" is a fact about a particular machine: the same app talks to a laptop
/// with Claude only and a workstation with four agents installed. The bridge
/// discovers the set from Herdr's own catalog and the host's PATH, so this
/// list is the only thing the launch UI is allowed to offer.
///
/// Not kept alive: it is read when the launch sheet opens, and re-reading it
/// after installing an agent on the host is exactly the behaviour wanted.
@riverpod
Future<List<AvailableAgent>> availableAgents(Ref ref) async {
  final client = ref.watch(bridgeClientProvider);
  if (client == null) return const [];
  return client.availableAgents();
}
