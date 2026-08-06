import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/connection/connection.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../../data/db/database.dart';
import 'fleet_counts.dart';
import 'fleet_widget_store.dart';

/// Secure-storage key holding a server's bearer, mirroring
/// `connection_providers.dart`. Duplicated for the same reason
/// `notification_actions.dart` duplicates it: the background refresh runs in the
/// push isolate, which has no Riverpod container to read the repository from.
String _bearerKey(String id) => 'gothalo.bearer.$id';

/// How long one bridge gets to answer a background refresh.
///
/// Deliberately shorter than [BridgeClient]'s own 8s: this runs while a
/// notification is being drawn, and a sleeping laptop must not hold that up.
/// A server that misses the budget keeps its previous counts.
const _refreshBudget = Duration(seconds: 4);

/// Serializes writes within one isolate. Two sources (the live snapshot and the
/// Priority poll) can land in the same frame, and both do read-modify-write on
/// the same store. Nothing guards the *cross*-isolate case — the push isolate
/// and the UI isolate are rarely awake together, and the loser of that race is
/// corrected by the next refresh either way.
Future<void> _writes = Future.value();

Future<T> _serialized<T>(Future<T> Function() body) {
  final result = _writes.then((_) => body());
  _writes = result.then((_) {}, onError: (_) {});
  return result;
}

/// Fold one server's agents into the widget, leaving every other server's
/// numbers alone.
///
/// This is the hot path: it runs off the active server's live `/events`
/// snapshot, so the widget tracks that machine as closely as the app does.
Future<void> syncServerToWidget({
  required String serverId,
  required String serverName,
  required List<Agent> agents,
  Set<String>? knownServerIds,
}) async {
  if (!fleetWidgetSupported) return;
  if (!await fleetWidgetInstalled()) return;
  await _serialized(() async {
    final buckets = await readFleetBuckets();
    final next = ServerCounts.fromAgents(
      serverName,
      agents,
      DateTime.now().millisecondsSinceEpoch,
    );
    final known = knownServerIds ?? {...buckets.keys, serverId};
    // Most `/events` frames change something the widget does not show. Only
    // republish when the answer actually moved — but still publish when the set
    // of servers did, so an unpair lands even on an unchanged snapshot.
    if (next.sameNumbers(buckets[serverId]) &&
        known.length == buckets.length &&
        known.containsAll(buckets.keys)) {
      return;
    }
    buckets[serverId] = next;
    await publishFleetBuckets(buckets, known: known);
  });
}

/// Drop servers the app no longer knows about, without changing any counts.
/// Called when the saved-servers list changes so an unpaired machine leaves the
/// widget immediately rather than at the next refresh.
Future<void> pruneWidgetServers(Set<String> knownServerIds) async {
  if (!fleetWidgetSupported) return;
  if (!await fleetWidgetInstalled()) return;
  await _serialized(() async {
    final buckets = await readFleetBuckets();
    await publishFleetBuckets(buckets, known: knownServerIds);
  });
}

/// The non-secret half of a saved server, as the refresh needs it. Mirrors the
/// drift profile row so a caller that already has one (the app) doesn't have to
/// open a second database connection to the same file just to re-read it.
class WidgetServer {
  const WidgetServer({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.deviceId,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String? deviceId;
}

/// Re-read **every** saved server and republish the widget.
///
/// Isolate-safe by construction: with no [servers] supplied it opens its own
/// database, reads bearers straight from secure storage, and builds its own
/// clients — the same shape `notification_actions.dart` uses to act on a
/// notification with no app running. That is what lets a push refresh the
/// widget while the UI is gone. The app passes its own list instead, so it
/// never opens a second connection to the database it already holds.
///
/// Servers are fetched concurrently and independently: one asleep machine
/// contributes its last known counts instead of blanking the whole widget or
/// delaying the others.
Future<void> refreshWidgetFromBridges({List<WidgetServer>? servers}) async {
  if (!fleetWidgetSupported) return;
  if (!await fleetWidgetInstalled()) return;

  AppDatabase? owned;
  try {
    final targets =
        servers ??
        [
          for (final p in await (owned = AppDatabase()).watchProfiles().first)
            WidgetServer(
              id: p.id,
              name: p.name,
              baseUrl: p.baseUrl,
              deviceId: p.deviceId,
            ),
        ];
    if (targets.isEmpty) {
      await _serialized(() => publishFleetBuckets({}, known: const {}));
      return;
    }

    final buckets = await _serialized(readFleetBuckets);
    final now = DateTime.now().millisecondsSinceEpoch;
    const secure = FlutterSecureStorage();

    await Future.wait([
      for (final s in targets)
        () async {
          try {
            final bearer = await secure.read(key: _bearerKey(s.id));
            if (bearer == null || bearer.isEmpty) return;
            final client = BridgeClient(
              Connection(
                id: s.id,
                name: s.name,
                baseUrl: s.baseUrl,
                bearer: bearer,
                deviceId: s.deviceId,
              ),
            );
            final snap = await client.getSnapshot().timeout(_refreshBudget);
            buckets[s.id] = ServerCounts.fromAgents(s.name, snap.agents, now);
          } catch (e) {
            // Unreachable, asleep, revoked: keep what we had. A widget showing
            // slightly old numbers is far more useful than one showing zeros.
            debugPrint('gothalo: widget refresh skipped ${s.name}: $e');
          }
        }(),
    ]);

    await _serialized(
      () =>
          publishFleetBuckets(buckets, known: {for (final s in targets) s.id}),
    );
  } catch (e) {
    debugPrint('gothalo: widget refresh failed: $e');
  } finally {
    await owned?.close();
  }
}
