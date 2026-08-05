import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/connection/connection_providers.dart';
import '../db/db_providers.dart';
import 'bridge_client.dart';

part 'bridge_providers.g.dart';

/// A [BridgeClient] for the active connection, rebuilt automatically whenever
/// [ActiveConnection] changes (settings save today, QR pairing later). Returns
/// null while there is no connection configured.
@riverpod
BridgeClient? bridgeClient(Ref ref) {
  // Stable for the session so a transient un-watch doesn't recreate the client
  // (which would churn the snapshot store's `/events` socket).
  ref.keepAlive();
  final connection = ref.watch(activeConnectionProvider).asData?.value;
  if (connection == null) return null;
  return BridgeClient(connection);
}

/// Learn (and remember) which bridge the active server actually is.
///
/// A push carries only the sending bridge's `server_id`, so the app needs the
/// reverse mapping to attribute an alert, route a notification tap, or act on a
/// tray button — all of which can happen with no UI running. Asking `GET /info`
/// whenever we connect is what populates it, including for servers that were
/// paired before the bridge reported an identity at all.
///
/// Best-effort: an older bridge 404s and the server simply stays unattributed.
@Riverpod(keepAlive: true)
Future<String?> serverIdentity(Ref ref) async {
  final client = ref.watch(bridgeClientProvider);
  if (client == null) return null;
  try {
    final info = await client.info();
    if (info.serverId.isEmpty) return null;
    await ref
        .read(databaseProvider)
        .setProfileServerId(client.connection.id, info.serverId);
    return info.serverId;
  } catch (_) {
    return null;
  }
}
