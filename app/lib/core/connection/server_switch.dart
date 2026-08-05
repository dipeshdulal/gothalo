import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/db_providers.dart';
import 'connection_providers.dart';

/// Point the app at the bridge identified by [serverId] (a bridge's own id, as
/// carried in a push), if it is one of the saved servers.
///
/// Anything that opens an agent from an alert has to do this first: alerts come
/// from every paired machine, but the snapshot, terminal and approve calls all
/// run against the *active* one. Without the switch, opening an alert from a
/// second machine silently acts on the wrong server.
///
/// A server id we don't recognise — an unpaired bridge, or one paired before
/// identity existed — leaves the selection untouched, so navigation degrades to
/// "open it on the current server" instead of failing.
Future<void> activateServer(WidgetRef ref, String serverId) async {
  if (serverId.isEmpty) return;
  final profile = await ref.read(databaseProvider).profileByServerId(serverId);
  if (profile == null) return;
  final active = await ref.read(activeServerIdProvider.future);
  if (active == profile.id) return;
  await ref.read(activeServerIdProvider.notifier).set(profile.id);
}
