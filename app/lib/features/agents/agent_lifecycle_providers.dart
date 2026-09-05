import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/connection/connection_providers.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';

part 'agent_lifecycle_providers.g.dart';

/// The agent kind you last started, so the launch sheet opens on it.
///
/// A person runs the same agent most of the time, and the sheet made them say
/// so every launch. Remembered on the device rather than read from the flock:
/// what is *running* is a poor guess at what you want to start next — a host
/// can be full of agents someone else's habits put there.
///
/// Only ever a hint. The bridge's installed list is still the only thing the
/// picker may offer, so a remembered kind that has since been uninstalled
/// selects nothing rather than something that cannot start.
class LastAgentKind extends AsyncNotifier<String?> {
  static const _key = 'gothalo.last_agent_kind';

  @override
  Future<String?> build() =>
      ref.watch(secureStorageProvider).read(key: _key);

  Future<void> record(String kind) async {
    if (kind.isEmpty) return;
    await ref.read(secureStorageProvider).write(key: _key, value: kind);
    state = AsyncData(kind);
  }
}

final lastAgentKindProvider =
    AsyncNotifierProvider<LastAgentKind, String?>(LastAgentKind.new);

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
