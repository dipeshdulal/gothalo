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
  final active = ref.watch(activeConnectionProvider);
  // While the active connection is being resolved, hand out NO client rather
  // than the previous one.
  //
  // `asData` deliberately preserves the last value across a refresh, which is
  // wrong here: the identity of the server is the whole point of the client. A
  // cold start has no previous value, so callers get null and show their loading
  // state — a path every screen already handles. But switching servers (a
  // notification tap for an agent on another machine) leaves the OLD server's
  // client in `asData` while the new profile and bearer are read, and a screen
  // that adopts it opens a socket to the wrong machine for a pane that only
  // exists on the other one. Pane ids are not unique across servers, so it can
  // even find an unrelated agent of the same name.
  //
  // Returning null makes the swap behave exactly like the cold start.
  if (active.isLoading) return null;
  final connection = active.asData?.value;
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
