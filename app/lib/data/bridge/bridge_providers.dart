import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/connection/connection_providers.dart';
import 'bridge_client.dart';

part 'bridge_providers.g.dart';

/// A [BridgeClient] for the active connection, rebuilt automatically whenever
/// [ActiveConnection] changes (settings save today, QR pairing later). Returns
/// null while there is no connection configured.
@riverpod
BridgeClient? bridgeClient(Ref ref) {
  final connection = ref.watch(activeConnectionProvider).asData?.value;
  if (connection == null) return null;
  return BridgeClient(connection);
}
