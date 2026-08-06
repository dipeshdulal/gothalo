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
/// Returns whether it is safe to go on and open the agent.
///
/// False means the push named a bridge this phone has no record of, and the
/// caller must NOT navigate. Pane ids are not unique across servers, so opening
/// that id on whatever server happens to be active can land on a real but
/// unrelated agent — and the user would have no way to tell. Refusing is the
/// only safe answer; the previous behaviour of navigating anyway was the one
/// outcome worth avoiding.
///
/// It happens when a bridge predates `GET /info` and has never reported an
/// identity, but also on a fully current fleet: a cold start that taps a
/// notification before the identity sync has run, a server whose config was
/// regenerated, or one removed and re-added.
///
/// An EMPTY id is not that case — it is a push from a bridge too old to send one
/// at all, where there is nothing to resolve and nothing better to do than open
/// it on the current server. That returns true.
Future<bool> activateServer(WidgetRef ref, String serverId) async {
  if (serverId.isEmpty) return true;
  final profile = await ref.read(databaseProvider).profileByServerId(serverId);
  if (profile == null) return false;
  final active = await ref.read(activeServerIdProvider.future);
  if (active == profile.id) return true;
  await ref.read(activeServerIdProvider.notifier).set(profile.id);
  return true;
}
