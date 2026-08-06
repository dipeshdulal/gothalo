import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_providers.dart';
import '../inbox/inbox_providers.dart';
import 'fleet_widget_store.dart';
import 'fleet_widget_sync.dart';

/// Keeps the Android home-screen widget in step with what the app can see.
///
/// Two feeds, deliberately no third:
///
/// 1. **The active server, live.** `snapshotControllerProvider` is already
///    streaming `/events` for the whole session, so folding each snapshot into
///    the widget costs nothing and tracks that machine exactly as closely as the
///    app does.
/// 2. **The whole fleet, at moments we already know are interesting** — app
///    start and every resume. Other servers have no socket, so they can only be
///    asked; asking them on a timer is what FCM exists to avoid (the same
///    reasoning that confines Priority's cross-server poll to the seconds that
///    screen is on screen).
///
/// The push isolate adds the third trigger from outside the app entirely — see
/// `firebaseMessagingBackgroundHandler`. Every path no-ops when the widget is
/// not on a home screen.
final fleetWidgetSyncProvider = Provider<void>((ref) {
  if (!fleetWidgetSupported) return;

  Set<String> knownIds() =>
      (ref.read(serversProvider).value ?? const []).map((s) => s.id).toSet();

  List<WidgetServer> targets() => [
    for (final s in ref.read(serversProvider).value ?? const [])
      WidgetServer(id: s.id, name: s.name, baseUrl: s.baseUrl),
  ];

  // 1. The active server's live snapshot.
  ref.listen(snapshotControllerProvider, (_, next) {
    final snap = next.value;
    final conn = ref.read(activeConnectionProvider).value;
    if (snap == null || conn == null) return;
    _fireAndForget(
      syncServerToWidget(
        serverId: conn.id,
        serverName: conn.name,
        agents: snap.agents,
        knownServerIds: knownIds(),
      ),
    );
  }, fireImmediately: true);

  // A server that was unpaired must leave the widget now, not at the next
  // refresh — its agents are no longer reachable or actionable.
  ref.listen(serversProvider, (_, next) {
    if (next.value == null) return;
    _fireAndForget(pruneWidgetServers(knownIds()));
  });

  // 2. The whole fleet, at start and on every resume.
  _fireAndForget(
    Future.delayed(
      // The servers list is still loading at first frame; a beat's delay is the
      // difference between refreshing every bridge and refreshing none.
      const Duration(seconds: 2),
      () => refreshWidgetFromBridges(servers: targets()),
    ),
  );
  final lifecycle = AppLifecycleListener(
    onResume: () =>
        _fireAndForget(refreshWidgetFromBridges(servers: targets())),
  );
  ref.onDispose(lifecycle.dispose);
});

/// The widget must never be able to fail anything upstream of it.
void _fireAndForget(Future<void> f) {
  unawaited(f.catchError((Object e) => debugPrint('gothalo: widget sync: $e')));
}
