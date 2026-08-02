import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../../data/db/database.dart';
import '../../data/db/db_providers.dart';

part 'inbox_providers.g.dart';

/// The live inbox, fetched from `/snapshot`.
///
/// `build()` runs the first fetch and re-runs automatically if the active
/// connection changes (via [bridgeClientProvider]). [refresh] backs
/// pull-to-refresh. dio does the fetching here; persistence (drift) is a
/// separate concern handled by [inboxHistory] and the FCM path.
@riverpod
class SnapshotController extends _$SnapshotController {
  @override
  Future<Snapshot> build() => _fetch();

  Future<Snapshot> _fetch() {
    final client = ref.watch(bridgeClientProvider);
    if (client == null) {
      throw BridgeException('No bridge connection configured yet.');
    }
    return client.getSnapshot();
  }

  /// Pull-to-refresh: re-fetch without tearing the current list down to a
  /// spinner (the RefreshIndicator already shows progress).
  Future<void> refresh() async {
    state = await AsyncValue.guard(_fetch);
  }
}

/// Reactive event/inbox history for a profile, straight off drift. Re-emits the
/// instant a new `blocked`/`done` event is inserted (by the FCM handler or a
/// detected snapshot transition).
///
/// Authored manually (not `@riverpod`) on purpose: [AgentEvent] is a type drift
/// generates wholesale in `database.g.dart`, so referencing it in a
/// riverpod-generated signature fails on a clean build (the type isn't emitted
/// yet when riverpod runs). A manual provider compiles after all codegen, so
/// the type resolves.
final inboxHistoryProvider =
    StreamProvider.family<List<AgentEvent>, String>((ref, profileId) {
  return ref.watch(databaseProvider).watchEvents(profileId);
});
